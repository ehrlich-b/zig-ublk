//! Memory block device example (RAM disk)
//!
//! Creates a working RAM-backed block device that:
//! - Stores data in memory with thread-safe sharded locking
//! - Persists for the lifetime of the process
//! - Can be tested with: dd if=/dev/zero of=/dev/ublkb0 bs=4k count=1
//!                  then: dd if=/dev/ublkb0 bs=4k count=1 | hexdump -C

const std = @import("std");
const ublk = @import("zig_ublk");

/// Thread-safe memory backend with sharded RwLocks
///
/// Uses 64KB shards to allow concurrent access to different regions of storage.
/// Reads can proceed in parallel; writes lock only the affected shards.
const MemoryBackend = struct {
    storage: []u8,
    shards: []std.Thread.RwLock,
    allocator: std.mem.Allocator,

    const SHARD_SIZE: usize = 64 * 1024; // 64KB per shard

    pub fn init(allocator: std.mem.Allocator, size: usize) !MemoryBackend {
        const storage = try allocator.alloc(u8, size);
        errdefer allocator.free(storage);
        @memset(storage, 0); // Initialize to zeros

        // Calculate number of shards
        const num_shards = (size + SHARD_SIZE - 1) / SHARD_SIZE;
        const shards = try allocator.alloc(std.Thread.RwLock, num_shards);
        for (shards) |*shard| {
            shard.* = .{};
        }

        return .{
            .storage = storage,
            .shards = shards,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryBackend) void {
        self.allocator.free(self.shards);
        self.allocator.free(self.storage);
    }

    /// Perform a read operation with shared locks on affected shards
    pub fn read(self: *MemoryBackend, offset: usize, length: usize, buffer: []u8) i32 {
        if (offset + length > self.storage.len) {
            return -28; // -ENOSPC
        }
        if (length > buffer.len) {
            return -22; // -EINVAL
        }

        const start_shard = offset / SHARD_SIZE;
        const end_shard = (offset + length - 1) / SHARD_SIZE;

        // Lock all affected shards for reading (shared)
        for (self.shards[start_shard .. end_shard + 1]) |*shard| {
            shard.lockShared();
        }
        defer {
            for (self.shards[start_shard .. end_shard + 1]) |*shard| {
                shard.unlockShared();
            }
        }

        @memcpy(buffer[0..length], self.storage[offset..][0..length]);
        return 0;
    }

    /// Perform a write operation with exclusive locks on affected shards
    pub fn write(self: *MemoryBackend, offset: usize, length: usize, buffer: []const u8) i32 {
        if (offset + length > self.storage.len) {
            return -28; // -ENOSPC
        }
        if (length > buffer.len) {
            return -22; // -EINVAL
        }

        const start_shard = offset / SHARD_SIZE;
        const end_shard = (offset + length - 1) / SHARD_SIZE;

        // Lock all affected shards for writing (exclusive)
        for (self.shards[start_shard .. end_shard + 1]) |*shard| {
            shard.lock();
        }
        defer {
            for (self.shards[start_shard .. end_shard + 1]) |*shard| {
                shard.unlock();
            }
        }

        @memcpy(self.storage[offset..][0..length], buffer[0..length]);
        return 0;
    }

    /// Discard (zero) a region with exclusive locks on affected shards
    pub fn discard(self: *MemoryBackend, offset: usize, length: usize) i32 {
        if (offset + length > self.storage.len) {
            return -28; // -ENOSPC
        }

        const start_shard = offset / SHARD_SIZE;
        const end_shard = (offset + length - 1) / SHARD_SIZE;

        // Lock all affected shards for writing (exclusive)
        for (self.shards[start_shard .. end_shard + 1]) |*shard| {
            shard.lock();
        }
        defer {
            for (self.shards[start_shard .. end_shard + 1]) |*shard| {
                shard.unlock();
            }
        }

        @memset(self.storage[offset..][0..length], 0);
        return 0;
    }
};

/// Global backend pointer (needed for handler callback)
var g_backend: ?*MemoryBackend = null;

/// Thread-safe memory backend IO handler
fn memoryHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    const backend = g_backend orelse return -5; // -EIO
    const op = desc.getIoOp();
    const nr_sectors = desc.nr_sectors;
    const start_sector = desc.start_sector;
    const length: usize = @as(usize, nr_sectors) * 512;
    const offset: usize = @as(usize, start_sector) * 512;

    _ = queue;
    _ = tag;

    if (op) |io_op| {
        switch (io_op) {
            .read => return backend.read(offset, length, buffer),
            .write => return backend.write(offset, length, buffer),
            .flush => return 0, // Memory is always synchronized
            .discard => return backend.discard(offset, length),
            else => {
                std.log.warn("Unsupported operation: {}", .{io_op});
                return -95; // -EOPNOTSUPP
            },
        }
    } else {
        std.log.warn("Unknown operation code: {d}", .{desc.getOp()});
        return -5; // -EIO
    }
}

/// Queue thread context
const QueueContext = struct {
    queue: *ublk.Queue,
    ready: std.atomic.Value(bool),
    stop: std.atomic.Value(bool),
};

/// Queue thread function - runs IO loop
fn queueThread(ctx: *QueueContext) void {
    std.debug.print("Queue thread: starting\n", .{});

    // Prime the queue (submit FETCH_REQs)
    ctx.queue.prime() catch |err| {
        std.debug.print("Queue thread: prime failed: {}\n", .{err});
        return;
    };
    std.debug.print("Queue thread: primed, entering wait loop\n", .{});

    // Signal that we're ready (primed and about to wait)
    ctx.ready.store(true, .release);

    // IO loop
    var io_count: u64 = 0;
    while (!ctx.stop.load(.acquire)) {
        const processed = ctx.queue.processCompletions(memoryHandler) catch |err| {
            std.debug.print("Queue thread: IO error: {}\n", .{err});
            break;
        };
        io_count += processed;

        // Only log periodically to avoid flooding output
        if (io_count > 0 and io_count % 10000 == 0) {
            std.debug.print("Queue thread: {d} IOs completed\n", .{io_count});
        }
    }
    std.debug.print("Queue thread: exiting\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const device_size: u64 = 64 * 1024 * 1024; // 64MB RAM disk

    std.debug.print("=== zig-ublk memory device (RAM disk) ===\n\n", .{});

    // Initialize memory backend
    std.debug.print("[0] Allocating {d} MB backing storage...\n", .{device_size / (1024 * 1024)});
    var backend = MemoryBackend.init(allocator, device_size) catch |err| {
        std.debug.print("ERROR: Failed to allocate storage: {}\n", .{err});
        return;
    };
    defer backend.deinit();
    g_backend = &backend;
    std.debug.print("    SUCCESS ({d} shards for thread-safe access)\n\n", .{backend.shards.len});

    // Initialize controller
    std.debug.print("[1] Opening control device...\n", .{});

    var controller = ublk.Controller.init() catch |err| {
        switch (err) {
            error.DeviceNotFound => {
                std.debug.print("ERROR: /dev/ublk-control not found.\n", .{});
                std.debug.print("Make sure ublk_drv module is loaded: sudo modprobe ublk_drv\n", .{});
                return;
            },
            error.PermissionDenied => {
                std.debug.print("ERROR: Permission denied. Try running with sudo.\n", .{});
                return;
            },
            else => {
                std.debug.print("ERROR: Failed to initialize controller: {}\n", .{err});
                return;
            },
        }
    };
    defer controller.deinit();
    std.debug.print("    SUCCESS\n\n", .{});

    // ADD_DEV
    std.debug.print("[2] Creating device...\n", .{});

    var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = 1;
    dev_info.queue_depth = 64;
    dev_info.max_io_buf_bytes = 64 * 1024; // Must match IO_BUFFER_SIZE_PER_TAG
    dev_info.dev_id = 0xFFFF_FFFF;
    dev_info.ublksrv_pid = @as(i32, @intCast(std.os.linux.getpid()));
    dev_info.flags = 0x02; // UBLK_F_CMD_IOCTL_ENCODE only

    const dev_id = controller.addDevice(&dev_info) catch |err| {
        std.debug.print("    ERROR: ADD_DEV failed: {}\n", .{err});
        return;
    };
    std.debug.print("    SUCCESS: Device ID = {d}\n\n", .{dev_id});

    // Cleanup on exit
    defer {
        std.debug.print("\n[7] Deleting device...\n", .{});
        controller.deleteDevice(dev_id) catch |err| {
            std.debug.print("    WARNING: DEL_DEV failed: {}\n", .{err});
        };
        std.debug.print("    SUCCESS\n", .{});
    }

    // SET_PARAMS
    std.debug.print("[3] Setting parameters...\n", .{});

    const block_size: u32 = 512;
    const params = ublk.UblkParams.initBasic(device_size, block_size);
    var params_buf = ublk.UblkParamsBuffer.init(params);

    controller.setParams(dev_id, &params_buf) catch |err| {
        std.debug.print("    ERROR: SET_PARAMS failed: {}\n", .{err});
        return;
    };
    std.debug.print("    SUCCESS: {d} MB device\n\n", .{device_size / (1024 * 1024)});

    // Setup queue
    std.debug.print("[4] Setting up queue...\n", .{});

    var queue = ublk.Queue.init(dev_id, 0, dev_info.queue_depth, allocator) catch |err| {
        std.debug.print("    ERROR: Queue setup failed: {}\n", .{err});
        return;
    };
    defer queue.deinit();
    std.debug.print("    SUCCESS: Queue 0 ready\n\n", .{});

    // Create queue context and spawn thread
    std.debug.print("[5] Starting queue thread...\n", .{});
    var ctx = QueueContext{
        .queue = &queue,
        .ready = std.atomic.Value(bool).init(false),
        .stop = std.atomic.Value(bool).init(false),
    };

    const thread = std.Thread.spawn(.{}, queueThread, .{&ctx}) catch |err| {
        std.debug.print("    ERROR: Failed to spawn thread: {}\n", .{err});
        return;
    };

    // Wait for queue thread to be ready (primed and waiting)
    std.debug.print("    Waiting for queue to be ready...\n", .{});
    while (!ctx.ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    std.debug.print("    SUCCESS: Queue thread running\n\n", .{});

    // START_DEV - now queue thread is in wait loop
    std.debug.print("[6] Starting device...\n", .{});

    controller.startDevice(dev_id) catch |err| {
        std.debug.print("    ERROR: START_DEV failed: {}\n", .{err});
        ctx.stop.store(true, .release);
        thread.join();
        return;
    };
    std.debug.print("    SUCCESS: /dev/ublkb{d} is now available!\n", .{dev_id});

    // Cleanup device on exit
    defer {
        std.debug.print("\n[*] Stopping device...\n", .{});
        ctx.stop.store(true, .release);
        controller.stopDevice(dev_id) catch {};
        thread.join();
    }

    std.debug.print("=== Device ready for IO ===\n", .{});
    std.debug.print("This is a {d} MB RAM disk - data persists until process exits.\n\n", .{device_size / (1024 * 1024)});
    std.debug.print("Test commands:\n", .{});
    std.debug.print("  Write: echo 'Hello RAM disk!' | sudo dd of=/dev/ublkb{d} bs=512 count=1\n", .{dev_id});
    std.debug.print("  Read:  sudo dd if=/dev/ublkb{d} bs=512 count=1 | head -c 20\n", .{dev_id});
    std.debug.print("\nPress Ctrl+C to exit\n\n", .{});

    // Main thread just waits
    while (!ctx.stop.load(.acquire)) {
        const ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
