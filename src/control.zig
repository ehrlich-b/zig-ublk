//! Controller for managing ublk devices via /dev/ublk-control
//!
//! Handles device lifecycle: ADD_DEV, SET_PARAMS, START_DEV, STOP_DEV, DEL_DEV

const std = @import("std");
const linux = std.os.linux;

const ring = @import("ring.zig");
const uapi = @import("uapi.zig");
const params = @import("params.zig");

const IoUring128 = ring.IoUring128;
const IoUringCqe32 = ring.IoUringCqe32;

/// Controller for managing ublk devices via /dev/ublk-control
pub const Controller = struct {
    control_fd: std.posix.fd_t,
    uring: IoUring128,

    pub const InitError = error{
        DeviceNotFound,
        PermissionDenied,
        IoUringInitFailed,
    } || std.posix.OpenError || IoUring128.InitError;

    /// Open the ublk control device and initialize io_uring
    pub fn init() InitError!Controller {
        // Open /dev/ublk-control
        const fd = std.posix.open(uapi.UBLK_CONTROL_PATH, .{ .ACCMODE = .RDWR }, 0) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DeviceNotFound,
                error.AccessDenied => error.PermissionDenied,
                else => err,
            };
        };
        errdefer std.posix.close(fd);

        // Initialize io_uring with SQE128/CQE32 for URING_CMD
        var uring_instance = IoUring128.init(32) catch |err| {
            return switch (err) {
                error.PermissionDenied => error.PermissionDenied,
                else => err,
            };
        };
        errdefer uring_instance.deinit();

        return Controller{
            .control_fd = fd,
            .uring = uring_instance,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.uring.deinit();
        std.posix.close(self.control_fd);
    }

    /// Submit an ADD_DEV command to create a new ublk device
    pub fn addDevice(self: *Controller, dev_info: *uapi.UblksrvCtrlDevInfo) ControlError!u32 {
        const sqe = try self.uring.getSqe();

        // Prepare URING_CMD for ADD_DEV with ioctl encoding
        sqe.prepUringCmd(uapi.ublkCtrlCmd(.add_dev), self.control_fd);
        sqe.user_data = 0xADD_DE7;

        // Fill in the control command in the SQE cmd area
        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_info.dev_id,
            .queue_id = 0xFFFF, // Control operation
            .len = @sizeOf(uapi.UblksrvCtrlDevInfo),
            .addr = @intFromPtr(dev_info),
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        // Submit and wait for completion
        _ = try self.uring.submitAndWait(1);

        // Get the completion
        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.AddDeviceFailed;
        }

        // Return the assigned device ID (may be updated by kernel)
        return dev_info.dev_id;
    }

    /// Submit a SET_PARAMS command to configure device parameters
    pub fn setParams(self: *Controller, dev_id: u32, params_buf: *params.UblkParamsBuffer) ControlError!void {
        const sqe = try self.uring.getSqe();

        // Prepare URING_CMD for SET_PARAMS with ioctl encoding
        sqe.prepUringCmd(uapi.ublkCtrlCmd(.set_params), self.control_fd);
        sqe.user_data = 0x5E7_0A4A; // SET_PARAMS marker

        // Fill in the control command in the SQE cmd area
        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_id,
            .queue_id = 0xFFFF, // Control operation
            .len = 128, // Buffer size
            .addr = @intFromPtr(params_buf),
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        // Submit and wait for completion
        _ = try self.uring.submitAndWait(1);

        // Get the completion
        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.SetParamsFailed;
        }
    }

    /// Submit a GET_DEV_INFO command to retrieve device information
    pub fn getDeviceInfo(self: *Controller, dev_id: u32, dev_info: *uapi.UblksrvCtrlDevInfo) ControlError!void {
        const sqe = try self.uring.getSqe();

        sqe.prepUringCmd(uapi.ublkCtrlCmd(.get_dev_info), self.control_fd);
        sqe.user_data = 0x6E7_1AF0; // GET_DEV_INFO marker

        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_id,
            .queue_id = 0xFFFF,
            .len = @sizeOf(uapi.UblksrvCtrlDevInfo),
            .addr = @intFromPtr(dev_info),
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        _ = try self.uring.submitAndWait(1);

        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.GetDeviceInfoFailed;
        }
    }

    /// Submit a START_DEV command to activate the device
    /// Note: Queue must be in wait state (io_uring_enter) before calling this
    pub fn startDevice(self: *Controller, dev_id: u32) ControlError!void {
        const sqe = try self.uring.getSqe();

        sqe.prepUringCmd(uapi.ublkCtrlCmd(.start_dev), self.control_fd);
        sqe.user_data = 0x57A_47DE; // START_DEV marker

        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_id,
            .queue_id = 0xFFFF,
            .len = 0,
            .addr = 0,
            .data = @intCast(std.os.linux.getpid()), // PID required for START_DEV
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        // Submit and wait for completion
        // Note: This will block until the queue thread enters io_uring wait
        _ = try self.uring.submit();

        // Wait for completion - kernel will complete START_DEV when queue is ready
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            const ready = self.uring.cqReady();
            if (ready > 0) break;
            // Wait for completion
            const res = linux.io_uring_enter(self.uring.fd, 0, 1, linux.IORING_ENTER_GETEVENTS, null);
            if (linux.errno(res) == .SUCCESS) break;
            if (linux.errno(res) == .INTR) continue;
        }

        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.StartDeviceFailed;
        }
    }

    /// Submit a STOP_DEV command to deactivate the device
    pub fn stopDevice(self: *Controller, dev_id: u32) ControlError!void {
        const sqe = try self.uring.getSqe();

        sqe.prepUringCmd(uapi.ublkCtrlCmd(.stop_dev), self.control_fd);
        sqe.user_data = 0x570_0DE7; // STOP_DEV marker

        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_id,
            .queue_id = 0xFFFF,
            .len = 0,
            .addr = 0,
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        _ = try self.uring.submitAndWait(1);

        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.StopDeviceFailed;
        }
    }

    /// Submit a DEL_DEV command to delete the device
    pub fn deleteDevice(self: *Controller, dev_id: u32) ControlError!void {
        const sqe = try self.uring.getSqe();

        sqe.prepUringCmd(uapi.ublkCtrlCmd(.del_dev), self.control_fd);
        sqe.user_data = 0xDE1_DE77; // DEL_DEV marker

        const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
        cmd.* = .{
            .dev_id = dev_id,
            .queue_id = 0xFFFF,
            .len = 0,
            .addr = 0,
            .data = 0,
            .dev_path_len = 0,
            .pad = 0,
            .reserved = 0,
        };

        _ = try self.uring.submitAndWait(1);

        var cqes: [1]IoUringCqe32 = undefined;
        const n = self.uring.copyCqes(&cqes);
        if (n == 0) return error.NoCompletion;

        const cqe = cqes[0];
        if (cqe.res < 0) {
            return error.DeleteDeviceFailed;
        }
    }

    pub const ControlError = error{
        SubmissionQueueFull,
        NoCompletion,
        AddDeviceFailed,
        SetParamsFailed,
        GetDeviceInfoFailed,
        StartDeviceFailed,
        StopDeviceFailed,
        DeleteDeviceFailed,
        SystemResources,
        FileDescriptorInvalid,
        CompletionQueueOvercommitted,
        SubmissionQueueEntryInvalid,
        BufferInvalid,
        Unexpected,
    };
};
