//! Device parameter structures for ublk
//!
//! Used with SET_PARAMS and GET_PARAMS commands to configure device properties.

const std = @import("std");

// ============================================================================
// Parameter Type Flags
// ============================================================================

/// Parameter type flags - indicate which parameter sections are valid
pub const UBLK_PARAM_TYPE_BASIC: u32 = 1 << 0;
pub const UBLK_PARAM_TYPE_DISCARD: u32 = 1 << 1;
pub const UBLK_PARAM_TYPE_DEVT: u32 = 1 << 2;
pub const UBLK_PARAM_TYPE_ZONED: u32 = 1 << 3;

// ============================================================================
// Device Attribute Flags
// ============================================================================

/// Device attribute flags (used in UblkParamBasic.attrs)
pub const UBLK_ATTR_READ_ONLY: u32 = 1 << 0;
pub const UBLK_ATTR_ROTATIONAL: u32 = 1 << 1;
pub const UBLK_ATTR_VOLATILE_CACHE: u32 = 1 << 2;
pub const UBLK_ATTR_FUA: u32 = 1 << 3;

// ============================================================================
// Parameter Structures
// ============================================================================

/// Basic device parameters (32 bytes)
pub const UblkParamBasic = extern struct {
    attrs: u32, // attribute flags (UBLK_ATTR_*)
    logical_bs_shift: u8, // logical block size = 1 << shift
    physical_bs_shift: u8, // physical block size = 1 << shift
    io_opt_shift: u8, // optimal I/O size = 1 << shift
    io_min_shift: u8, // minimum I/O size = 1 << shift
    max_sectors: u32, // max sectors per request
    chunk_sectors: u32, // chunk size in sectors (0 = no chunking)
    dev_sectors: u64, // device size in sectors
    virt_boundary_mask: u64, // virtual boundary mask

    comptime {
        if (@sizeOf(UblkParamBasic) != 32) {
            @compileError("UblkParamBasic must be exactly 32 bytes");
        }
    }
};

/// Discard parameters (20 bytes)
pub const UblkParamDiscard = extern struct {
    discard_alignment: u32,
    discard_granularity: u32,
    max_discard_sectors: u32,
    max_write_zeroes_sectors: u32,
    max_discard_segments: u16,
    reserved0: u16,

    comptime {
        if (@sizeOf(UblkParamDiscard) != 20) {
            @compileError("UblkParamDiscard must be exactly 20 bytes");
        }
    }
};

/// Device number parameters (16 bytes) - read-only from kernel
pub const UblkParamDevt = extern struct {
    char_major: u32,
    char_minor: u32,
    disk_major: u32,
    disk_minor: u32,

    comptime {
        if (@sizeOf(UblkParamDevt) != 16) {
            @compileError("UblkParamDevt must be exactly 16 bytes");
        }
    }
};

/// Zoned device parameters (32 bytes)
pub const UblkParamZoned = extern struct {
    max_open_zones: u32,
    max_active_zones: u32,
    max_zone_append_sectors: u32,
    reserved: [20]u8,

    comptime {
        if (@sizeOf(UblkParamZoned) != 32) {
            @compileError("UblkParamZoned must be exactly 32 bytes");
        }
    }
};

/// Combined device parameters structure (108 bytes base)
/// Note: Kernel requires buffer padded to 128 bytes minimum
pub const UblkParams = extern struct {
    len: u32, // total length of parameters
    types: u32, // UBLK_PARAM_TYPE_* flags
    basic: UblkParamBasic,
    discard: UblkParamDiscard,
    devt: UblkParamDevt,
    zoned: UblkParamZoned,

    /// Create params for a simple device with basic parameters only
    pub fn initBasic(device_size_bytes: u64, logical_block_size: u32) UblkParams {
        const bs_shift = sizeToShift(logical_block_size);
        const sectors = device_size_bytes / logical_block_size;

        return UblkParams{
            .len = 128, // Padded size that kernel expects
            .types = UBLK_PARAM_TYPE_BASIC,
            .basic = .{
                .attrs = 0,
                .logical_bs_shift = bs_shift,
                .physical_bs_shift = bs_shift,
                .io_opt_shift = 0,
                .io_min_shift = bs_shift,
                .max_sectors = 1024, // 512KB max I/O (common default)
                .chunk_sectors = 0,
                .dev_sectors = sectors,
                .virt_boundary_mask = 0,
            },
            .discard = std.mem.zeroes(UblkParamDiscard),
            .devt = std.mem.zeroes(UblkParamDevt),
            .zoned = std.mem.zeroes(UblkParamZoned),
        };
    }

    /// Check if basic parameters are included
    pub fn hasBasic(self: UblkParams) bool {
        return (self.types & UBLK_PARAM_TYPE_BASIC) != 0;
    }

    /// Check if discard parameters are included
    pub fn hasDiscard(self: UblkParams) bool {
        return (self.types & UBLK_PARAM_TYPE_DISCARD) != 0;
    }

    /// Check if devt parameters are included
    pub fn hasDevt(self: UblkParams) bool {
        return (self.types & UBLK_PARAM_TYPE_DEVT) != 0;
    }

    /// Check if zoned parameters are included
    pub fn hasZoned(self: UblkParams) bool {
        return (self.types & UBLK_PARAM_TYPE_ZONED) != 0;
    }
};

/// Padded buffer for UblkParams - kernel requires 128 bytes minimum
pub const UblkParamsBuffer = extern struct {
    params: UblkParams,
    _padding: [128 - @sizeOf(UblkParams)]u8 = [_]u8{0} ** (128 - @sizeOf(UblkParams)),

    pub fn init(p: UblkParams) UblkParamsBuffer {
        return .{ .params = p };
    }

    comptime {
        if (@sizeOf(UblkParamsBuffer) != 128) {
            @compileError("UblkParamsBuffer must be exactly 128 bytes");
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert size to shift value (log2)
pub fn sizeToShift(size: u32) u8 {
    var s = size;
    var shift: u8 = 0;
    while (s > 1) : (s >>= 1) {
        shift += 1;
    }
    return shift;
}

// ============================================================================
// Tests
// ============================================================================

test "UblkParams struct sizes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UblkParamBasic));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(UblkParamDiscard));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(UblkParamDevt));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(UblkParamZoned));
    // UblkParams = len(4) + types(4) + basic(32) + discard(20) + devt(16) + zoned(32) = 108
    // But alignment may add padding
    try std.testing.expect(@sizeOf(UblkParams) <= 128);
    // UblkParamsBuffer must be exactly 128 bytes for kernel
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(UblkParamsBuffer));
}

test "UblkParams.initBasic" {
    // 1GB device with 512-byte blocks
    const p = UblkParams.initBasic(1024 * 1024 * 1024, 512);

    try std.testing.expectEqual(UBLK_PARAM_TYPE_BASIC, p.types);
    try std.testing.expect(p.hasBasic());
    try std.testing.expect(!p.hasDiscard());
    try std.testing.expect(!p.hasDevt());
    try std.testing.expect(!p.hasZoned());

    // 512 bytes = 2^9, so shift should be 9
    try std.testing.expectEqual(@as(u8, 9), p.basic.logical_bs_shift);

    // 1GB / 512 = 2^21 sectors
    try std.testing.expectEqual(@as(u64, 2097152), p.basic.dev_sectors);
}

test "sizeToShift" {
    try std.testing.expectEqual(@as(u8, 9), sizeToShift(512));
    try std.testing.expectEqual(@as(u8, 12), sizeToShift(4096));
    try std.testing.expectEqual(@as(u8, 0), sizeToShift(1));
}
