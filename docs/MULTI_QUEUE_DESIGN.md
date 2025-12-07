# Multi-Queue Support Design Document

## Overview

This document describes the design for adding multi-queue support to zig-ublk, achieving feature parity with go-ublk. Multi-queue allows parallel IO processing across multiple CPU cores, significantly improving throughput for high-performance backends.

## Background

### Current Architecture (Single Queue)

```
┌─────────────────────────────────────────────────────────┐
│                      User Code                          │
│  main() creates Controller, Queue, spawns thread        │
├─────────────────────────────────────────────────────────┤
│                     Controller                          │
│  - Opens /dev/ublk-control                              │
│  - Sends ADD_DEV, SET_PARAMS, START_DEV, etc.           │
├─────────────────────────────────────────────────────────┤
│                       Queue                             │
│  - Opens /dev/ublkcN                                    │
│  - Owns io_uring (SQE128/CQE32)                         │
│  - mmaps descriptors and buffers                        │
│  - Runs IO loop in dedicated thread                     │
└─────────────────────────────────────────────────────────┘
```

Current flow in examples:
1. Create Controller, call ADD_DEV
2. Create single Queue (queue_id=0)
3. Spawn thread, prime queue (submit FETCH_REQs)
4. Call START_DEV from main thread
5. Queue thread processes IO in loop

### go-ublk Multi-Queue Model

Key findings from go-ublk analysis:

1. **One OS thread per queue** - Go uses `runtime.LockOSThread()` to pin each queue's goroutine to a dedicated OS thread. The kernel tracks which thread owns each queue and rejects commands from other threads.

2. **Queues are completely independent** - No shared state between queues. Each has its own:
   - io_uring instance
   - Descriptor mmap (at offset `queue_id * desc_size`)
   - IO buffer allocation
   - Tag state machine

3. **Shared backend must be thread-safe** - The only shared component is the backend (memory, file, etc.). The memory backend uses sharded locking (64KB shards).

4. **Single START_DEV for all queues** - All queues must have FETCH_REQs pending before START_DEV is called. START_DEV activates the entire device, not individual queues.

5. **Optional CPU affinity** - Queues can be pinned to specific CPUs for NUMA optimization.

## Proposed Design

### New Module: `src/device.zig`

Introduce a `Device` struct that orchestrates multiple queues:

```zig
/// Multi-queue device manager
pub const Device = struct {
    allocator: std.mem.Allocator,
    controller: *Controller,
    device_id: u32,

    // Queue management
    queues: []Queue,
    threads: []std.Thread,
    contexts: []QueueContext,

    // Lifecycle state
    state: DeviceState,

    pub const DeviceState = enum {
        created,      // ADD_DEV done
        configured,   // SET_PARAMS done
        starting,     // Queues priming
        running,      // START_DEV done, IO active
        stopping,     // Shutdown in progress
        stopped,      // STOP_DEV done
    };

    pub const Config = struct {
        num_queues: u16 = 0,        // 0 = auto-detect from CPU count
        queue_depth: u16 = 64,
        device_size: u64,
        block_size: u32 = 512,
        cpu_affinity: ?[]const u16 = null,  // Optional CPU pinning
    };

    pub fn init(controller: *Controller, config: Config, allocator: std.mem.Allocator) !Device;
    pub fn deinit(self: *Device) void;

    pub fn start(self: *Device, handler: IoHandler) !void;
    pub fn stop(self: *Device) !void;
};
```

### Queue Context for Thread Communication

```zig
pub const QueueContext = struct {
    queue: *Queue,
    handler: IoHandler,

    // Synchronization
    ready: std.atomic.Value(bool),
    stop: std.atomic.Value(bool),
    error_result: ?anyerror,

    // Optional CPU affinity
    cpu_id: ?u16,
};
```

### Thread Function

```zig
fn queueThreadFn(ctx: *QueueContext) void {
    // Pin to CPU if configured
    if (ctx.cpu_id) |cpu| {
        setCpuAffinity(cpu) catch {};
    }

    // Prime the queue
    ctx.queue.prime() catch |err| {
        ctx.error_result = err;
        return;
    };

    // Signal ready
    ctx.ready.store(true, .release);

    // IO loop
    while (!ctx.stop.load(.acquire)) {
        _ = ctx.queue.processCompletions(ctx.handler) catch |err| {
            ctx.error_result = err;
            break;
        };
    }
}
```

### Startup Sequence

```zig
pub fn start(self: *Device, handler: IoHandler) !void {
    // 1. Initialize all queues
    for (0..self.queues.len) |i| {
        self.queues[i] = try Queue.init(
            self.device_id,
            @intCast(i),  // queue_id
            self.config.queue_depth,
            self.allocator,
        );
    }

    // 2. Spawn threads for all queues
    for (0..self.queues.len) |i| {
        self.contexts[i] = .{
            .queue = &self.queues[i],
            .handler = handler,
            .ready = std.atomic.Value(bool).init(false),
            .stop = std.atomic.Value(bool).init(false),
            .error_result = null,
            .cpu_id = if (self.config.cpu_affinity) |aff|
                aff[i % aff.len] else null,
        };
        self.threads[i] = try std.Thread.spawn(.{}, queueThreadFn, .{&self.contexts[i]});
    }

    // 3. Wait for ALL queues to be primed
    for (self.contexts) |*ctx| {
        while (!ctx.ready.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        // Check for errors during priming
        if (ctx.error_result) |err| return err;
    }

    // 4. Small delay (kernel needs time to see FETCH_REQs)
    std.time.sleep(10 * std.time.ns_per_ms);

    // 5. START_DEV (single call for entire device)
    try self.controller.startDevice(self.device_id);

    self.state = .running;
}
```

### Shutdown Sequence

```zig
pub fn stop(self: *Device) !void {
    // 1. Signal all threads to stop
    for (self.contexts) |*ctx| {
        ctx.stop.store(true, .release);
    }

    // 2. Stop device (wakes up waiting io_urings)
    try self.controller.stopDevice(self.device_id);

    // 3. Join all threads
    for (self.threads) |thread| {
        thread.join();
    }

    // 4. Deinit all queues
    for (self.queues) |*q| {
        q.deinit();
    }

    self.state = .stopped;
}
```

## Changes to Existing Code

### Queue Changes

1. **Accept pre-opened char_fd** - Currently Queue.init() opens /dev/ublkcN. For multi-queue, the Device should open it once and pass it to each queue (or let each queue open its own - both work, go-ublk uses dup()).

```zig
// Option A: Queue opens its own fd (simpler, current behavior)
// Each queue opens /dev/ublkcN independently - kernel handles it

// Option B: Device opens fd, queues dup() it
pub fn initWithFd(char_fd: std.posix.fd_t, queue_id: u16, ...) !Queue {
    const my_fd = try std.posix.dup(char_fd);
    // ... rest of init
}
```

Recommendation: **Keep current behavior** (each queue opens its own fd). It's simpler and the kernel handles concurrent opens correctly.

2. **No other Queue changes needed** - The current Queue implementation already:
   - Takes queue_id as parameter
   - Calculates correct mmap offset based on queue_id
   - Has independent io_uring per instance
   - Tracks its own tag states

### Controller Changes

None required. Controller already supports:
- ADD_DEV with configurable nr_hw_queues
- START_DEV (activates entire device)
- STOP_DEV, DEL_DEV

### IoHandler Signature

Current signature works for multi-queue:

```zig
pub const IoHandler = *const fn (queue: *Queue, tag: u16, desc: UblksrvIoDesc, buffer: []u8) i32;
```

The handler receives the Queue pointer, so it knows which queue the IO came from. For backends that need queue awareness (rare), they can check `queue.queue_id`.

**Thread Safety Note:** The handler will be called from multiple threads concurrently. Backends must be thread-safe:
- Null backend: Already safe (no shared state)
- Memory backend: Needs synchronization (see below)

## Backend Thread Safety

### Memory Backend Updates

The current memory backend in `examples/memory.zig` uses a simple byte array. For multi-queue, it needs thread-safe access:

**Option 1: Global Mutex (Simple, Lower Performance)**
```zig
const MemoryBackend = struct {
    data: []u8,
    mutex: std.Thread.Mutex,

    fn handleIo(self: *MemoryBackend, ...) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        // ... perform IO
    }
};
```

**Option 2: Sharded Locks (go-ublk approach, Higher Performance)**
```zig
const MemoryBackend = struct {
    data: []u8,
    shard_size: usize = 64 * 1024,  // 64KB shards
    shards: []std.Thread.RwLock,

    fn handleIo(self: *MemoryBackend, offset: u64, len: usize, ...) i32 {
        const start_shard = offset / self.shard_size;
        const end_shard = (offset + len - 1) / self.shard_size;

        // Lock all touched shards
        for (start_shard..end_shard + 1) |s| {
            if (is_write) self.shards[s].lock()
            else self.shards[s].lockShared();
        }
        defer for (start_shard..end_shard + 1) |s| {
            if (is_write) self.shards[s].unlock()
            else self.shards[s].unlockShared();
        };

        // ... perform IO
    }
};
```

**Option 3: Lock-Free with Atomics (Complex, Highest Performance)**

For simple backends, sharded RwLocks provide good performance with reasonable complexity.

## CPU Affinity

### Linux sched_setaffinity

Zig's stdlib doesn't have a direct wrapper, but we can use the raw syscall:

```zig
fn setCpuAffinity(cpu_id: u16) !void {
    var mask: [16]usize = [_]usize{0} ** 16;  // 1024 CPUs max
    const word_idx = cpu_id / @bitSizeOf(usize);
    const bit_idx: u6 = @intCast(cpu_id % @bitSizeOf(usize));
    mask[word_idx] = @as(usize, 1) << bit_idx;

    const rc = std.os.linux.syscall3(
        .sched_setaffinity,
        0,  // current thread
        @sizeOf(@TypeOf(mask)),
        @intFromPtr(&mask),
    );

    if (rc != 0) return error.AffinityFailed;
}
```

This is optional but useful for NUMA systems where pinning queue threads to specific CPUs can reduce cache thrashing.

## Auto-Detecting Queue Count

```zig
fn detectQueueCount() u16 {
    // Use CPU count as default
    const cpu_count = std.Thread.getCpuCount() catch 1;
    // Cap at reasonable maximum (kernel typically supports up to 32)
    return @intCast(@min(cpu_count, 32));
}
```

## Example Usage

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Initialize controller
    var controller = try Controller.init();
    defer controller.deinit();

    // Create multi-queue device
    var device = try Device.init(&controller, .{
        .num_queues = 4,           // 4 queues (or 0 for auto)
        .queue_depth = 128,
        .device_size = 1024 * 1024 * 1024,  // 1GB
        .cpu_affinity = &[_]u16{ 0, 1, 2, 3 },  // Pin to CPUs 0-3
    }, allocator);
    defer device.deinit();

    // Create thread-safe backend
    var backend = try MemoryBackend.init(1024 * 1024 * 1024, allocator);
    defer backend.deinit();

    // Start device with handler
    try device.start(backend.handler());
    defer device.stop() catch {};

    std.debug.print("Device running with {} queues\n", .{device.queues.len});

    // Wait for signal...
}
```

## Testing Strategy

### Unit Tests
- Queue creation with different queue_ids (already works)
- Device initialization with various queue counts
- CPU affinity setting (mock or skip on CI)

### VM Integration Tests

1. **Multi-queue null backend**
   - Create device with N queues
   - Run fio with `--numjobs=N` to stress all queues
   - Verify no errors, measure aggregate IOPS

2. **Multi-queue memory backend with verification**
   - Thread-safe memory backend
   - Run fio with verify enabled across multiple jobs
   - Confirm data integrity under concurrent access

3. **Scaling test**
   - Measure IOPS with 1, 2, 4, 8 queues
   - Verify near-linear scaling (CPU bound)

### Benchmark Comparison

```bash
# Single queue (current)
fio --name=single --numjobs=1 --filename=/dev/ublkb0 ...

# Multi-queue
fio --name=multi --numjobs=4 --filename=/dev/ublkb0 ...
```

Expected: ~3-4x IOPS improvement with 4 queues on 4+ core system.

## Implementation Plan

### Phase 1: Core Multi-Queue Infrastructure
1. Create `src/device.zig` with Device struct
2. Implement init/deinit with multiple Queue instances
3. Implement start() with synchronized thread spawning
4. Implement stop() with clean shutdown
5. Update examples/null.zig to use Device (optional, for testing)

### Phase 2: Thread-Safe Memory Backend
1. Add sharded locking to memory backend
2. Update examples/memory.zig to be thread-safe
3. Add multi-queue memory example

### Phase 3: CPU Affinity (Optional)
1. Implement setCpuAffinity() helper
2. Add cpu_affinity config option
3. Document NUMA considerations

### Phase 4: Testing & Benchmarking
1. Add vm-multiqueue-e2e.sh test script
2. Add vm-multiqueue-bench.sh for scaling tests
3. Update benchmark results in TODO.md

## Open Questions

1. **Should Device own Controller or take reference?**
   - Recommendation: Take reference (current design). User may want multiple devices.

2. **Error handling during startup - partial failure?**
   - If queue N fails to start, should we stop queues 0..N-1?
   - Recommendation: Yes, clean shutdown on any failure.

3. **Dynamic queue count changes?**
   - go-ublk doesn't support this. Recommendation: Don't support initially.

4. **Backend interface vs function pointer?**
   - Current: Simple function pointer works
   - Future: Could add Backend trait/interface for more complex backends

## References

- go-ublk implementation: `.go-ublk-ref/backend.go`, `.go-ublk-ref/internal/queue/runner.go`
- Linux ublk docs: https://docs.kernel.org/block/ublk.html
- io_uring multi-threaded guidance: One ring per thread is recommended
