# Review: queue.zig vs internal/queue/runner.go

Maps to: `.go-ublk-ref/internal/queue/runner.go`

## File Purpose

Queue runner handles the IO processing loop for a single ublk queue. This is the **hot path** - performance critical code that processes every block IO operation.

## Go Implementation Summary (734 lines)

```go
type Runner struct {
    deviceID     uint32
    queueID      uint16
    depth        int
    backend      interfaces.Backend       // Interface!
    charDeviceFd int
    ring         uring.Ring
    descPtr      unsafe.Pointer           // mmap'd descriptors
    bufPtr       unsafe.Pointer           // mmap'd IO buffers
    tagStates    []TagState
    tagMutexes   []sync.Mutex             // Per-tag mutexes
    ioCmds       []uapi.UblksrvIOCmd      // Pre-allocated commands
    logger       interfaces.Logger
    observer     interfaces.Observer       // Metrics
    cpuAffinity  []int
    ctx          context.Context
    cancel       context.CancelFunc
}

func NewRunner(ctx context.Context, config Config) (*Runner, error)
func (r *Runner) Start() error
func (r *Runner) Prime() error
func (r *Runner) Stop() error
func (r *Runner) Close() error
```

Key Go features:
- Backend interface for polymorphism
- Context for cancellation
- Per-tag mutexes for thread safety
- Pre-allocated ioCmds to avoid hot-path allocations
- CPU affinity support
- Observer for metrics

## Zig Implementation (src/queue.zig, 267 lines)

```zig
pub const Queue = struct {
    device_id: u32,
    queue_id: u16,
    depth: u16,
    char_fd: std.posix.fd_t,
    uring: IoUring128,
    desc_mmap: []align(page_size) u8,
    buf_mmap: []align(page_size) u8,
    descriptors: []volatile uapi.UblksrvIoDesc,
    buffers_base: [*]u8,
    tag_states: []TagState,

    pub fn init(device_id: u32, queue_id: u16, depth: u16, allocator: Allocator) InitError!Queue
    pub fn deinit(self: *Queue, allocator: Allocator) void
    pub fn prime(self: *Queue) QueueError!void
    pub fn processCompletions(self: *Queue, handler: IoHandler) QueueError!u32
    pub fn getBuffer(self: *Queue, tag: u16) []u8
};
```

## Critical Difference: Backend Interface

### Go: Interface Injection

```go
type Backend interface {
    ReadAt(p []byte, off int64) (n int, err error)
    WriteAt(p []byte, off int64) (n int, err error)
    Flush() error
    Size() int64
}

// Usage in runner
_, err = r.backend.ReadAt(buffer, int64(offset))
```

### Zig: Function Pointer Callback

```zig
pub const IoHandler = *const fn (
    queue_ptr: *Queue,
    tag: u16,
    desc: uapi.UblksrvIoDesc,
    buffer: []u8
) i32;

// Usage
const io_result = handler(self, tag, desc, buffer);
```

**Analysis:**
- Go: True interface - backend stored in struct, called per-operation
- Zig: Callback passed to `processCompletions` - less flexible
- Go: Backend can have state (file handles, memory pointers)
- Zig: Handler is stateless function, needs global state hack

**Problem with Zig approach:**
```zig
// In examples/memory.zig - GLOBAL STATE HACK
var g_backend: ?*MemoryBackend = null;

fn memoryHandler(queue: *ublk.Queue, tag: u16, desc: ublk.UblksrvIoDesc, buffer: []u8) i32 {
    const backend = g_backend orelse return -5;  // Access global!
    // ...
}
```

This is not idiomatic. Should use comptime generics or fat-pointer interface.

## Allocation Analysis

### Go Allocations

```go
// In NewRunner
r := &Runner{                           // Heap allocation
    tagStates:    make([]TagState, depth),  // Slice allocation
    tagMutexes:   make([]sync.Mutex, depth), // Slice allocation
    ioCmds:       make([]uapi.UblksrvIOCmd, depth), // Pre-allocated!
}
```

### Zig Allocations

```zig
// In Queue.init
const tag_states = allocator.alloc(TagState, depth) catch return error.OutOfMemory;
```

**Issue**: Allocator passed to both init AND deinit:
```zig
var queue = try Queue.init(dev_id, 0, depth, allocator);
defer queue.deinit(allocator);  // WHY PASS AGAIN?
```

**Fix**: Store allocator in struct:
```zig
pub const Queue = struct {
    allocator: std.mem.Allocator,  // Store it
    tag_states: []TagState,
    // ...

    pub fn deinit(self: *Queue) void {
        self.allocator.free(self.tag_states);
        // ...
    }
};
```

## Hot Path Analysis

### Go Hot Path (processRequests)

```go
func (r *Runner) processRequests() error {
    completions, err := r.ring.WaitForCompletion(0)  // Block for completions

    for _, completion := range completions {
        // Process each completion
        if err := r.handleCompletion(tag, isCommit, result); err != nil {
            return err
        }
    }

    // ONE syscall for all submissions
    if _, err := r.ring.FlushSubmissions(); err != nil {
        return err
    }
    return nil
}
```

### Zig Hot Path (processCompletions)

```zig
pub fn processCompletions(self: *Queue, handler: IoHandler) QueueError!u32 {
    _ = try self.uring.submitAndWait(1);  // Block for completions

    var cqes: [64]IoUringCqe32 = undefined;
    const count = self.uring.copyCqes(&cqes);

    for (cqes[0..count]) |cqe| {
        // ... process completion, call handler
        try self.submitCommitAndFetch(tag, commit_result);
    }

    // Flush submissions
    _ = try self.uring.submit();
    return count;
}
```

**Comparison:**
- Both batch completions
- Both use single syscall for submissions
- Go: Pre-allocated `ioCmds[]` avoids allocation
- Zig: Stack-allocated `cqes[64]` - good
- Go: Per-tag mutexes for thread safety
- Zig: No mutexes (single-threaded queue) - simpler, correct

## State Machine Comparison

### Go TagState

```go
type TagState int
const (
    TagStateInFlightFetch TagState = iota
    TagStateOwned
    TagStateInFlightCommit
)
```

### Zig TagState

```zig
pub const TagState = enum {
    in_flight_fetch,
    owned,
    in_flight_commit,
};
```

Identical logic, both correct.

## Memory Mapping

### Go mmap

```go
func mmapQueues(fd int, queueID uint16, depth int) (unsafe.Pointer, unsafe.Pointer, error) {
    // Descriptor array - READ ONLY
    descPtr, _, errno := syscall.Syscall6(syscall.SYS_MMAP, ...)

    // IO buffers - ANONYMOUS
    bufPtr, _, errno := syscall.Syscall6(syscall.SYS_MMAP, ...)
}
```

### Zig mmap

```zig
// Descriptor array
const desc_mmap = std.posix.mmap(
    null, desc_size,
    std.posix.PROT.READ,  // READ ONLY - correct
    .{ .TYPE = .SHARED, .POPULATE = true },
    char_fd, mmap_offset,
) catch return error.MmapFailed;

// IO buffers
const buf_mmap = std.posix.mmap(
    null, buf_size,
    std.posix.PROT.READ | std.posix.PROT.WRITE,
    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
    -1, 0,
) catch return error.MmapFailed;
```

Both correct. Zig uses stdlib wrapper which is cleaner.

## What's Missing in Zig

1. **Backend interface** - Go has proper interface, Zig has callback
2. **CPU affinity** - Go supports pinning to CPU
3. **Metrics observer** - Go has `Observer` interface for metrics
4. **Context cancellation** - Go uses context for graceful shutdown
5. **Pre-allocated IO commands** - Go avoids hot-path allocation

## What Zig Does Better

1. **No mutexes** - Single-threaded queue design, simpler
2. **Stack-allocated CQE buffer** - `var cqes: [64]IoUringCqe32 = undefined`
3. **Volatile descriptors** - `[]volatile uapi.UblksrvIoDesc` - correct for mmap'd memory
4. **No logging** - Library doesn't log (except error paths)

## Recommendations

### 1. Fix Allocator Pattern (HIGH PRIORITY)

```zig
pub const Queue = struct {
    allocator: std.mem.Allocator,
    // ... other fields

    pub fn init(device_id: u32, queue_id: u16, depth: u16, allocator: std.mem.Allocator) InitError!Queue {
        // ...
        return Queue{
            .allocator = allocator,
            .tag_states = tag_states,
            // ...
        };
    }

    pub fn deinit(self: *Queue) void {
        self.allocator.free(self.tag_states);
        std.posix.munmap(self.buf_mmap);
        std.posix.munmap(self.desc_mmap);
        self.uring.deinit();
        std.posix.close(self.char_fd);
    }
};
```

### 2. Proper Backend Interface (HIGH PRIORITY)

**Option A: Comptime Generic (zero-cost)**
```zig
pub fn Queue(comptime Backend: type) type {
    return struct {
        backend: Backend,
        // ... other fields

        pub fn processCompletions(self: *@This()) !u32 {
            // ... for each IO
            const result = switch (op) {
                .read => self.backend.readAt(buffer, offset),
                .write => self.backend.writeAt(buffer, offset),
                // ...
            };
        }
    };
}

// Usage
const MyQueue = Queue(MemoryBackend);
var queue = try MyQueue.init(dev_id, 0, depth, allocator, &backend);
```

**Option B: Fat-pointer Interface (runtime flexible)**
```zig
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readAt: *const fn (*anyopaque, []u8, u64) Error!usize,
        writeAt: *const fn (*anyopaque, []const u8, u64) Error!usize,
        flush: *const fn (*anyopaque) Error!void,
        size: *const fn (*anyopaque) u64,
    };

    pub fn readAt(self: Backend, buf: []u8, off: u64) Error!usize {
        return self.vtable.readAt(self.ptr, buf, off);
    }
    // ... other methods
};
```

### 3. Add Pre-allocated IO Commands

```zig
pub const Queue = struct {
    io_cmds: []uapi.UblksrvIoCmd,  // Pre-allocated per tag

    pub fn init(...) !Queue {
        const io_cmds = try allocator.alloc(uapi.UblksrvIoCmd, depth);
        // ...
    }
};
```

This avoids any allocation in the hot path.

### 4. Consider Context/Cancellation

```zig
pub const Queue = struct {
    stop_flag: std.atomic.Value(bool),

    pub fn stop(self: *Queue) void {
        self.stop_flag.store(true, .release);
    }

    pub fn processCompletions(self: *Queue, ...) !u32 {
        if (self.stop_flag.load(.acquire)) return 0;
        // ...
    }
};
```
