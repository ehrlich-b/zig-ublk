//! zig-ublk: Native Zig implementation of Linux ublk
//!
//! This is a userspace block device driver using io_uring for kernel communication.
//! Currently in Phase 0 (Zig Bootcamp) - learning the APIs we need.

const std = @import("std");
const linux = std.os.linux;

// ============================================================================
// Phase 0: Zig Bootcamp - API Exploration
// ============================================================================

// Findings:
// - Stdlib IoUring does NOT support SQE128/CQE32 properly
// - It mmaps sqes with 64 bytes per entry, but kernel expects 128 with SQE128
// - We must use raw io_uring_setup and mmap ourselves

/// 128-byte SQE for URING_CMD operations
/// First 64 bytes match linux.io_uring_sqe layout
/// Bytes 48-127 are the extended cmd area (80 bytes)
pub const IoUringSqe128 = extern struct {
    // Standard SQE fields (bytes 0-47)
    opcode: linux.IORING_OP,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    opflags: extern union {
        rw_flags: linux.kernel_rwf,
        fsync_flags: u32,
        poll_events: u16,
        poll32_events: u32,
        sync_range_flags: u32,
        msg_flags: u32,
        timeout_flags: u32,
        accept_flags: u32,
        cancel_flags: u32,
        open_flags: linux.O,
        statx_flags: u32,
        fadvise_advice: u32,
        splice_flags: u32,
        rename_flags: u32,
        unlink_flags: u32,
        hardlink_flags: u32,
        xattr_flags: u32,
        msg_ring_flags: u32,
        uring_cmd_flags: u32,
        waitid_flags: u32,
        futex_flags: u32,
        install_fd_flags: u32,
        nop_flags: u32,
    },
    user_data: u64,
    buf: extern union {
        buf_index: u16,
        buf_group: u16,
    },
    personality: u16,
    splice_fd_in_or_file_index: extern union {
        splice_fd_in: i32,
        file_index: u32,
        optlen: u32,
    },
    addr3_or_cmd: extern union {
        addr3: u64,
        cmd: [0]u8, // cmd area starts here (byte 48) for URING_CMD
    },
    __pad2: [1]u64,

    // Extended area (bytes 64-127) - only present in SQE128 mode
    // For URING_CMD, bytes 48-127 (80 bytes) form the cmd area
    // We access this via getCmd()
    big_sqe_extra: [64]u8,

    /// Get pointer to the 80-byte cmd area (bytes 48-127)
    /// This is where UblksrvCtrlCmd or UblksrvIoCmd goes
    pub fn getCmd(self: *IoUringSqe128, comptime T: type) *T {
        // cmd area starts at byte 48 (addr3_or_cmd union)
        const cmd_ptr: *[80]u8 = @ptrCast(&self.addr3_or_cmd);
        return @ptrCast(@alignCast(cmd_ptr));
    }

    /// Prepare for a URING_CMD operation
    /// cmd_op: ioctl-encoded command (from ublkCtrlCmd or ublkIoCmd)
    /// target_fd: file descriptor (/dev/ublk-control or /dev/ublkcN)
    pub fn prepUringCmd(self: *IoUringSqe128, cmd_op: u32, target_fd: i32) void {
        // Zero out the struct first
        const bytes: *[128]u8 = @ptrCast(self);
        @memset(bytes, 0);

        self.opcode = linux.IORING_OP.URING_CMD;
        self.fd = target_fd;
        // For URING_CMD, cmd_op goes in the `off` field (bytes 8-11)
        // The upper 32 bits (bytes 12-15) must be zero
        self.off = cmd_op;
    }

    comptime {
        if (@sizeOf(IoUringSqe128) != 128) {
            @compileError("IoUringSqe128 must be exactly 128 bytes");
        }
    }
};

/// 32-byte CQE for CQE32 mode
pub const IoUringCqe32 = extern struct {
    // Standard CQE fields (bytes 0-15)
    user_data: u64,
    res: i32,
    flags: u32,

    // Extended area (bytes 16-31) - only present in CQE32 mode
    big_cqe: [16]u8,

    pub fn err(self: IoUringCqe32) linux.E {
        if (self.res > -4096 and self.res < 0) {
            return @enumFromInt(@as(u16, @intCast(-self.res)));
        }
        return .SUCCESS;
    }

    comptime {
        if (@sizeOf(IoUringCqe32) != 32) {
            @compileError("IoUringCqe32 must be exactly 32 bytes");
        }
    }
};

// ============================================================================
// Raw io_uring for SQE128/CQE32
// ============================================================================

/// io_uring wrapper that properly handles SQE128/CQE32 mode
/// The stdlib IoUring doesn't support these modes because it assumes
/// 64-byte SQEs and 16-byte CQEs in its mmap calculations.
pub const IoUring128 = struct {
    fd: linux.fd_t = -1,
    sq_ring: []align(std.heap.page_size_min) u8 = &.{},
    sqes_mmap: []align(std.heap.page_size_min) u8 = &.{},

    // Ring pointers (point into sq_ring mmap)
    sq_head: *u32 = undefined,
    sq_tail: *u32 = undefined,
    sq_mask: u32 = 0,
    sq_flags: *u32 = undefined,
    sq_dropped: *u32 = undefined,
    sq_array: []u32 = &.{},
    cq_head: *u32 = undefined,
    cq_tail: *u32 = undefined,
    cq_mask: u32 = 0,
    cq_overflow: *u32 = undefined,

    // SQE/CQE arrays (properly sized for 128/32 byte entries)
    sqes: []IoUringSqe128 = &.{},
    cqes: []IoUringCqe32 = &.{},

    // Tracking
    sqe_head: u32 = 0,
    sqe_tail: u32 = 0,
    features: u32 = 0,

    pub const InitError = error{
        EntriesZero,
        EntriesNotPowerOfTwo,
        ParamsOutsideAccessibleAddressSpace,
        ArgumentsInvalid,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        PermissionDenied,
        SystemOutdated,
        MmapFailed,
        Unexpected,
    };

    /// Initialize io_uring with SQE128 and CQE32 support
    pub fn init(entries: u16) InitError!IoUring128 {
        if (entries == 0) return error.EntriesZero;
        if (!std.math.isPowerOfTwo(entries)) return error.EntriesNotPowerOfTwo;

        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = linux.IORING_SETUP_SQE128 | linux.IORING_SETUP_CQE32,
        });

        const res = linux.io_uring_setup(entries, &params);
        const fd = switch (linux.errno(res)) {
            .SUCCESS => @as(linux.fd_t, @intCast(res)),
            .FAULT => return error.ParamsOutsideAccessibleAddressSpace,
            .INVAL => return error.ArgumentsInvalid,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            .NOSYS => return error.SystemOutdated,
            else => return error.Unexpected,
        };
        errdefer std.posix.close(fd);

        // Modern kernels (5.4+) use single mmap for SQ and CQ rings
        if ((params.features & linux.IORING_FEAT_SINGLE_MMAP) == 0) {
            return error.SystemOutdated;
        }

        // mmap the ring structure (SQ and CQ rings share this)
        // Size must account for CQE32 (32 bytes per CQE)
        const ring_size = @max(
            params.sq_off.array + params.sq_entries * @sizeOf(u32),
            params.cq_off.cqes + params.cq_entries * @sizeOf(IoUringCqe32),
        );
        const sq_ring = std.posix.mmap(
            null,
            ring_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQ_RING,
        ) catch return error.MmapFailed;
        errdefer std.posix.munmap(sq_ring);

        // mmap the SQEs (128 bytes per entry)
        const sqes_size = params.sq_entries * @sizeOf(IoUringSqe128);
        const sqes_mmap = std.posix.mmap(
            null,
            sqes_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQES,
        ) catch return error.MmapFailed;
        errdefer std.posix.munmap(sqes_mmap);

        var self = IoUring128{
            .fd = fd,
            .sq_ring = sq_ring,
            .sqes_mmap = sqes_mmap,
            .features = params.features,
        };

        // Set up SQ ring pointers
        self.sq_head = @ptrCast(@alignCast(&sq_ring[params.sq_off.head]));
        self.sq_tail = @ptrCast(@alignCast(&sq_ring[params.sq_off.tail]));
        self.sq_mask = @as(*u32, @ptrCast(@alignCast(&sq_ring[params.sq_off.ring_mask]))).*;
        self.sq_flags = @ptrCast(@alignCast(&sq_ring[params.sq_off.flags]));
        self.sq_dropped = @ptrCast(@alignCast(&sq_ring[params.sq_off.dropped]));
        const array_ptr: [*]u32 = @ptrCast(@alignCast(&sq_ring[params.sq_off.array]));
        self.sq_array = array_ptr[0..params.sq_entries];

        // Set up CQ ring pointers (32-byte CQEs)
        self.cq_head = @ptrCast(@alignCast(&sq_ring[params.cq_off.head]));
        self.cq_tail = @ptrCast(@alignCast(&sq_ring[params.cq_off.tail]));
        self.cq_mask = @as(*u32, @ptrCast(@alignCast(&sq_ring[params.cq_off.ring_mask]))).*;
        self.cq_overflow = @ptrCast(@alignCast(&sq_ring[params.cq_off.overflow]));
        const cqes_ptr: [*]IoUringCqe32 = @ptrCast(@alignCast(&sq_ring[params.cq_off.cqes]));
        self.cqes = cqes_ptr[0..params.cq_entries];

        // Set up SQEs (128-byte entries)
        const sqes_ptr: [*]IoUringSqe128 = @ptrCast(@alignCast(&sqes_mmap[0]));
        self.sqes = sqes_ptr[0..params.sq_entries];

        return self;
    }

    pub fn deinit(self: *IoUring128) void {
        if (self.fd >= 0) {
            std.posix.munmap(self.sqes_mmap);
            std.posix.munmap(self.sq_ring);
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Get a vacant SQE, or error if queue is full
    pub fn getSqe(self: *IoUring128) error{SubmissionQueueFull}!*IoUringSqe128 {
        const head = @atomicLoad(u32, self.sq_head, .acquire);
        const next = self.sqe_tail +% 1;
        if (next -% head > self.sqes.len) return error.SubmissionQueueFull;
        const sqe = &self.sqes[self.sqe_tail & self.sq_mask];
        self.sqe_tail = next;
        return sqe;
    }

    /// Flush pending SQEs to the kernel submission queue
    pub fn flushSq(self: *IoUring128) u32 {
        if (self.sqe_head == self.sqe_tail) return 0;

        const pending = self.sqe_tail -% self.sqe_head;
        var to_submit = pending;
        var tail = self.sq_tail.*;

        while (to_submit > 0) : (to_submit -= 1) {
            self.sq_array[tail & self.sq_mask] = self.sqe_head & self.sq_mask;
            tail +%= 1;
            self.sqe_head +%= 1;
        }

        // Release store ensures kernel sees SQE updates before tail update
        @atomicStore(u32, self.sq_tail, tail, .release);

        return pending;
    }

    /// Submit SQEs to the kernel
    pub fn submit(self: *IoUring128) !u32 {
        return self.submitAndWait(0);
    }

    /// Submit SQEs and wait for completions
    pub fn submitAndWait(self: *IoUring128, wait_nr: u32) !u32 {
        const to_submit = self.flushSq();
        var flags: u32 = 0;

        if (wait_nr > 0) {
            flags |= linux.IORING_ENTER_GETEVENTS;
        }

        if (to_submit > 0 or wait_nr > 0) {
            const res = linux.io_uring_enter(self.fd, to_submit, wait_nr, flags, null);
            switch (linux.errno(res)) {
                .SUCCESS => return @intCast(res),
                .AGAIN => return error.SystemResources,
                .BADF => return error.FileDescriptorInvalid,
                .BUSY => return error.CompletionQueueOvercommitted,
                .INVAL => return error.SubmissionQueueEntryInvalid,
                .FAULT => return error.BufferInvalid,
                else => |e| return std.posix.unexpectedErrno(e),
            }
        }
        return 0;
    }

    pub const SubmitError = error{
        SystemResources,
        FileDescriptorInvalid,
        CompletionQueueOvercommitted,
        SubmissionQueueEntryInvalid,
        BufferInvalid,
        Unexpected,
    };

    /// Copy ready CQEs to the provided buffer
    pub fn copyCqes(self: *IoUring128, cqes: []IoUringCqe32) u32 {
        const ready = self.cqReady();
        const count = @min(cqes.len, ready);

        var head = self.cq_head.*;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            cqes[i] = self.cqes[head & self.cq_mask];
            head +%= 1;
        }

        // Release store so kernel knows we've consumed the CQEs
        @atomicStore(u32, self.cq_head, head, .release);

        return count;
    }

    /// Number of CQEs ready to be consumed
    pub fn cqReady(self: *IoUring128) u32 {
        return @atomicLoad(u32, self.cq_tail, .acquire) -% self.cq_head.*;
    }
};

// ============================================================================
// Control Device
// ============================================================================

pub const UBLK_CONTROL_PATH = "/dev/ublk-control";

/// Controller for managing ublk devices via /dev/ublk-control
pub const Controller = struct {
    control_fd: std.posix.fd_t,
    ring: IoUring128,

    pub const InitError = error{
        DeviceNotFound,
        PermissionDenied,
        IoUringInitFailed,
    } || std.posix.OpenError || IoUring128.InitError;

    /// Open the ublk control device and initialize io_uring
    pub fn init() InitError!Controller {
        // Open /dev/ublk-control
        const fd = std.posix.open(UBLK_CONTROL_PATH, .{ .ACCMODE = .RDWR }, 0) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DeviceNotFound,
                error.AccessDenied => error.PermissionDenied,
                else => err,
            };
        };
        errdefer std.posix.close(fd);

        // Initialize io_uring with SQE128/CQE32 for URING_CMD
        var ring = IoUring128.init(32) catch |err| {
            return switch (err) {
                error.PermissionDenied => error.PermissionDenied,
                else => err,
            };
        };
        errdefer ring.deinit();

        return Controller{
            .control_fd = fd,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.ring.deinit();
        std.posix.close(self.control_fd);
    }

    /// Submit an ADD_DEV command to create a new ublk device
    pub fn addDevice(self: *Controller, dev_info: *UblksrvCtrlDevInfo) ControlError!u32 {
        const sqe = try self.ring.getSqe();

        // Prepare URING_CMD for ADD_DEV with ioctl encoding
        sqe.prepUringCmd(ublkCtrlCmd(.add_dev), self.control_fd);
        sqe.user_data = 0xADD_DE7;

        // Fill in the control command in the SQE cmd area
        const cmd = sqe.getCmd(UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_info.dev_id,
            .queue_id = 0xFFFF, // Control operation
            .len = @sizeOf(UblksrvCtrlDevInfo),
            .addr = @intFromPtr(dev_info),
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        // Submit and wait for completion
        _ = try self.ring.submitAndWait(1);

        // Get the completion
        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.ring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            // Kernel returned error
            std.log.err("ADD_DEV failed with error: {d}", .{cqe.res});
            return error.AddDeviceFailed;
        }

        // Return the assigned device ID (may be updated by kernel)
        return dev_info.dev_id;
    }

    pub const ControlError = error{
        SubmissionQueueFull,
        NoCompletion,
        AddDeviceFailed,
        SystemResources,
        FileDescriptorInvalid,
        CompletionQueueOvercommitted,
        SubmissionQueueEntryInvalid,
        BufferInvalid,
        Unexpected,
    };
};

// ============================================================================
// UAPI Definitions (from kernel headers)
// ============================================================================

/// Control commands sent to /dev/ublk-control
pub const CtrlCmd = enum(u8) {
    get_queue_affinity = 0x01,
    get_dev_info = 0x02,
    add_dev = 0x04,
    del_dev = 0x05,
    start_dev = 0x06,
    stop_dev = 0x07,
    set_params = 0x08,
    get_params = 0x09,
    start_user_recovery = 0x10,
    end_user_recovery = 0x11,
    get_dev_info2 = 0x12,
};

/// IO commands sent to /dev/ublkcN
pub const IoCmd = enum(u8) {
    fetch_req = 0x20,
    commit_and_fetch_req = 0x21,
    need_get_data = 0x22,
};

// ============================================================================
// ioctl Encoding (required for kernel 6.11+)
// ============================================================================

const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;
const IOC_NRSHIFT: u5 = 0;
const IOC_TYPESHIFT: u5 = 8;
const IOC_SIZESHIFT: u5 = 16;
const IOC_DIRSHIFT: u5 = 30;

/// Encode an ioctl command number
fn ioctlEncode(dir: u32, typ: u8, nr: u8, size: u32) u32 {
    return (dir << IOC_DIRSHIFT) |
        (size << IOC_SIZESHIFT) |
        (@as(u32, typ) << IOC_TYPESHIFT) |
        (@as(u32, nr) << IOC_NRSHIFT);
}

/// Encode a ublk control command (uses 32-byte header)
pub fn ublkCtrlCmd(cmd: CtrlCmd) u32 {
    return ioctlEncode(IOC_READ | IOC_WRITE, 'u', @intFromEnum(cmd), 32);
}

/// Encode a ublk IO command (uses 16-byte header)
pub fn ublkIoCmd(cmd: IoCmd) u32 {
    return ioctlEncode(IOC_READ | IOC_WRITE, 'u', @intFromEnum(cmd), 16);
}

// ============================================================================
// Kernel ABI Structures
// ============================================================================

/// Control command structure - placed in SQE cmd area (32 bytes)
pub const UblksrvCtrlCmd = extern struct {
    dev_id: u32,
    queue_id: u16,
    len: u16,
    addr: u64,
    data: u64,
    dev_path_len: u16,
    pad: u16,
    reserved: u32,

    comptime {
        if (@sizeOf(UblksrvCtrlCmd) != 32) {
            @compileError("UblksrvCtrlCmd must be exactly 32 bytes");
        }
    }
};

/// IO command structure (16 bytes)
pub const UblksrvIoCmd = extern struct {
    qid: u16,
    tag: u16,
    result: i32,
    addr: u64,

    comptime {
        if (@sizeOf(UblksrvIoCmd) != 16) {
            @compileError("UblksrvIoCmd must be exactly 16 bytes");
        }
    }
};

/// IO descriptor - mmap'd from kernel (24 bytes)
pub const UblksrvIoDesc = extern struct {
    op_flags: u32, // op: bits 0-7, flags: bits 8-31
    nr_sectors: u32,
    start_sector: u64,
    addr: u64,

    pub fn getOp(self: UblksrvIoDesc) u8 {
        return @truncate(self.op_flags);
    }

    pub fn getFlags(self: UblksrvIoDesc) u24 {
        return @truncate(self.op_flags >> 8);
    }

    comptime {
        if (@sizeOf(UblksrvIoDesc) != 24) {
            @compileError("UblksrvIoDesc must be exactly 24 bytes");
        }
    }
};

/// Device info structure (64 bytes)
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

    comptime {
        if (@sizeOf(UblksrvCtrlDevInfo) != 64) {
            @compileError("UblksrvCtrlDevInfo must be exactly 64 bytes");
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "struct sizes match kernel ABI" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UblksrvCtrlCmd));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(UblksrvIoCmd));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(UblksrvIoDesc));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(UblksrvCtrlDevInfo));
}

test "IoDesc field extraction" {
    const desc = UblksrvIoDesc{
        .op_flags = 0x12_34_56_01, // op=1 (WRITE), flags=0x123456
        .nr_sectors = 8,
        .start_sector = 0,
        .addr = 0,
    };
    try std.testing.expectEqual(@as(u8, 1), desc.getOp());
    try std.testing.expectEqual(@as(u24, 0x12_34_56), desc.getFlags());
}

test "SQE128 and CQE32 sizes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(IoUringSqe128));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(IoUringCqe32));
}

test "SQE128 cmd area access" {
    var sqe: IoUringSqe128 = undefined;
    @memset(@as(*[128]u8, @ptrCast(&sqe)), 0);

    // The cmd area should be usable for UblksrvCtrlCmd (32 bytes)
    const cmd = sqe.getCmd(UblksrvCtrlCmd);
    cmd.dev_id = 0xDEAD_BEEF;
    cmd.queue_id = 0xFFFF;
    cmd.addr = 0x1234_5678_9ABC_DEF0;

    // Verify values are set
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cmd.dev_id);
    try std.testing.expectEqual(@as(u16, 0xFFFF), cmd.queue_id);
    try std.testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), cmd.addr);
}

test "io_uring constants available" {
    // Verify the constants we need are in stdlib
    try std.testing.expect(linux.IORING_SETUP_SQE128 != 0);
    try std.testing.expect(linux.IORING_SETUP_CQE32 != 0);
    // URING_CMD is opcode 46 in modern kernels (was 27 in early versions)
    try std.testing.expectEqual(@as(u8, 46), @intFromEnum(linux.IORING_OP.URING_CMD));
}
