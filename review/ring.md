# Review: ring.zig vs internal/uring/minimal.go

Maps to: `.go-ublk-ref/internal/uring/minimal.go`

## File Purpose

Custom io_uring wrapper that handles SQE128/CQE32 mode required for URING_CMD operations. The stdlib io_uring doesn't support these modes.

## Go Implementation Summary (995 lines)

```go
type minimalRing struct {
    ringFd    int
    targetFd  int
    params    io_uring_params
    sqAddr    unsafe.Pointer
    cqAddr    unsafe.Pointer
    sqesAddr  unsafe.Pointer

    // Hot path optimizations
    sqePool       sqe128          // Reusable SQE
    resultsPool   []Result        // Reusable results
    cqePool       []minimalResult // Pool to avoid alloc
    sqTailLocal   uint32          // Local tail for batching
}

// Memory barriers
func Sfence()  // Store fence
func Mfence()  // Full fence
```

Key features:
- Pre-allocated pools for hot path
- Batched submissions (prepare → flush pattern)
- EINTR handling in wait loops
- Memory barriers for kernel communication

## Zig Implementation (src/ring.zig, 440 lines)

```zig
pub const IoUring128 = struct {
    fd: linux.fd_t = -1,
    sq_ring: []align(page_size) u8 = &.{},
    sqes_mmap: []align(page_size) u8 = &.{},

    // Ring pointers
    sq_head: *u32 = undefined,
    sq_tail: *u32 = undefined,
    sq_mask: u32 = 0,
    cq_head: *u32 = undefined,
    cq_tail: *u32 = undefined,
    cq_mask: u32 = 0,

    // Typed arrays
    sqes: []IoUringSqe128 = &.{},
    cqes: []IoUringCqe32 = &.{},

    // Tracking
    sqe_head: u32 = 0,
    sqe_tail: u32 = 0,
    features: u32 = 0,

    pub fn init(entries: u32) InitError!IoUring128
    pub fn deinit(self: *IoUring128) void
    pub fn getSqe(self: *IoUring128) GetSqeError!*IoUringSqe128
    pub fn submit(self: *IoUring128) SubmitError!u32
    pub fn submitAndWait(self: *IoUring128, wait_nr: u32) SubmitError!u32
    pub fn copyCqes(self: *IoUring128, cqes: []IoUringCqe32) u32
    pub fn cqReady(self: *IoUring128) u32
};
```

## Key Comparison Points

### 1. SQE128 Structure

**Go:**
```go
type sqe128 struct {
    opcode      uint8
    flags       uint8
    ioprio      uint16
    fd          int32
    union0      [8]byte   // off/addr2/cmd_op
    addr        uint64
    len         uint32
    opcodeFlags uint32
    userData    uint64
    bufIndex    uint16
    personality uint16
    spliceFdIn  int32
    cmd         [80]byte  // URING_CMD area
}
```

**Zig:**
```zig
pub const IoUringSqe128 = extern struct {
    opcode: linux.IORING_OP,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    opflags: extern union { ... },
    user_data: u64,
    buf: extern union { ... },
    personality: u16,
    splice_fd_in_or_file_index: extern union { ... },
    addr3_or_cmd: extern union { ... },
    __pad2: [1]u64,
    big_sqe_extra: [64]u8,

    comptime { assert(@sizeOf(IoUringSqe128) == 128); }
};
```

**Analysis:**
- Zig: More explicit union types, comptime size check
- Go: Simpler, but relies on runtime size assertion
- Both: Correct 128-byte layout

### 2. Memory Barriers

**Go:**
```go
// In barrier.go (platform-specific)
func Sfence() {
    // Store fence before tail update
    unix.Mfence()  // or inline asm
}

// Usage
Sfence()
atomic.StoreUint32(sqTail, newTail)
```

**Zig:**
```zig
// Uses atomic operations which imply barriers
_ = @atomicRmw(u32, self.sq_tail, .Add, 1, .release);

// Or explicit fence
@fence(.seq_cst);
```

**Analysis:**
- Go: Explicit barriers with assembly
- Zig: Atomic operations with memory ordering semantics
- Both correct, Zig more portable

### 3. Batched Submissions

**Go:**
```go
// Prepare without syscall
func (r *minimalRing) PrepareIOCmd(cmd uint32, ioCmd *uapi.UblksrvIOCmd, userData uint64) error {
    // Write to sqe
    r.prepareSQE(sqe)  // Updates sqTailLocal
    return nil
}

// Submit all prepared
func (r *minimalRing) FlushSubmissions() (uint32, error) {
    pending := r.sqTailLocal - currentTail
    Sfence()
    atomic.StoreUint32(sqTail, r.sqTailLocal)
    return r.submitOnly(pending)  // ONE syscall
}
```

**Zig:**
```zig
pub fn getSqe(self: *IoUring128) GetSqeError!*IoUringSqe128 {
    // Check space, return pointer to SQE slot
    const index = self.sqe_tail & self.sq_mask;
    return &self.sqes[index];
}

pub fn submit(self: *IoUring128) SubmitError!u32 {
    // Update tail and call io_uring_enter
}
```

**Analysis:**
- Go: Explicit prepare/flush separation for batching
- Zig: `getSqe` returns pointer, caller fills it, then `submit`
- Both achieve batching, Go more explicit about it

### 4. Hot Path Allocations

**Go:**
```go
// Pre-allocated pools
type minimalRing struct {
    sqePool      sqe128          // Reusable SQE
    resultsPool  []Result        // Reusable results slice
    cqePool      []minimalResult // Pool of result structs
    cqePoolIndex int
}

func (r *minimalRing) WaitForCompletion(timeout int) ([]Result, error) {
    r.resultsPool = r.resultsPool[:0]  // Reset, keep capacity
    r.cqePoolIndex = 0

    // Use pool entries
    if r.cqePoolIndex < r.cqePoolSize {
        res = &r.cqePool[r.cqePoolIndex]
        r.cqePoolIndex++
    }
}
```

**Zig:**
```zig
// Caller provides buffer
pub fn copyCqes(self: *IoUring128, cqes: []IoUringCqe32) u32 {
    // Copy directly to caller's buffer
}

// Usage in Queue
var cqes: [64]IoUringCqe32 = undefined;  // Stack allocated!
const count = self.uring.copyCqes(&cqes);
```

**Analysis:**
- Go: Internal pooling, returns slice
- Zig: Caller provides buffer, stack allocation in caller
- Zig simpler and faster (no pool management)

### 5. Error Handling

**Go:**
```go
func (r *minimalRing) submitAndWaitRing(toSubmit, minComplete uint32) (submitted, completed uint32, errno syscall.Errno) {
    r1, r2, err := syscall.Syscall6(unix.SYS_IO_URING_ENTER, ...)
    return uint32(r1), uint32(r2), err
}
```

**Zig:**
```zig
pub fn submitAndWait(self: *IoUring128, wait_nr: u32) SubmitError!u32 {
    const res = linux.io_uring_enter(self.fd, sq_to_submit, wait_nr, flags, null);
    switch (linux.errno(res)) {
        .SUCCESS => return @intCast(res),
        .INTR => continue,  // Retry on signal
        // ... error mapping
    }
}
```

**Analysis:**
- Go: Returns raw errno, caller interprets
- Zig: Error union with specific error types
- Zig more type-safe

## What's Missing in Zig

1. **RegisterFiles** - Go registers FDs with io_uring
2. **Async handle pattern** - Go has `SubmitCtrlCmdAsync` + `AsyncHandle.Wait`
3. **EINTR retry loop** - Zig has it but less explicit

## What Zig Does Better

1. **Comptime size assertions** - Catches ABI mismatch at compile time
2. **Type-safe enums** - `linux.IORING_OP.URING_CMD`
3. **No internal allocation** - Caller provides buffers
4. **Cleaner error types** - Error union vs errno

## Recommendations

### 1. Add RegisterFiles (for queue FD registration)

```zig
pub fn registerFiles(self: *IoUring128, fds: []const i32) !void {
    const res = linux.io_uring_register(
        self.fd,
        linux.IORING_REGISTER_FILES,
        @ptrCast(fds.ptr),
        @intCast(fds.len),
    );
    if (linux.errno(res) != .SUCCESS) {
        return error.RegisterFilesFailed;
    }
}
```

### 2. Explicit Batch API

Current API is implicit (getSqe → submit). Make explicit:

```zig
pub const Batch = struct {
    ring: *IoUring128,
    count: u32 = 0,

    pub fn add(self: *Batch) !*IoUringSqe128 {
        const sqe = try self.ring.getSqe();
        self.count += 1;
        return sqe;
    }

    pub fn flush(self: *Batch) !u32 {
        defer self.count = 0;
        return self.ring.submit();
    }
};
```

### 3. Document Memory Ordering

```zig
/// Get next available SQE slot.
///
/// Memory ordering: The returned SQE can be written without barriers.
/// Call `submit()` after filling the SQE to ensure visibility to kernel.
/// The submit call includes necessary store fence before updating tail.
pub fn getSqe(self: *IoUring128) GetSqeError!*IoUringSqe128 {
    // ...
}
```
