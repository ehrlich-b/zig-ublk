//! Null block device example
//!
//! Creates a block device that discards all writes and returns zeros on read.
//! This is the simplest possible backend, useful for testing.

const std = @import("std");
const ublk = @import("zig_ublk");

pub fn main() !void {
    std.debug.print("zig-ublk null device example\n", .{});
    std.debug.print("Attempting to open {s}...\n", .{ublk.UBLK_CONTROL_PATH});

    var controller = ublk.Controller.init() catch |err| {
        switch (err) {
            error.DeviceNotFound => {
                std.debug.print("ERROR: {s} not found.\n", .{ublk.UBLK_CONTROL_PATH});
                std.debug.print("Make sure ublk_drv module is loaded: sudo modprobe ublk_drv\n", .{});
                return;
            },
            error.PermissionDenied => {
                std.debug.print("ERROR: Permission denied.\n", .{});
                std.debug.print("Try running with sudo.\n", .{});
                return;
            },
            else => {
                std.debug.print("ERROR: Failed to initialize controller: {}\n", .{err});
                return;
            },
        }
    };
    defer controller.deinit();

    std.debug.print("SUCCESS: Opened {s} (fd={})\n", .{ ublk.UBLK_CONTROL_PATH, controller.control_fd });
    std.debug.print("SUCCESS: Created io_uring with SQE128/CQE32\n", .{});

    // Try ADD_DEV
    std.debug.print("\nCreating device...\n", .{});

    var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = 1;
    dev_info.queue_depth = 64;
    dev_info.max_io_buf_bytes = 512 * 1024; // 512KB
    dev_info.dev_id = 0xFFFF_FFFF; // Let kernel assign ID
    dev_info.ublksrv_pid = @as(i32, @intCast(std.os.linux.getpid()));

    const dev_id = controller.addDevice(&dev_info) catch |err| {
        std.debug.print("ERROR: ADD_DEV failed: {}\n", .{err});
        return;
    };

    std.debug.print("SUCCESS: Device created with ID {d}\n", .{dev_id});
    std.debug.print("\nDevice path: /dev/ublkc{d}\n", .{dev_id});

    // TODO: Phase 2 - Continue device lifecycle
    // 3. Set params
    // 4. Start device
}
