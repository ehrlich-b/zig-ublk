# zig-ublk API Surface Area

Living documentation of the Zig stdlib APIs we use and how we use them.

## std.os.linux

### Constants We Need

```zig
const linux = std.os.linux;

// io_uring setup flags
linux.IORING_SETUP_SQE128      // 128-byte SQEs (for cmd area)
linux.IORING_SETUP_CQE32       // 32-byte CQEs

// io_uring opcodes
linux.IORING_OP.URING_CMD      // opcode for ublk commands

// mmap protections
linux.PROT.READ
linux.PROT.WRITE

// mmap flags
linux.MAP.SHARED
linux.MAP.PRIVATE
linux.MAP.ANONYMOUS
```

### io_uring_params

```zig
// From linux.zig - we'll need to set flags
pub const io_uring_params = extern struct {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,              // <-- IORING_SETUP_SQE128 | IORING_SETUP_CQE32
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    features: u32,           // <-- kernel sets this, check IORING_FEAT_*
    wq_fd: u32,
    resv: [3]u32,
    sq_off: io_sqring_offsets,
    cq_off: io_cqring_offsets,
};
```

## std.os.linux.IoUring

### What It Provides

```zig
const IoUring = std.os.linux.IoUring;

// Creation
pub fn init(entries: u16, flags: u32) !IoUring
pub fn init_params(entries: u16, p: *linux.io_uring_params) !IoUring
pub fn deinit(self: *IoUring) void

// Submission
pub fn get_sqe(self: *IoUring) !*linux.io_uring_sqe
pub fn submit(self: *IoUring) !u32
pub fn submit_and_wait(self: *IoUring, wait_nr: u32) !u32

// Completion
// (need to investigate - probably through cq.cqes)

// Fields we can access
self.fd: linux.fd_t        // ring file descriptor
self.sq: SubmissionQueue   // has sqes[], head, tail, etc
self.cq: CompletionQueue   // has cqes[], head, tail, etc
self.flags: u32            // setup flags
self.features: u32         // kernel feature flags
```

### What It DOESN'T Provide (we need to handle)

1. **SQE128 access** - stdlib sqe is 64 bytes, we need 128
2. **CQE32 access** - stdlib cqe is 16 bytes, we need 32
3. **Raw cmd area** - bytes 48-127 of SQE for URING_CMD

## std.posix

```zig
const posix = std.posix;

// File operations
posix.open(path, flags, mode) !fd_t
posix.close(fd) void

// Error handling
posix.unexpectedErrno(errno) error
```

## Our Custom Structures

These must match kernel ABI exactly.

### Control Command (32 bytes)

```zig
/// Placed in SQE cmd area for control operations
pub const UblksrvCtrlCmd = extern struct {
    dev_id: u32,        // 0xFFFFFFFF for new device
    queue_id: u16,      // 0xFFFF for control ops
    len: u16,           // data length at addr
    addr: u64,          // userspace buffer
    data: u64,          // inline payload
    dev_path_len: u16,  // unprivileged mode only
    pad: u16,
    reserved: u32,
};
```

### IO Command (16 bytes)

```zig
/// Placed in SQE cmd area for IO operations
pub const UblksrvIoCmd = extern struct {
    qid: u16,
    tag: u16,
    result: i32,
    addr: u64,
};
```

### IO Descriptor (24 bytes)

```zig
/// mmap'd from kernel, read-only
pub const UblksrvIoDesc = extern struct {
    op_flags: u32,      // op: bits 0-7, flags: bits 8-31
    nr_sectors: u32,
    start_sector: u64,
    addr: u64,
};
```

### Device Info (64 bytes)

```zig
pub const UblksrvCtrlDevInfo = extern struct {
    nr_hw_queues: u16,
    queue_depth: u16,
    state: u16,
    pad0: u16,
    max_io_buf_bytes: u32,
    dev_id: u32,
    ublksrv_pid: i32,
    pad1: u32,
    flags: u64,
    ublksrv_flags: u64,
    owner_uid: u32,
    owner_gid: u32,
    reserved1: u64,
    reserved2: u64,
};
```

### 128-byte SQE (custom)

```zig
/// Extended SQE for URING_CMD operations
/// First 64 bytes match linux.io_uring_sqe
/// Bytes 48-127 are the cmd area (80 bytes)
pub const IoUringSqe128 = extern struct {
    // Standard SQE fields (bytes 0-47)
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

    // Extended area (bytes 48-127)
    // For URING_CMD: bytes 48-51 are cmd_op
    cmd_op: u32,
    __pad1: u32,
    cmd: [72]u8,  // remaining cmd area
};
comptime {
    std.debug.assert(@sizeOf(IoUringSqe128) == 128);
}
```

## Open Questions

1. **Can we use IoUring.init_params with SQE128 flag?**
   - The wrapper mmaps based on params, but does it handle 128-byte SQEs?
   - Probably not - sqes slice is `[]io_uring_sqe` (64 bytes each)

2. **Do we need raw mmap?**
   - Likely yes, to get proper 128-byte SQE slots
   - Or we cast/overlay our struct on the memory

3. **CQE32 handling?**
   - Stdlib cqe is 16 bytes
   - We need to handle the extra 16 bytes (big_cqe field)

## Usage Pattern (Proposed)

```zig
// Option A: Raw syscalls (full control)
const ring_fd = linux.io_uring_setup(entries, &params);
// mmap SQ, CQ, SQEs ourselves with correct sizes

// Option B: Hybrid (use IoUring, overlay our structs)
var ring = try IoUring.init_params(entries, &params);
// Cast sqes to our 128-byte version
const sqe128 = @ptrCast(*IoUringSqe128, ring.sq.sqes.ptr);
```
