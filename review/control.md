# Review: control.zig vs internal/ctrl/control.go

Maps to: `.go-ublk-ref/internal/ctrl/control.go`

## File Purpose

Controller manages the ublk control device (`/dev/ublk-control`) and handles device lifecycle operations: ADD_DEV, SET_PARAMS, START_DEV, STOP_DEV, DEL_DEV.

## Go Implementation Summary (381 lines)

```go
type Controller struct {
    controlFd int
    ring      uring.Ring
    logger    *logging.Logger
}

func NewController() (*Controller, error)
func (c *Controller) Close() error
func (c *Controller) AddDevice(params *DeviceParams) (uint32, error)
func (c *Controller) SetParams(deviceID uint32, params *DeviceParams) error
func (c *Controller) StartDevice(deviceID uint32) error
func (c *Controller) StopDevice(deviceID uint32) error
func (c *Controller) DeleteDevice(deviceID uint32) error
func (c *Controller) GetDeviceInfo(deviceID uint32) (*uapi.UblksrvCtrlDevInfo, error)
func (c *Controller) GetParams(deviceID uint32) (*uapi.UblkParams, error)
```

Key features:
- Logger injection for debugging
- `DeviceParams` struct for high-level configuration
- Auto-detect queue count
- Feature flag building based on params

## Zig Implementation (src/control.zig, 293 lines)

```zig
pub const Controller = struct {
    control_fd: std.posix.fd_t,
    uring: IoUring128,

    pub fn init() InitError!Controller
    pub fn deinit(self: *Controller) void
    pub fn addDevice(self: *Controller, dev_info: *uapi.UblksrvCtrlDevInfo) ControlError!u32
    pub fn setParams(self: *Controller, dev_id: u32, params_buf: *params.UblkParamsBuffer) ControlError!void
    pub fn startDevice(self: *Controller, dev_id: u32) ControlError!void
    pub fn stopDevice(self: *Controller, dev_id: u32) ControlError!void
    pub fn deleteDevice(self: *Controller, dev_id: u32) ControlError!void
    pub fn getDeviceInfo(self: *Controller, dev_id: u32, dev_info: *uapi.UblksrvCtrlDevInfo) ControlError!void
};
```

## Line-by-Line Analysis

### Initialization (Go lines 26-49 → Zig lines 27-51)

**Go:**
```go
func NewController() (*Controller, error) {
    fd, err := syscall.Open(UblkControlPath, syscall.O_RDWR, 0)
    if err != nil {
        return nil, fmt.Errorf("failed to open %s: %v", UblkControlPath, err)
    }
    ring, err := uring.NewRing(config)
    // ...
    return &Controller{controlFd: fd, ring: ring, logger: logging.Default()}, nil
}
```

**Zig:**
```zig
pub fn init() InitError!Controller {
    const fd = std.posix.open(uapi.UBLK_CONTROL_PATH, .{ .ACCMODE = .RDWR }, 0) catch |err| {
        return switch (err) {
            error.FileNotFound => error.DeviceNotFound,
            error.AccessDenied => error.PermissionDenied,
            else => err,
        };
    };
    errdefer std.posix.close(fd);

    var uring_instance = IoUring128.init(32) catch |err| { ... };
    errdefer uring_instance.deinit();

    return Controller{ .control_fd = fd, .uring = uring_instance };
}
```

**Analysis:**
- Go: Heap allocates controller, returns pointer
- Zig: Returns by value, no heap allocation
- Zig: Uses `errdefer` for cleanup on error - excellent pattern
- Zig: Explicit error translation - better than generic error wrapping
- **Missing in Zig**: No logger injection (good - library shouldn't log)

### AddDevice (Go lines 61-132 → Zig lines 59-96)

**Go:**
```go
func (c *Controller) AddDevice(params *DeviceParams) (uint32, error) {
    // Auto-detect queues
    numQueues := params.NumQueues
    if numQueues <= 0 { numQueues = 1 }

    devInfo := &uapi.UblksrvCtrlDevInfo{
        NrHwQueues: uint16(numQueues),
        // ... high-level params translated
        Flags: c.buildFeatureFlags(params),
    }

    c.logger.Debug("submitting ADD_DEV", ...)  // LOGGING IN LIBRARY

    deviceInfoBytes := uapi.Marshal(devInfo)
    cmd := &uapi.UblksrvCtrlCmd{ ... Addr: uint64(uintptr(unsafe.Pointer(&deviceInfoBytes[0]))), ... }

    result, err := c.ring.SubmitCtrlCmd(op, cmd, 0)
    runtime.KeepAlive(deviceInfoBytes)  // Prevent GC
    // ...
}
```

**Zig:**
```zig
pub fn addDevice(self: *Controller, dev_info: *uapi.UblksrvCtrlDevInfo) ControlError!u32 {
    const sqe = try self.uring.getSqe();
    sqe.prepUringCmd(uapi.ublkCtrlCmd(.add_dev), self.control_fd);
    sqe.user_data = 0xADD_DE7;

    const cmd = sqe.getCmd(uapi.UblksrvCtrlCmd);
    cmd.* = .{
        .dev_id = dev_info.dev_id,
        .addr = @intFromPtr(dev_info),
        // ...
    };

    _ = try self.uring.submitAndWait(1);
    // ... check result
    return dev_info.dev_id;
}
```

**Analysis:**
- Go: Takes high-level `DeviceParams`, builds `UblksrvCtrlDevInfo` internally
- Zig: Takes raw `UblksrvCtrlDevInfo` pointer directly
- Go: Needs `runtime.KeepAlive` to prevent GC collecting buffer
- Zig: No GC, pointer valid as long as caller holds it
- Go: Logs debug info - **bad for library code**
- Zig: No logging - **correct for library code**

**Trade-off**: Go's higher-level API is more ergonomic. Zig exposes raw kernel structs.

### Error Handling Pattern

**Go:**
```go
if result.Value() < 0 {
    return 0, fmt.Errorf("ADD_DEV failed with error: %d", result.Value())
}
```

**Zig:**
```zig
if (cqe.res < 0) {
    std.log.err("ADD_DEV failed with error: {d}", .{cqe.res});  // BAD
    return error.AddDeviceFailed;  // GOOD
}
```

**Issue**: Zig both logs AND returns error. Should only return error.

### START_DEV Special Handling (Go lines 205-230 → Zig lines 166-210)

Both implementations handle the requirement that START_DEV blocks until the queue thread enters io_uring wait state. The Zig version has a retry loop:

```zig
var attempts: u32 = 0;
while (attempts < 10) : (attempts += 1) {
    const ready = self.uring.cqReady();
    if (ready > 0) break;
    const res = linux.io_uring_enter(self.uring.fd, 0, 1, linux.IORING_ENTER_GETEVENTS, null);
    // ...
}
```

This is correct - the kernel requires the queue to be in a waiting state.

## What's Missing in Zig

1. **High-level DeviceParams** - Go has nice config struct
2. **GetParams** - Go has it, Zig doesn't
3. **Feature flag builder** - Go's `buildFeatureFlags()` translates options to flags
4. **Queue affinity getter** - `UBLK_CMD_GET_QUEUE_AFFINITY`

## What Zig Does Better

1. **No heap allocation** - Controller returned by value
2. **No logging in library** - Caller decides logging
3. **`errdefer` cleanup** - Automatic cleanup on error paths
4. **Explicit error types** - `ControlError` enum with specific variants

## API Ergonomics Issue

**Current Zig usage:**
```zig
var dev_info = std.mem.zeroInit(ublk.UblksrvCtrlDevInfo, .{});
dev_info.nr_hw_queues = 1;
dev_info.queue_depth = 64;
dev_info.max_io_buf_bytes = 512 * 1024;
dev_info.dev_id = 0xFFFF_FFFF;
dev_info.ublksrv_pid = @intCast(std.os.linux.getpid());
dev_info.flags = 0x02;
const dev_id = try controller.addDevice(&dev_info);
```

**Better ergonomics (builder pattern):**
```zig
const dev_id = try controller.addDevice(.{
    .queues = 1,
    .depth = 64,
    .max_io_size = 512 * 1024,
    .flags = .{ .ioctl_encode = true },
});
```

## Recommendations

### 1. Remove Logging from Error Paths

```zig
// Before (bad)
if (cqe.res < 0) {
    std.log.err("ADD_DEV failed: {d}", .{cqe.res});
    return error.AddDeviceFailed;
}

// After (good)
if (cqe.res < 0) {
    return error.AddDeviceFailed;
}
```

### 2. Add High-Level Config API

```zig
pub const DeviceConfig = struct {
    queues: u16 = 1,
    depth: u16 = 64,
    max_io_size: u32 = 512 * 1024,
    features: Features = .{},

    pub const Features = packed struct {
        ioctl_encode: bool = true,
        user_copy: bool = false,
        // ...
    };
};

pub fn createDevice(self: *Controller, config: DeviceConfig) !u32 {
    var dev_info = std.mem.zeroInit(uapi.UblksrvCtrlDevInfo, .{});
    dev_info.nr_hw_queues = config.queues;
    // ... translate config to dev_info
    return self.addDevice(&dev_info);
}
```

### 3. Add GetParams

```zig
pub fn getParams(self: *Controller, dev_id: u32, params_buf: *params.UblkParamsBuffer) ControlError!void {
    // ... similar to setParams but with get_params command
}
```
