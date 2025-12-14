//! Multi-queue device manager for ublk
//!
//! Orchestrates multiple IO queues for parallel processing across CPU cores.
//! Each queue runs in its own dedicated thread.

const std = @import("std");
const linux = std.os.linux;

const control = @import("control.zig");
const queue_mod = @import("queue.zig");
const uapi = @import("uapi.zig");
const params = @import("params.zig");

const Controller = control.Controller;
const Queue = queue_mod.Queue;

/// Multi-queue device manager
pub const Device = struct {
    allocator: std.mem.Allocator,
    controller: *Controller,
    device_id: u32,
    config: Config,

    // Queue management
    queues: []Queue,
    threads: []std.Thread,
    contexts: []QueueContext,

    // Lifecycle state
    state: DeviceState,

    /// Device lifecycle states
    pub const DeviceState = enum {
        /// ADD_DEV completed
        created,
        /// SET_PARAMS completed
        configured,
        /// Queues are being started
        starting,
        /// START_DEV completed, IO active
        running,
        /// Shutdown in progress
        stopping,
        /// STOP_DEV completed
        stopped,
    };

    /// Device configuration
    pub const Config = struct {
        /// Number of queues (0 = auto-detect from CPU count)
        num_queues: u16 = 0,
        /// Queue depth (number of concurrent IOs per queue)
        queue_depth: u16 = 64,
        /// Device size in bytes
        device_size: u64,
        /// Block size in bytes
        block_size: u32 = 512,
        /// Optional CPU pinning for queue threads
        cpu_affinity: ?[]const u16 = null,
    };

    /// Context passed to each queue thread
    pub const QueueContext = struct {
        queue: *Queue,
        handler: Queue.IoHandler,
        /// Set to true when queue is primed and ready
        ready: std.atomic.Value(bool),
        /// Set to true to signal thread to stop
        stop: std.atomic.Value(bool),
        /// Error result if priming failed
        error_result: ?anyerror,
        /// Optional CPU to pin this thread to
        cpu_id: ?u16,
    };

    pub const InitError = error{
        OutOfMemory,
        InvalidConfig,
    } || Controller.ControlError || Queue.InitError;

    /// Initialize a multi-queue device
    ///
    /// This performs ADD_DEV and SET_PARAMS. Call start() to spawn queue threads
    /// and activate the device.
    pub fn init(
        controller: *Controller,
        config: Config,
        allocator: std.mem.Allocator,
    ) InitError!Device {
        // Determine number of queues
        const num_queues: u16 = if (config.num_queues == 0)
            detectQueueCount()
        else
            config.num_queues;

        if (num_queues == 0) return error.InvalidConfig;

        // Prepare device info for ADD_DEV
        var dev_info = std.mem.zeroInit(uapi.UblksrvCtrlDevInfo, .{});
        dev_info.nr_hw_queues = num_queues;
        dev_info.queue_depth = config.queue_depth;
        dev_info.max_io_buf_bytes = uapi.IO_BUFFER_SIZE_PER_TAG;
        dev_info.dev_id = 0xFFFF_FFFF; // Auto-assign
        dev_info.ublksrv_pid = @intCast(linux.getpid());
        dev_info.flags = uapi.UBLK_F_CMD_IOCTL_ENCODE;

        // ADD_DEV
        const device_id = try controller.addDevice(&dev_info);
        errdefer controller.deleteDevice(device_id) catch {};

        // SET_PARAMS
        const device_params = params.UblkParams.initBasic(config.device_size, config.block_size);
        var params_buf = params.UblkParamsBuffer.init(device_params);
        try controller.setParams(device_id, &params_buf);

        // Allocate arrays for queues, threads, and contexts
        const queues = allocator.alloc(Queue, num_queues) catch return error.OutOfMemory;
        errdefer allocator.free(queues);

        const threads = allocator.alloc(std.Thread, num_queues) catch return error.OutOfMemory;
        errdefer allocator.free(threads);

        const contexts = allocator.alloc(QueueContext, num_queues) catch return error.OutOfMemory;
        errdefer allocator.free(contexts);

        return Device{
            .allocator = allocator,
            .controller = controller,
            .device_id = device_id,
            .config = config,
            .queues = queues,
            .threads = threads,
            .contexts = contexts,
            .state = .configured,
        };
    }

    /// Clean up device resources
    pub fn deinit(self: *Device) void {
        // Stop if still running
        if (self.state == .running) {
            self.stop() catch {};
        }

        // Delete the device from kernel
        self.controller.deleteDevice(self.device_id) catch {};

        // Free arrays
        self.allocator.free(self.contexts);
        self.allocator.free(self.threads);
        self.allocator.free(self.queues);

        self.state = .stopped;
    }

    /// Start the device with the given IO handler
    ///
    /// This initializes all queues, spawns threads, waits for all queues to prime,
    /// then calls START_DEV.
    pub fn start(self: *Device, handler: Queue.IoHandler) !void {
        if (self.state != .configured) {
            return error.InvalidConfig;
        }

        self.state = .starting;
        errdefer self.state = .configured;

        const num_queues = self.queues.len;

        // 0. Open the character device once (all queues share this fd via dup)
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/dev/ublkc{d}\x00", .{self.device_id}) catch unreachable;

        // Retry loop for udev to create the device node after ADD_DEV
        var char_fd: std.posix.fd_t = -1;
        var retry: usize = 0;
        while (retry < 50) : (retry += 1) {
            char_fd = std.posix.open(path[0 .. path.len - 1], .{ .ACCMODE = .RDWR }, 0) catch |err| {
                if (err == error.FileNotFound) {
                    // Wait for udev
                    const ts = linux.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                    _ = linux.nanosleep(&ts, null);
                    continue;
                }
                return err;
            };
            break;
        }
        if (char_fd < 0) {
            return error.DeviceNotFound;
        }
        defer std.posix.close(char_fd);

        // 1. Initialize and start each queue SEQUENTIALLY
        // (go-ublk does this - each queue must submit FETCH_REQs before creating the next)
        var initialized_queues: usize = 0;
        var spawned_threads: usize = 0;

        errdefer {
            // Signal all spawned threads to stop and join them
            for (self.contexts[0..spawned_threads]) |*ctx| {
                ctx.stop.store(true, .release);
            }
            for (self.threads[0..spawned_threads]) |thread| {
                thread.join();
            }
            for (self.queues[0..initialized_queues]) |*q| {
                q.deinit();
            }
        }

        for (0..num_queues) |i| {
            // Create queue
            self.queues[i] = try Queue.initWithFd(
                char_fd,
                self.device_id,
                @intCast(i),
                self.config.queue_depth,
                self.allocator,
            );
            initialized_queues += 1;

            // Set up context
            self.contexts[i] = .{
                .queue = &self.queues[i],
                .handler = handler,
                .ready = std.atomic.Value(bool).init(false),
                .stop = std.atomic.Value(bool).init(false),
                .error_result = null,
                .cpu_id = if (self.config.cpu_affinity) |aff|
                    aff[i % aff.len]
                else
                    null,
            };

            // Spawn thread (it will prime and enter IO loop)
            self.threads[i] = try std.Thread.spawn(.{}, queueThreadFn, .{&self.contexts[i]});
            spawned_threads += 1;

            // Wait for THIS queue to be primed before creating the next one
            while (!self.contexts[i].ready.load(.acquire)) {
                // Sleep briefly to avoid busy-waiting when threads compete for CPUs
                const ts = linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
            }

            // Check for errors during priming
            if (self.contexts[i].error_result) |err| {
                return err;
            }
        }

        // 4. Delay for kernel to process FETCH_REQs (go-ublk uses 100ms, we use 500ms for reliability)
        const ts = linux.timespec{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);

        // 5. START_DEV (single call for entire device)
        try self.controller.startDevice(self.device_id);

        self.state = .running;
    }

    /// Stop the device and clean up queue threads
    pub fn stop(self: *Device) !void {
        if (self.state != .running) {
            return;
        }

        self.state = .stopping;

        // 1. Signal all threads to stop
        for (self.contexts) |*ctx| {
            ctx.stop.store(true, .release);
        }

        // 2. Stop device (wakes up waiting io_urings)
        self.controller.stopDevice(self.device_id) catch {};

        // 3. Join all threads
        for (self.threads) |thread| {
            thread.join();
        }

        // 4. Deinit all queues
        for (self.queues) |*q| {
            q.deinit();
        }

        self.state = .stopped;
    }

    /// Get the number of queues
    pub fn numQueues(self: *const Device) usize {
        return self.queues.len;
    }
};

/// Thread function that runs IO loop for a single queue
fn queueThreadFn(ctx: *Device.QueueContext) void {
    // Pin to CPU if configured
    if (ctx.cpu_id) |cpu| {
        setCpuAffinity(cpu) catch {};
    }

    // Prime the queue (submit FETCH_REQs)
    ctx.queue.prime() catch |err| {
        ctx.error_result = err;
        ctx.ready.store(true, .release); // Signal ready even on error
        return;
    };

    // Signal ready
    ctx.ready.store(true, .release);

    // IO loop
    while (!ctx.stop.load(.acquire)) {
        _ = ctx.queue.processCompletions(ctx.handler) catch |err| {
            ctx.error_result = err;
            break;
        };
    }
}

/// Detect optimal queue count based on CPU count
fn detectQueueCount() u16 {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    // Cap at 32 (kernel typically supports up to 32)
    return @intCast(@min(cpu_count, 32));
}

/// Set CPU affinity for the current thread
fn setCpuAffinity(cpu_id: u16) !void {
    var mask: [16]usize = [_]usize{0} ** 16; // 1024 CPUs max
    const word_idx = cpu_id / @bitSizeOf(usize);
    const bit_idx: u6 = @intCast(cpu_id % @bitSizeOf(usize));
    mask[word_idx] = @as(usize, 1) << bit_idx;

    const rc = linux.syscall3(
        .sched_setaffinity,
        0, // current thread
        @sizeOf(@TypeOf(mask)),
        @intFromPtr(&mask),
    );

    if (rc != 0) return error.AffinityFailed;
}

// ============================================================================
// Tests
// ============================================================================

test "detectQueueCount returns at least 1" {
    const count = detectQueueCount();
    try std.testing.expect(count >= 1);
    try std.testing.expect(count <= 32);
}

test "Config defaults" {
    const config = Device.Config{
        .device_size = 1024 * 1024 * 1024,
    };
    try std.testing.expectEqual(@as(u16, 0), config.num_queues);
    try std.testing.expectEqual(@as(u16, 64), config.queue_depth);
    try std.testing.expectEqual(@as(u32, 512), config.block_size);
    try std.testing.expect(config.cpu_affinity == null);
}
