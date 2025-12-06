//! Null block device - benchmark version (no debug output)
//!
//! Stripped down for benchmarking - no prints in the hot path

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
            if (length <= buffer.len) {
                @memset(buffer[0..length], 0);
            }
            return 0;
        },
        1, 2, 3 => return 0, // WRITE, FLUSH, DISCARD
        else => return -5, // -EIO
    }
}

const QueueContext = struct {
    queue: *ublk.Queue,
    ready: std.atomic.Value(bool),
    stop: std.atomic.Value(bool),
};

fn queueThread(ctx: *QueueContext) void {
    ctx.queue.prime() catch return;
    ctx.ready.store(true, .release);

    // Hot loop - no prints, no allocations
    while (!ctx.stop.load(.acquire)) {
        _ = ctx.queue.processCompletions(nullHandler) catch break;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== zig-ublk null device (benchmark) ===\n", .{});

    var controller = ublk.Controller.init() catch |err| {
        std.debug.print("Controller init failed: {}\n", .{err});
        return;
    };
    defer controller.deinit();

    var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = 1;
    dev_info.queue_depth = 128; // Higher depth for benchmark
    dev_info.max_io_buf_bytes = 64 * 1024; // Must match IO_BUFFER_SIZE_PER_TAG
    dev_info.dev_id = 0xFFFF_FFFF;
    dev_info.ublksrv_pid = @as(i32, @intCast(std.os.linux.getpid()));
    dev_info.flags = 0x02;

    const dev_id = controller.addDevice(&dev_info) catch |err| {
        std.debug.print("ADD_DEV failed: {}\n", .{err});
        return;
    };

    defer {
        controller.deleteDevice(dev_id) catch {};
    }

    const device_size: u64 = 256 * 1024 * 1024;
    const params = ublk.UblkParams.initBasic(device_size, 512);
    var params_buf = ublk.UblkParamsBuffer.init(params);
    controller.setParams(dev_id, &params_buf) catch |err| {
        std.debug.print("SET_PARAMS failed: {}\n", .{err});
        return;
    };

    var queue = ublk.Queue.init(dev_id, 0, dev_info.queue_depth, allocator) catch |err| {
        std.debug.print("Queue init failed: {}\n", .{err});
        return;
    };
    defer queue.deinit();

    var ctx = QueueContext{
        .queue = &queue,
        .ready = std.atomic.Value(bool).init(false),
        .stop = std.atomic.Value(bool).init(false),
    };

    const thread = std.Thread.spawn(.{}, queueThread, .{&ctx}) catch |err| {
        std.debug.print("Thread spawn failed: {}\n", .{err});
        return;
    };

    while (!ctx.ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    controller.startDevice(dev_id) catch |err| {
        std.debug.print("START_DEV failed: {}\n", .{err});
        ctx.stop.store(true, .release);
        thread.join();
        return;
    };

    std.debug.print("Device /dev/ublkb{d} ready for benchmark\n", .{dev_id});

    defer {
        ctx.stop.store(true, .release);
        controller.stopDevice(dev_id) catch {};
        thread.join();
    }

    // Wait for signal
    while (!ctx.stop.load(.acquire)) {
        const ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
