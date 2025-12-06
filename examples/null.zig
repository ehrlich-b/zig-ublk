//! Null block device example
//!
//! Creates a working null block device that:
//! - Returns zeros on read
//! - Discards all writes
//! - Can be tested with: dd if=/dev/ublkb0 bs=4k count=1 | hexdump -C

const std = @import("std");
const ublk = @import("zig_ublk");

/// Null backend IO handler - returns zeros for reads, discards writes
fn nullHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    const op = desc.getOp();
    const nr_sectors = desc.nr_sectors;
    const length = nr_sectors * 512;

    _ = queue;
    _ = tag;

    switch (op) {
        0 => { // READ
            // Return zeros
            if (length <= buffer.len) {
                @memset(buffer[0..length], 0);
            }
            return 0; // Success
        },
        1 => { // WRITE
            // Discard - do nothing
            return 0; // Success
        },
        2 => { // FLUSH
            return 0; // Success
        },
        3 => { // DISCARD
            return 0; // Success
        },
        else => {
            std.log.warn("Unknown operation: {d}", .{op});
            return -5; // -EIO
        },
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
        const processed = ctx.queue.processCompletions(nullHandler) catch |err| {
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

    std.debug.print("=== zig-ublk null device (threaded) ===\n\n", .{});

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

    const device_size: u64 = 256 * 1024 * 1024; // 256MB
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
    std.debug.print("Try: dd if=/dev/ublkb{d} bs=4k count=1 | hexdump -C\n", .{dev_id});
    std.debug.print("Press Ctrl+C to exit\n\n", .{});

    // Main thread just waits
    while (!ctx.stop.load(.acquire)) {
        const ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
