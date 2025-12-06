//! zig-ublk: Native Zig implementation of Linux ublk
//!
//! This is a userspace block device driver using io_uring for kernel communication.
//!
//! ## Usage
//!
//! ```zig
//! const ublk = @import("zig-ublk");
//!
//! // Create controller
//! var ctrl = try ublk.Controller.init();
//! defer ctrl.deinit();
//!
//! // Add device
//! var dev_info = std.mem.zeroes(ublk.UblksrvCtrlDevInfo);
//! dev_info.nr_hw_queues = 1;
//! dev_info.queue_depth = 64;
//! const dev_id = try ctrl.addDevice(&dev_info);
//!
//! // Configure parameters
//! const params = ublk.UblkParams.initBasic(1024 * 1024 * 1024, 512);
//! var params_buf = ublk.UblkParamsBuffer.init(params);
//! try ctrl.setParams(dev_id, &params_buf);
//!
//! // Set up queue and start device
//! var queue = try ublk.Queue.init(dev_id, 0, 64, allocator);
//! defer queue.deinit(allocator);
//!
//! try queue.prime();
//! try ctrl.startDevice(dev_id);
//! ```

const std = @import("std");

// ============================================================================
// Module Re-exports
// ============================================================================

pub const uapi = @import("uapi.zig");
pub const params = @import("params.zig");
pub const ring = @import("ring.zig");
pub const control = @import("control.zig");
pub const queue = @import("queue.zig");

// ============================================================================
// Convenience Re-exports (top-level access)
// ============================================================================

// Ring types
pub const IoUring128 = ring.IoUring128;
pub const IoUringSqe128 = ring.IoUringSqe128;
pub const IoUringCqe32 = ring.IoUringCqe32;

// Controller
pub const Controller = control.Controller;

// Queue
pub const Queue = queue.Queue;
pub const TagState = queue.TagState;

// UAPI structures
pub const UblksrvCtrlCmd = uapi.UblksrvCtrlCmd;
pub const UblksrvIoCmd = uapi.UblksrvIoCmd;
pub const UblksrvIoDesc = uapi.UblksrvIoDesc;
pub const UblksrvCtrlDevInfo = uapi.UblksrvCtrlDevInfo;
pub const CtrlCmd = uapi.CtrlCmd;
pub const IoCmd = uapi.IoCmd;
pub const IoOp = uapi.IoOp;
pub const ublkCtrlCmd = uapi.ublkCtrlCmd;
pub const ublkIoCmd = uapi.ublkIoCmd;

// Parameters
pub const UblkParams = params.UblkParams;
pub const UblkParamsBuffer = params.UblkParamsBuffer;
pub const UblkParamBasic = params.UblkParamBasic;
pub const UblkParamDiscard = params.UblkParamDiscard;
pub const UblkParamDevt = params.UblkParamDevt;
pub const UblkParamZoned = params.UblkParamZoned;

// Constants
pub const UBLK_CONTROL_PATH = uapi.UBLK_CONTROL_PATH;
pub const IO_BUFFER_SIZE_PER_TAG = uapi.IO_BUFFER_SIZE_PER_TAG;
pub const UBLK_PARAM_TYPE_BASIC = params.UBLK_PARAM_TYPE_BASIC;
pub const UBLK_PARAM_TYPE_DISCARD = params.UBLK_PARAM_TYPE_DISCARD;
pub const UBLK_PARAM_TYPE_DEVT = params.UBLK_PARAM_TYPE_DEVT;
pub const UBLK_PARAM_TYPE_ZONED = params.UBLK_PARAM_TYPE_ZONED;
pub const UBLK_ATTR_READ_ONLY = params.UBLK_ATTR_READ_ONLY;
pub const UBLK_ATTR_ROTATIONAL = params.UBLK_ATTR_ROTATIONAL;
pub const UBLK_ATTR_VOLATILE_CACHE = params.UBLK_ATTR_VOLATILE_CACHE;
pub const UBLK_ATTR_FUA = params.UBLK_ATTR_FUA;

// ============================================================================
// Tests - Run all module tests
// ============================================================================

test {
    // Import all modules to run their tests
    std.testing.refAllDecls(@This());
}
