//! Kernel UAPI definitions for ublk
//!
//! Contains command enums, ioctl encoding, and kernel ABI structures.
//! These must match kernel headers exactly.

const std = @import("std");

// ============================================================================
// Command Enums
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
// IO Operation Codes (from kernel block layer)
// ============================================================================

/// Block IO operation codes (REQ_OP_* from linux/blk_types.h)
pub const IoOp = enum(u8) {
    read = 0,
    write = 1,
    flush = 2,
    discard = 3,
    secure_erase = 5,
    write_zeroes = 9,
    zone_open = 10,
    zone_close = 11,
    zone_finish = 12,
    zone_append = 13,
    zone_reset = 15,
    zone_reset_all = 17,
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

    /// Get the IO operation as a typed enum (returns null if unknown)
    pub fn getIoOp(self: UblksrvIoDesc) ?IoOp {
        return std.meta.intToEnum(IoOp, self.getOp()) catch null;
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
// Constants
// ============================================================================

/// Control device path
pub const UBLK_CONTROL_PATH = "/dev/ublk-control";

/// IO buffer size per tag (64KB)
pub const IO_BUFFER_SIZE_PER_TAG: usize = 64 * 1024;

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
    try std.testing.expectEqual(IoOp.write, desc.getIoOp().?);
}

test "IoOp enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(IoOp.read));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(IoOp.write));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(IoOp.flush));
}
