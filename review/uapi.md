# Review: uapi.zig vs internal/uapi/*.go

Maps to: `.go-ublk-ref/internal/uapi/constants.go` and `.go-ublk-ref/internal/uapi/structs.go`

## File Purpose

Defines kernel UAPI (User API) structures and constants that must match the Linux kernel's `ublk_cmd.h` header exactly. This is the ABI boundary.

## Go Implementation Summary

**constants.go** (159 lines):
- Control command constants (`UBLK_CMD_ADD_DEV = 0x04`, etc.)
- IO command constants (`UBLK_IO_FETCH_REQ = 0x20`, etc.)
- Feature flags (`UBLK_F_SUPPORT_ZERO_COPY`, etc.)
- ioctl encoding function `IoctlEncode()` and helpers

**structs.go** (207 lines):
- `UblksrvCtrlCmd` - 32 bytes, control command header
- `UblksrvCtrlDevInfo` - 64 bytes, device information
- `UblksrvIODesc` - 24 bytes, IO descriptor (mmap'd)
- `UblksrvIOCmd` - 16 bytes, IO command header
- `UblkParams*` - Device parameter structures
- Compile-time size checks via `var _ [N]byte = [unsafe.Sizeof(T{})]byte{}`

## Zig Implementation (src/uapi.zig)

**What's there:**

```zig
// Command enums - BETTER than Go (type-safe)
pub const CtrlCmd = enum(u8) {
    add_dev = 0x04,
    del_dev = 0x05,
    // ...
};

pub const IoCmd = enum(u8) {
    fetch_req = 0x20,
    commit_and_fetch_req = 0x21,
    // ...
};

// IO operation enum - BETTER than Go
pub const IoOp = enum(u8) {
    read = 0,
    write = 1,
    flush = 2,
    // ...
};
```

**Struct definitions with comptime size checks:**

```zig
pub const UblksrvCtrlCmd = extern struct {
    dev_id: u32,
    queue_id: u16,
    // ...

    comptime {
        if (@sizeOf(UblksrvCtrlCmd) != 32) {
            @compileError("UblksrvCtrlCmd must be exactly 32 bytes");
        }
    }
};
```

**ioctl encoding:**

```zig
pub fn ublkCtrlCmd(cmd: CtrlCmd) u32 {
    return ioctlEncode(IOC_READ | IOC_WRITE, 'u', @intFromEnum(cmd), 32);
}
```

## Line-by-Line Analysis

### Constants (Go lines 5-125 → Zig)

| Go | Zig | Notes |
|----|-----|-------|
| `UBLK_CMD_ADD_DEV = 0x04` | `CtrlCmd.add_dev = 0x04` | Zig uses enum - type-safe |
| `UBLK_IO_FETCH_REQ = 0x20` | `IoCmd.fetch_req = 0x20` | Zig uses enum - type-safe |
| `UBLK_IO_OP_READ = 0` | `IoOp.read = 0` | Zig uses enum - type-safe |
| `UBLK_F_CMD_IOCTL_ENCODE = 1 << 6` | Missing | **GAP**: Feature flags not defined |

### Structs (Go lines 21-101 → Zig)

**UblksrvCtrlCmd (32 bytes):**
- Go: Plain struct with size check via array trick
- Zig: `extern struct` with comptime assertion
- **Verdict**: Both correct, Zig more explicit

**UblksrvIODesc (24 bytes):**
- Go: Has `GetOp()` and `GetFlags()` methods
- Zig: Has `getOp()`, `getFlags()`, AND `getIoOp()` returning optional enum
- **Verdict**: Zig better - typed enum access

### ioctl Encoding (Go lines 127-158 → Zig lines 56-81)

Both implementations identical in logic:
```
cmd = (dir << 30) | (size << 16) | ('u' << 8) | nr
```

## What's Missing in Zig

1. **Feature flags** - Go has `UBLK_F_*` constants, Zig doesn't expose them
2. **Device state constants** - `UBLK_S_DEV_DEAD`, `UBLK_S_DEV_LIVE`
3. **IO flags** - `UBLK_IO_F_FUA`, etc.
4. **Buffer encoding constants** - `UBLK_IO_BUF_BITS`, etc.
5. **Path helper functions** - `UblkDevicePath()`, `UblkBlockDevicePath()`

## What Zig Does Better

1. **Type-safe enums** - Can't accidentally use wrong command type
2. **Comptime size checks** - Compile error instead of runtime panic
3. **IoOp enum with optional** - `getIoOp()` returns `?IoOp` for safe parsing

## Recommendations

### Add Missing Constants

```zig
// Feature flags
pub const UBLK_F_SUPPORT_ZERO_COPY: u64 = 1 << 0;
pub const UBLK_F_URING_CMD_COMP_IN_TASK: u64 = 1 << 1;
pub const UBLK_F_NEED_GET_DATA: u64 = 1 << 2;
pub const UBLK_F_USER_RECOVERY: u64 = 1 << 3;
pub const UBLK_F_CMD_IOCTL_ENCODE: u64 = 1 << 6;
// etc.

// Device states
pub const DeviceState = enum(u16) {
    dead = 0,
    live = 1,
    quiesced = 2,
};
```

### Add Path Helpers

```zig
pub fn devicePath(buf: *[32]u8, dev_id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "/dev/ublkc{d}", .{dev_id}) catch unreachable;
}

pub fn blockDevicePath(buf: *[32]u8, dev_id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "/dev/ublkb{d}", .{dev_id}) catch unreachable;
}
```

## Test Coverage

Current tests:
- Struct size validation ✓
- IoDesc field extraction ✓
- IoOp enum values ✓
- ioctl encoding ✓
- CtrlCmd/IoCmd enum values ✓

Missing tests:
- Unknown IoOp handling (added in recent commit) ✓
- Feature flag combinations
- Path helper functions (if added)
