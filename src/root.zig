//! zig-ublk: Native Zig implementation of Linux ublk
//!
//! This is a userspace block device driver using io_uring for kernel communication.
//! Currently in Phase 0 (Zig Bootcamp) - learning the APIs we need.

const std = @import("std");
const linux = std.os.linux;

// ============================================================================
// Phase 0: Zig Bootcamp - API Exploration
// ============================================================================

/// Explore what's available in std.os.linux.IO_Uring
pub fn exploreIoUring() !void {
    // TODO: Phase 0.1 - Investigate IO_Uring API
    // Questions:
    // - Can we set IORING_SETUP_SQE128 and IORING_SETUP_CQE32?
    // - Is IORING_OP_URING_CMD (opcode 27) available?
    // - How do we access the SQE cmd area?
}

/// Explore mmap and syscall patterns
pub fn exploreSyscalls() !void {
    // TODO: Phase 0.2 - Investigate syscall patterns
    // Questions:
    // - How to open /dev/ublk-control?
    // - How to mmap with specific flags?
    // - How to cast mmap result to struct pointer?
}

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
