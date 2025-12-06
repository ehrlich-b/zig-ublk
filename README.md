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

**Early development** - Currently in Phase 0 (Zig Bootcamp), learning the Zig APIs we need.

Based on the working Go implementation at [go-ublk](https://github.com/ehrlich-b/go-ublk).

## Requirements

- Linux kernel >= 6.0 (6.8+ recommended)
- `ublk_drv` module loaded (`modprobe ublk_drv`)
- Root or CAP_SYS_ADMIN privileges
- Zig 0.13+

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
const ublk = @import("zig-ublk");

pub fn main() !void {
    // Create a null block device (discards all writes, returns zeros on read)
    var device = try ublk.create(.{
        .size = 1024 * 1024 * 1024, // 1GB
        .backend = ublk.NullBackend{},
    });
    defer device.destroy();

    try device.start();
    // Device is now available at /dev/ublkbN

    // ... wait for signal ...

    try device.stop();
}
```

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
