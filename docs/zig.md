# Zig 0.16 Knowledge Base

Living documentation of what we've learned about Zig 0.16-dev for this project.

## Version Info

- **Installed:** 0.16.0-dev.1484+d0ba6642b
- **Location:** /opt/zig
- **Stdlib:** /opt/zig/lib/std

## Build System (0.16 Breaking Changes)

The build API changed significantly from 0.13 to 0.16.

### Old API (0.13)
```zig
// BROKEN in 0.16
const lib = b.addStaticLibrary(.{
    .name = "foo",
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});
```

### New API (0.16)
```zig
// Modules are first-class citizens now
// addModule = public (exported to dependents)
// createModule = private (internal use only)

const lib_mod = b.addModule("my_lib", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
});

// Executables take a *Module as root_module
const exe = b.addExecutable(.{
    .name = "my_exe",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "my_lib", .module = lib_mod },
        },
    }),
});

// Tests also take a module
const tests = b.addTest(.{
    .root_module = lib_mod,
});
```

### Key Types
- `Module.CreateOptions` - options for creating a module
- `Module.Import` - `{ .name = "foo", .module = mod }`
- `ExecutableOptions` - requires `.root_module: *Module`
- `TestOptions` - requires `.root_module: *Module`

### build.zig.zon Changes
```zig
.{
    .name = .my_package,        // enum literal, not string!
    .version = "0.0.0",
    .fingerprint = 0x...,       // new required field (zig generates it)
    .minimum_zig_version = "0.16.0-dev...",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## Struct Types for Kernel ABI

### packed struct
- No padding between fields
- Bit-level layout control
- Use for protocol wire formats where every bit matters

### extern struct
- C ABI compatible layout
- Predictable field alignment
- **Use this for kernel structures** - they follow C layout rules

```zig
// For kernel ABI - use extern struct
const UblksrvCtrlCmd = extern struct {
    dev_id: u32,
    queue_id: u16,
    len: u16,
    addr: u64,
    data: u64,
    dev_path_len: u16,
    pad: u16,
    reserved: u32,
};

// Compile-time size check
comptime {
    if (@sizeOf(UblksrvCtrlCmd) != 32) @compileError("wrong size");
}
```

## Comptime

Zig evaluates code at compile time when possible.

```zig
// Compile-time assertions
comptime {
    std.debug.assert(@sizeOf(MyStruct) == 32);
}

// Compile-time parameters (generics)
fn GenericList(comptime T: type) type {
    return struct {
        items: []T,
    };
}
```

## Error Handling

```zig
// Error sets
const MyError = error{
    DeviceNotFound,
    PermissionDenied,
    SystemOutdated,
};

// Error union return type
fn doThing() MyError!u32 {
    return error.DeviceNotFound;
}

// Using try (propagates error)
const result = try doThing();

// Using catch (handle error)
const result = doThing() catch |err| {
    std.log.err("failed: {}", .{err});
    return err;
};

// errdefer - runs on error return
fn openAndProcess() !void {
    const fd = try open();
    errdefer close(fd);  // only runs if function returns error
    try process(fd);
}
```

## Linux Syscalls

Location: `/opt/zig/lib/std/os/linux.zig` and `/opt/zig/lib/std/os/linux/`

```zig
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// File operations
const fd = try posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
defer posix.close(fd);

// mmap
const ptr = linux.mmap(
    null,           // addr hint
    4096,           // length
    linux.PROT.READ | linux.PROT.WRITE,
    .{ .TYPE = .SHARED },
    fd,
    0               // offset
);
if (ptr == linux.MAP_FAILED) {
    return error.MmapFailed;
}
```

## io_uring in Zig

Location: `/opt/zig/lib/std/os/linux/IoUring.zig`

### Available Constants
```zig
const linux = std.os.linux;

// Setup flags - ALL AVAILABLE in 0.16!
linux.IORING_SETUP_SQE128     // 1 << 10 - 128-byte SQEs
linux.IORING_SETUP_CQE32      // 1 << 11 - 32-byte CQEs
linux.IORING_SETUP_SQPOLL     // kernel-side SQ polling
linux.IORING_SETUP_IOPOLL     // busy-wait for completions

// Operations
linux.IORING_OP.URING_CMD     // opcode 27 - for ublk!
linux.IORING_OP.READ
linux.IORING_OP.WRITE
// ... many more
```

### The Problem: SQE Size

The stdlib `io_uring_sqe` is 64 bytes:
```zig
// From /opt/zig/lib/std/os/linux/io_uring_sqe.zig
pub const io_uring_sqe = extern struct {
    opcode: linux.IORING_OP,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    rw_flags: u32,
    user_data: u64,
    buf_index: u16,
    personality: u16,
    splice_fd_in: i32,
    addr3: u64,
    resv: u64,
};  // 64 bytes total
```

For URING_CMD with SQE128, we need 128 bytes with an 80-byte cmd area at bytes 48-127.

**We will need to:**
1. Use raw `io_uring_setup` syscall with SQE128|CQE32 flags
2. Define our own 128-byte SQE struct
3. mmap the rings ourselves
4. OR figure out if IoUring.init_params() can handle this

### Using IoUring

```zig
const IoUring = std.os.linux.IoUring;

// Basic init (no SQE128)
var ring = try IoUring.init(32, 0);
defer ring.deinit();

// With custom params
var params = std.mem.zeroInit(linux.io_uring_params, .{
    .flags = linux.IORING_SETUP_SQE128 | linux.IORING_SETUP_CQE32,
});
var ring = try IoUring.init_params(32, &params);
```

## Memory Barriers

For io_uring, we need memory barriers between user/kernel.

**IMPORTANT:** Zig 0.16 removed `@fence()`. Use atomic operations with ordering instead:

```zig
// Zig 0.16+ - use atomic operations directly
_ = @atomicLoad(u32, ptr, .acquire);    // Load with acquire semantics
@atomicStore(u32, ptr, value, .release); // Store with release semantics

// The ordering ensures:
// - .acquire: all subsequent reads see writes before this load
// - .release: all prior writes are visible before this store
```

## SQE128/CQE32 Support (SOLVED)

The stdlib IoUring does NOT support SQE128/CQE32:
- It mmaps `sq_entries * @sizeOf(io_uring_sqe)` = 64 bytes per SQE
- It mmaps `cq_entries * @sizeOf(io_uring_cqe)` = 16 bytes per CQE

**Our solution:** `IoUring128` in src/root.zig
- Uses raw `io_uring_setup` syscall with SQE128|CQE32 flags
- mmaps with correct sizes (128 bytes/SQE, 32 bytes/CQE)
- Defines custom `IoUringSqe128` and `IoUringCqe32` structs

## Resolved Questions

- [x] Test if IoUring.init_params with SQE128 flag actually works
  - **Answer:** It doesn't - the mmap size calculation is wrong
- [x] Understand how to access the extra 64 bytes of SQE128
  - **Answer:** The cmd area is bytes 48-127. Use `sqe.getCmd(T)` helper
- [x] Figure out CQE32 handling (stdlib cqe is 16 bytes)
  - **Answer:** Created IoUringCqe32 with 16-byte `big_cqe` field
- [ ] Test extern struct alignment matches kernel expectations
