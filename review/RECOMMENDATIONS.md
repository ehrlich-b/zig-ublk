# Recommendations for Idiomatic zig-ublk

Based on expert Zig review and comparison with go-ublk reference implementation.

## Priority 1: Critical Issues

### 1.1 Fix Allocator Pattern in Queue ✅ DONE

**Issue:** Allocator was passed to both init AND deinit - anti-pattern.

**Fix applied:** Queue now stores allocator internally. `deinit()` takes no arguments.

```zig
// Before (anti-pattern)
var queue = try Queue.init(dev_id, 0, depth, allocator);
defer queue.deinit(allocator);  // Allocator passed TWICE

// After (idiomatic)
var queue = try Queue.init(dev_id, 0, depth, allocator);
defer queue.deinit();  // No allocator needed
```

### 1.2 Remove Logging from Library Code ✅ DONE

**Issue:** Library code was logging AND returning errors.

**Fix applied:** All `std.log.err()` and `std.log.warn()` calls removed from:
- `src/control.zig` - all control commands
- `src/queue.zig` - processCompletions

Library now only returns typed errors. Callers decide logging policy.

## Priority 2: API Improvements

### 2.1 Backend Interface (Replaces Global State)

**Current (anti-pattern):**
```zig
// In examples/memory.zig
var g_backend: ?*MemoryBackend = null;  // GLOBAL STATE

fn memoryHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    const backend = g_backend orelse return -5;  // Access global
}
```

**Fix Option A: Comptime Generic (recommended for performance)**
```zig
pub fn Queue(comptime Backend: type) type {
    return struct {
        const Self = @This();

        backend: *Backend,
        allocator: std.mem.Allocator,
        // ... other fields

        pub fn init(
            device_id: u32,
            queue_id: u16,
            depth: u16,
            allocator: std.mem.Allocator,
            backend: *Backend,
        ) !Self {
            // ...
            return Self{
                .backend = backend,
                .allocator = allocator,
                // ...
            };
        }

        pub fn processCompletions(self: *Self) !u32 {
            // ... for each IO
            const result = switch (op) {
                .read => self.backend.readAt(buffer, offset),
                .write => self.backend.writeAt(buffer, offset),
                .flush => self.backend.flush(),
                .discard => self.backend.discard(offset, len),
            };
        }
    };
}

// Backend must implement
pub const MemoryBackend = struct {
    storage: []u8,

    pub fn readAt(self: *MemoryBackend, buf: []u8, off: u64) i32 {
        @memcpy(buf, self.storage[off..][0..buf.len]);
        return 0;
    }

    pub fn writeAt(self: *MemoryBackend, buf: []const u8, off: u64) i32 {
        @memcpy(self.storage[off..][0..buf.len], buf);
        return 0;
    }

    pub fn flush(self: *MemoryBackend) i32 {
        _ = self;
        return 0;
    }

    pub fn discard(self: *MemoryBackend, off: u64, len: usize) i32 {
        @memset(self.storage[off..][0..len], 0);
        return 0;
    }
};

// Usage
const MemQueue = Queue(MemoryBackend);
var backend = MemoryBackend{ .storage = storage };
var queue = try MemQueue.init(dev_id, 0, depth, allocator, &backend);
```

**Fix Option B: Fat-pointer Interface (for runtime flexibility)**
```zig
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readAt: *const fn (*anyopaque, []u8, u64) i32,
        writeAt: *const fn (*anyopaque, []const u8, u64) i32,
        flush: *const fn (*anyopaque) i32,
        discard: *const fn (*anyopaque, u64, usize) i32,
    };

    pub fn readAt(self: Backend, buf: []u8, off: u64) i32 {
        return self.vtable.readAt(self.ptr, buf, off);
    }
    // ... etc
};

// Create backend from concrete type
pub fn backend(comptime T: type, ptr: *T) Backend {
    return Backend{
        .ptr = ptr,
        .vtable = &.{
            .readAt = struct {
                fn f(p: *anyopaque, buf: []u8, off: u64) i32 {
                    return @as(*T, @ptrCast(@alignCast(p))).readAt(buf, off);
                }
            }.f,
            // ... etc
        },
    };
}
```

### 2.2 High-Level Device Config API

**Current (verbose):**
```zig
var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
dev_info.nr_hw_queues = 1;
dev_info.queue_depth = 64;
dev_info.max_io_buf_bytes = 512 * 1024;
dev_info.dev_id = 0xFFFF_FFFF;
dev_info.ublksrv_pid = @intCast(std.os.linux.getpid());
dev_info.flags = 0x02;
const dev_id = try controller.addDevice(&dev_info);
```

**Add high-level API:**
```zig
pub const DeviceConfig = struct {
    queues: u16 = 1,
    depth: u16 = 64,
    max_io_size: u32 = 512 * 1024,
    size: u64,  // Device size in bytes
    block_size: u32 = 512,
    features: Features = .{},

    pub const Features = packed struct {
        ioctl_encode: bool = true,
        user_copy: bool = false,
        zero_copy: bool = false,
        unprivileged: bool = false,
        _padding: u4 = 0,
    };
};

// In Controller
pub fn createDevice(self: *Controller, config: DeviceConfig) !Device {
    var dev_info = std.mem.zeroInit(uapi.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = config.queues;
    dev_info.queue_depth = config.depth;
    dev_info.max_io_buf_bytes = config.max_io_size;
    dev_info.dev_id = 0xFFFF_FFFF;
    dev_info.ublksrv_pid = @intCast(std.os.linux.getpid());
    dev_info.flags = buildFlags(config.features);

    const dev_id = try self.addDevice(&dev_info);
    // ... set params, return Device handle
}

// Usage
const device = try controller.createDevice(.{
    .size = 256 * 1024 * 1024,  // 256MB
    .depth = 128,
});
```

## Priority 3: Missing Features

### 3.1 Add Feature Flag Constants ✅ DONE

Added to `src/uapi.zig`:
- `UBLK_F_SUPPORT_ZERO_COPY`, `UBLK_F_URING_CMD_COMP_IN_TASK`, `UBLK_F_NEED_GET_DATA`
- `UBLK_F_USER_RECOVERY`, `UBLK_F_USER_RECOVERY_REISSUE`, `UBLK_F_UNPRIVILEGED_DEV`
- `UBLK_F_CMD_IOCTL_ENCODE`, `UBLK_F_USER_COPY`, `UBLK_F_ZONED`
- `DeviceState` enum (dead, live, quiesced)
- `devicePath()` and `blockDevicePath()` helper functions

Tests added for all new constants.

### 3.2 Add GetParams to Controller

```zig
pub fn getParams(self: *Controller, dev_id: u32) ControlError!params.UblkParams {
    var params_buf: params.UblkParamsBuffer = undefined;
    // ... similar to setParams but GET_PARAMS command
    return params_buf.params;
}
```

### 3.3 Add Stop Flag for Graceful Shutdown

```zig
pub const Queue = struct {
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn requestStop(self: *Queue) void {
        self.stop_flag.store(true, .release);
    }

    pub fn processCompletions(self: *Queue, ...) !u32 {
        if (self.stop_flag.load(.acquire)) return 0;
        // ... normal processing
    }
};
```

## Summary of Files Modified

| File | Changes | Status |
|------|---------|--------|
| `src/queue.zig` | Store allocator internally | ✅ Done |
| `src/queue.zig` | Remove logging | ✅ Done |
| `src/control.zig` | Remove logging | ✅ Done |
| `src/uapi.zig` | Add feature flags, device states, path helpers | ✅ Done |
| `src/root.zig` | Export new types, fix doc comment | ✅ Done |
| `examples/*.zig` | Update to use new deinit() API | ✅ Done |

## Remaining Work

| File | Changes | Status |
|------|---------|--------|
| `src/queue.zig` | Add backend generic/interface | 🔲 Pending (Priority 2) |
| `src/queue.zig` | Add stop flag for graceful shutdown | 🔲 Pending (Priority 3) |
| `src/control.zig` | Add high-level config API | 🔲 Pending (Priority 2) |
| `src/control.zig` | Add getParams | 🔲 Pending (Priority 3) |
| `src/root.zig` | Re-export new types | ✅ Done |
| `examples/*.zig` | Remove global state (needs backend interface) | 🔲 Pending (Priority 2) |

## Testing Changes

After implementing, ensure:
1. `zig build test` passes
2. `make vm-simple-e2e` passes
3. `make vm-memory-e2e` passes
4. `make vm-benchmark` shows similar or better performance

## References

- [Zig Interface Patterns](https://zig.news/yglcode/code-study-interface-idiomspatterns-in-zig-standard-libraries-4lkj)
- [http.zig API](https://github.com/karlseguin/http.zig) - Good example of allocator handling
- [Zig Allocator Guide](https://zig.guide/standard-library/allocators/)
- [std.ArrayList source](https://github.com/ziglang/zig/blob/master/lib/std/array_list.zig) - Pattern for storing allocator
