//! Multi-queue null block device example
//!
//! Demonstrates the Device API for managing multiple IO queues.
//! Each queue runs in its own thread for parallel IO processing.
//!
//! Expected performance: Near-linear IOPS scaling with queue count.

const std = @import("std");
const ublk = @import("zig_ublk");

/// Null backend IO handler - returns zeros for reads, discards writes
/// This handler is called from multiple threads concurrently.
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
        else => return -95, // -EOPNOTSUPP
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line for queue count
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var num_queues: u16 = 0; // 0 = auto-detect
    if (args.len > 1) {
        num_queues = std.fmt.parseInt(u16, args[1], 10) catch 0;
    }

    const device_size: u64 = 256 * 1024 * 1024; // 256MB

    std.debug.print("=== zig-ublk multi-queue null device ===\n\n", .{});

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

    // Create multi-queue device
    std.debug.print("[2] Creating multi-queue device...\n", .{});

    var device = ublk.Device.init(&controller, .{
        .num_queues = num_queues,
        .queue_depth = 64, // 64 works reliably with 4+ queues, 128 has issues
        .device_size = device_size,
        .block_size = 512,
    }, allocator) catch |err| {
        std.debug.print("    ERROR: Device init failed: {}\n", .{err});
        return;
    };
    defer device.deinit();

    std.debug.print("    SUCCESS: Device ID = {d}, {d} queues\n\n", .{ device.device_id, device.numQueues() });

    // Start device with null handler
    std.debug.print("[3] Starting device (spawning {d} queue threads)...\n", .{device.numQueues()});

    device.start(nullHandler) catch |err| {
        std.debug.print("    ERROR: Device start failed: {}\n", .{err});
        return;
    };
    defer device.stop() catch {};

    std.debug.print("    SUCCESS: /dev/ublkb{d} is now available!\n\n", .{device.device_id});

    std.debug.print("=== Device ready for IO ===\n", .{});
    std.debug.print("Running with {d} IO queues for parallel processing.\n\n", .{device.numQueues()});
    std.debug.print("Benchmark command:\n", .{});
    std.debug.print("  fio --name=test --filename=/dev/ublkb{d} --ioengine=libaio \\\n", .{device.device_id});
    std.debug.print("      --direct=1 --rw=randread --bs=4k --iodepth=64 \\\n", .{});
    std.debug.print("      --numjobs={d} --time_based --runtime=10\n\n", .{device.numQueues()});
    std.debug.print("Press Ctrl+C to exit\n\n", .{});

    // Main thread just waits
    while (device.state == .running) {
        const ts = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
