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

## Implemented: IoUring128

We implemented a custom io_uring wrapper that properly handles SQE128/CQE32:

```zig
// IoUring128 - raw io_uring for URING_CMD
pub const IoUring128 = struct {
    fd: linux.fd_t,
    sq_ring: []align(page_size_min) u8,
    sqes_mmap: []align(page_size_min) u8,
    sqes: []IoUringSqe128,
    cqes: []IoUringCqe32,
    // ... ring pointers and tracking

    pub fn init(entries: u16) !IoUring128;
    pub fn deinit(self: *IoUring128) void;
    pub fn getSqe(self: *IoUring128) !*IoUringSqe128;
    pub fn submit(self: *IoUring128) !u32;
    pub fn submitAndWait(self: *IoUring128, wait_nr: u32) !u32;
    pub fn copyCqes(self: *IoUring128, cqes: []IoUringCqe32) u32;
    pub fn cqReady(self: *IoUring128) u32;
};

// 128-byte SQE with getCmd() helper
pub const IoUringSqe128 = extern struct {
    // ... standard SQE fields (bytes 0-47)
    // ... extended fields including 80-byte cmd area

    pub fn getCmd(self: *IoUringSqe128, comptime T: type) *T;
    pub fn prepUringCmd(self: *IoUringSqe128, cmd_op: u32, target_fd: i32) void;
};

// 32-byte CQE
pub const IoUringCqe32 = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
    big_cqe: [16]u8,
};
```

## Implemented: Controller

```zig
// Controller for /dev/ublk-control operations
pub const Controller = struct {
    control_fd: std.posix.fd_t,
    ring: IoUring128,

    pub fn init() !Controller;
    pub fn deinit(self: *Controller) void;

    // Device lifecycle
    pub fn addDevice(self: *Controller, dev_info: *UblksrvCtrlDevInfo) !u32;
    pub fn setParams(self: *Controller, dev_id: u32, params: *UblkParamsBuffer) !void;
    pub fn getDeviceInfo(self: *Controller, dev_id: u32, dev_info: *UblksrvCtrlDevInfo) !void;
    pub fn startDevice(self: *Controller, dev_id: u32) !void;  // Requires IO queues ready
    pub fn stopDevice(self: *Controller, dev_id: u32) !void;
    pub fn deleteDevice(self: *Controller, dev_id: u32) !void;
};
```

## Implemented: UblkParams (Device Parameters)

```zig
// Parameter type flags
pub const UBLK_PARAM_TYPE_BASIC: u32 = 1 << 0;
pub const UBLK_PARAM_TYPE_DISCARD: u32 = 1 << 1;
pub const UBLK_PARAM_TYPE_DEVT: u32 = 1 << 2;
pub const UBLK_PARAM_TYPE_ZONED: u32 = 1 << 3;

// Basic device parameters (32 bytes)
pub const UblkParamBasic = extern struct {
    attrs: u32,              // UBLK_ATTR_* flags
    logical_bs_shift: u8,    // logical block size = 1 << shift
    physical_bs_shift: u8,
    io_opt_shift: u8,
    io_min_shift: u8,
    max_sectors: u32,
    chunk_sectors: u32,
    dev_sectors: u64,        // device size in sectors
    virt_boundary_mask: u64,
};

// Combined parameters structure
pub const UblkParams = extern struct {
    len: u32,
    types: u32,              // UBLK_PARAM_TYPE_* flags
    basic: UblkParamBasic,
    discard: UblkParamDiscard,
    devt: UblkParamDevt,
    zoned: UblkParamZoned,

    pub fn initBasic(device_size_bytes: u64, logical_block_size: u32) UblkParams;
    pub fn hasBasic(self: UblkParams) bool;
    // ... other has* methods
};

// Padded buffer for kernel (128 bytes)
pub const UblkParamsBuffer = extern struct {
    params: UblkParams,
    _padding: [...]u8,

    pub fn init(params: UblkParams) UblkParamsBuffer;
};
```

## Resolved Questions

1. **Can we use IoUring.init_params with SQE128 flag?**
   - **NO** - stdlib mmaps 64 bytes/SQE, we need 128

2. **Do we need raw mmap?**
   - **YES** - implemented in IoUring128.init()

3. **CQE32 handling?**
   - **SOLVED** - IoUringCqe32 with 16-byte big_cqe field

## Usage Pattern (Actual)

```zig
// Open control device and create io_uring
var controller = try Controller.init();
defer controller.deinit();

// Prepare device info
var dev_info = UblksrvCtrlDevInfo{ ... };

// Send ADD_DEV command via io_uring URING_CMD
const dev_id = try controller.addDevice(&dev_info);

// Configure device parameters (1GB device, 512-byte blocks)
const params = UblkParams.initBasic(1024 * 1024 * 1024, 512);
var params_buf = UblkParamsBuffer.init(params);
try controller.setParams(dev_id, &params_buf);
```
