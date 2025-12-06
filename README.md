# zig-ublk

Native Zig implementation of Linux ublk (userspace block device driver).

## What is ublk?

ublk is a Linux kernel feature (6.0+) for creating block devices in userspace. Think FUSE, but for block devices instead of filesystems. Communication happens via io_uring's IORING_OP_URING_CMD for high performance.

## Why Zig?

- **No runtime overhead** - No GC, no hidden allocations
- **Comptime** - Compile-time validation of kernel struct sizes
- **Direct syscall access** - First-class Linux support in stdlib
- **Explicit over implicit** - Memory management is visible and controllable

## Status

**Functional** - Core implementation complete with VM-tested backends.

- Null backend: discards writes, returns zeros (118K IOPS benchmarked)
- Memory backend: RAM-backed block device

Based on the working Go implementation at [go-ublk](https://github.com/ehrlich-b/go-ublk).

## Requirements

- Linux kernel >= 6.0 (6.8+ recommended)
- `ublk_drv` module loaded (`modprobe ublk_drv`)
- Root or CAP_SYS_ADMIN privileges
- Zig 0.16+

## Quick Start

```bash
# Check ublk module
lsmod | grep ublk_drv || sudo modprobe ublk_drv

# Build
zig build

# Run tests
zig build test

# Run null device example (requires root)
sudo zig build run-example-null
```

## Usage

```zig
const std = @import("std");
const ublk = @import("zig_ublk");

fn myHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    // Handle READ/WRITE/FLUSH/DISCARD operations
    const op = desc.getIoOp() orelse return -5;
    switch (op) {
        .read => @memset(buffer[0..desc.nr_sectors * 512], 0),
        .write, .flush, .discard => {},
        else => return -95, // EOPNOTSUPP
    }
    return 0; // Success
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Initialize controller
    var ctrl = try ublk.Controller.init();
    defer ctrl.deinit();

    // 2. Create device
    var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = 1;
    dev_info.queue_depth = 64;
    dev_info.max_io_buf_bytes = 512 * 1024;
    dev_info.dev_id = 0xFFFF_FFFF; // Auto-assign
    dev_info.ublksrv_pid = @intCast(std.os.linux.getpid());
    dev_info.flags = 0x02; // UBLK_F_CMD_IOCTL_ENCODE

    const dev_id = try ctrl.addDevice(&dev_info);
    defer ctrl.deleteDevice(dev_id) catch {};

    // 3. Set parameters
    const params = ublk.UblkParams.initBasic(256 * 1024 * 1024, 512); // 256MB
    var params_buf = ublk.UblkParamsBuffer.init(params);
    try ctrl.setParams(dev_id, &params_buf);

    // 4. Setup queue (must be in separate thread for START_DEV to work)
    var queue = try ublk.Queue.init(dev_id, 0, 64, allocator);
    defer queue.deinit(allocator);

    // 5. Prime queue and start device
    try queue.prime();
    try ctrl.startDevice(dev_id);
    defer ctrl.stopDevice(dev_id) catch {};

    // 6. Process IO in loop
    while (running) {
        _ = try queue.processCompletions(myHandler);
    }
}
```

See `examples/` for complete working implementations.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    User Application                      │
│                    (zig-ublk library)                    │
├──────────────┬──────────────────────────────────────────┤
│   Control    │              IO Queues                    │
│  /dev/ublk-  │         /dev/ublkcN (per device)         │
│   control    │                                          │
├──────────────┴──────────────────────────────────────────┤
│                      io_uring                            │
│              (IORING_OP_URING_CMD)                       │
├─────────────────────────────────────────────────────────┤
│                    Linux Kernel                          │
│                    (ublk_drv module)                     │
├─────────────────────────────────────────────────────────┤
│                   /dev/ublkbN                            │
│               (block device interface)                   │
└─────────────────────────────────────────────────────────┘
```

## License

MIT

## See Also

- [go-ublk](https://github.com/ehrlich-b/go-ublk) - Reference implementation
- [Linux ublk docs](https://docs.kernel.org/block/ublk.html)
- [kernel UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/ublk_cmd.h)
