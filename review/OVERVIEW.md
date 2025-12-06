# zig-ublk Expert Zig Review

Review from the perspective of an expert Zig developer.

## Executive Summary

The zig-ublk implementation is **functional but not fully idiomatic**. Key issues:

1. **Allocator Passing**: Queue requires allocator at init AND deinit - non-standard
2. **Interface Pattern**: Uses function pointer callback instead of proper Zig interface
3. **Error Handling**: Some places use `std.log.err` instead of returning errors
4. **Global State**: Memory backend example uses global `g_backend` pointer

## Allocation Analysis

### Where We Allocate

| Module | What | When | Idiomatic? |
|--------|------|------|------------|
| `Queue.init` | `tag_states: []TagState` | Init | YES - passed allocator |
| `Queue.init` | `buf_mmap` via mmap | Init | YES - OS allocation |
| `Queue.init` | `desc_mmap` via mmap | Init | YES - OS allocation |
| `Controller.init` | io_uring via mmap | Init | YES - OS allocation |
| Examples | `GeneralPurposeAllocator` | main() | YES - application owns |

### Allocator Passing Pattern Issues

**Current (non-idiomatic):**
```zig
var queue = try Queue.init(dev_id, 0, depth, allocator);
defer queue.deinit(allocator);  // Allocator passed again - WHY?
```

**Idiomatic Zig:**
```zig
var queue = try Queue.init(dev_id, 0, depth, allocator);
defer queue.deinit();  // Queue stores allocator internally
```

The pattern of passing allocator to both `init` and `deinit` is non-standard. Looking at [http.zig](https://github.com/karlseguin/http.zig) and stdlib patterns, the allocator should be stored in the struct if needed for deinit.

## Interface Pattern Analysis

### Current: Function Pointer Callback

```zig
pub const IoHandler = *const fn (
    queue_ptr: *Queue,
    tag: u16,
    desc: UblksrvIoDesc,
    buffer: []u8
) i32;

// Usage
queue.processCompletions(myHandler);
```

### Idiomatic Alternative: Comptime Generic

```zig
pub fn Queue(comptime Backend: type) type {
    return struct {
        backend: Backend,
        // ...

        pub fn processCompletions(self: *@This()) !u32 {
            // Call self.backend.handleIo(...)
        }
    };
}
```

Or using the "fat pointer" interface pattern from [Zig interface idioms](https://zig.news/yglcode/code-study-interface-idiomspatterns-in-zig-standard-libraries-4lkj):

```zig
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handleIo: *const fn (*anyopaque, u16, UblksrvIoDesc, []u8) i32,
    };

    pub fn handleIo(self: Backend, tag: u16, desc: UblksrvIoDesc, buf: []u8) i32 {
        return self.vtable.handleIo(self.ptr, tag, desc, buf);
    }
};
```

## Error Handling Analysis

### Good Patterns (keep these)

```zig
pub const InitError = error{
    DeviceNotFound,
    PermissionDenied,
    IoUringInitFailed,
} || std.posix.OpenError || IoUring128.InitError;
```

Error sets with explicit union - excellent.

### Problematic Patterns

```zig
// In control.zig - logs AND returns error (pick one)
if (cqe.res < 0) {
    std.log.err("ADD_DEV failed with error: {d}", .{cqe.res});
    return error.AddDeviceFailed;
}
```

Either log OR return error, not both. Let caller decide logging.

## Memory Safety Analysis

### Good: Comptime Size Assertions

```zig
comptime {
    if (@sizeOf(UblksrvCtrlCmd) != 32) {
        @compileError("UblksrvCtrlCmd must be exactly 32 bytes");
    }
}
```

### Good: Volatile for mmap'd Memory

```zig
descriptors: []volatile uapi.UblksrvIoDesc,
```

Correct use of volatile for kernel-written memory.

### Potential Issue: Buffer Lifetime

```zig
fn nullHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    // buffer is valid only during this call
    @memset(buffer[0..length], 0);
    return 0;
}
```

This is fine, but documentation should clarify buffer lifetime.

## Comparison with Go Reference

| Aspect | Go | Zig | Verdict |
|--------|-----|-----|---------|
| Memory barriers | `Sfence()`, `Mfence()` | `@fence(.seq_cst)` via atomic ops | Zig OK |
| Allocations | GC handles | Explicit allocator | Zig better |
| Error handling | `error` return | Error union | Zig better |
| Interface | Go interface | Function pointer | Go more flexible |
| Hot path allocs | Pre-allocated pools | mmap'd buffers | Both good |

## Recommendations

### Priority 1: Fix Allocator Pattern

Store allocator in Queue struct:

```zig
pub const Queue = struct {
    allocator: std.mem.Allocator,  // Store it
    // ...

    pub fn deinit(self: *Queue) void {
        self.allocator.free(self.tag_states);  // Use stored allocator
        // ...
    }
};
```

### Priority 2: Consider Comptime Backend

Replace callback with comptime generic for zero-cost abstraction:

```zig
pub fn Device(comptime Backend: type) type {
    return struct {
        controller: Controller,
        queue: Queue,
        backend: Backend,
        // ...
    };
}
```

### Priority 3: Remove Logging from Library

Library code should not log. Return errors and let application handle logging.

### Priority 4: Document Buffer Lifetimes

Add doc comments clarifying when buffers are valid.

## Sources

- [Zig Interface Patterns](https://zig.news/yglcode/code-study-interface-idiomspatterns-in-zig-standard-libraries-4lkj)
- [http.zig API Design](https://github.com/karlseguin/http.zig)
- [Zig Allocator Guide](https://zig.guide/standard-library/allocators/)
- [Leveraging Zig's Allocators](https://www.openmymind.net/Leveraging-Zigs-Allocators/)
