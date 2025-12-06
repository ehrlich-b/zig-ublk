//! Null block device example
//!
//! Creates a block device that discards all writes and returns zeros on read.
//! This is the simplest possible backend, useful for testing.

const std = @import("std");
const ublk = @import("zig-ublk");

pub fn main() !void {
    std.debug.print("zig-ublk null device example\n", .{});
    std.debug.print("Status: Phase 0 (Zig Bootcamp) - not yet implemented\n", .{});

    // TODO: Phase 4 - Implement null backend
    // 1. Create device with null backend
    // 2. Start device
    // 3. Wait for signal
    // 4. Stop and cleanup
}
