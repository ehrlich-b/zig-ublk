# Examples

Working examples demonstrating zig-ublk usage.

## Requirements

All examples require:
- Linux kernel >= 6.0 with `ublk_drv` module loaded
- Root privileges (or CAP_SYS_ADMIN)

```bash
# Load the ublk kernel module
sudo modprobe ublk_drv
```

## Examples

### null.zig - Null Block Device

The simplest backend - discards all writes and returns zeros on read. Good for understanding the ublk lifecycle.

```bash
# Build and run
sudo zig build run-example-null

# In another terminal, test it
dd if=/dev/ublkb0 bs=4k count=1 | hexdump -C  # Read zeros
dd if=/dev/zero of=/dev/ublkb0 bs=4k count=1  # Write (discarded)
```

Key concepts demonstrated:
- Controller initialization and device creation
- Parameter configuration (device size, block size)
- Queue setup with IO handler callback
- Threaded IO processing (queue must run in separate thread)
- Graceful shutdown with defer

### memory.zig - RAM Disk

A 64MB RAM-backed block device that actually stores data in memory.

```bash
# Build and run
sudo zig build run-example-memory

# In another terminal, test data persistence
echo "Hello ublk!" | sudo dd of=/dev/ublkb0 bs=512 count=1
sudo dd if=/dev/ublkb0 bs=512 count=1 | head -c 20  # Should show "Hello ublk!"
```

Key concepts demonstrated:
- Backend with actual storage (not just null)
- Handling READ/WRITE with offset calculations
- Global state for handler callback
- Bounds checking for IO requests

### null_bench.zig - Benchmark Version

Stripped-down null device optimized for benchmarking. No debug output in hot path.

```bash
# Build (always ReleaseFast)
zig build

# Run on a VM with fio
sudo ./zig-out/bin/example-null-bench &
fio --name=iops --rw=randread --bs=4k --direct=1 --ioengine=libaio \
    --iodepth=64 --runtime=10 --filename=/dev/ublkb0
```

Key optimizations:
- No `std.debug.print` in IO loop (syscall overhead)
- Higher queue depth (128)
- Always compiled with `-Doptimize=ReleaseFast`

## Device Lifecycle

All examples follow this pattern:

```
1. Controller.init()      - Open /dev/ublk-control
2. addDevice()            - Create device, get assigned ID
3. setParams()            - Configure size, block size, features
4. Queue.init()           - Open /dev/ublkcN, mmap descriptors
5. queue.prime()          - Submit initial FETCH_REQ commands
6. startDevice()          - Activate /dev/ublkbN (blocks until queue waiting)
7. processCompletions()   - IO loop: handle requests, resubmit
8. stopDevice()           - Deactivate block device
9. deleteDevice()         - Remove device from kernel
```

## Writing Your Own Backend

Implement a handler function with this signature:

```zig
fn myHandler(
    queue: *ublk.Queue,   // Queue context (rarely needed)
    tag: u16,             // Request tag (for tracking)
    desc: ublk.UblksrvIoDesc, // IO descriptor with operation details
    buffer: []u8,         // Data buffer for read/write
) i32 {                   // Return 0 for success, negative errno for error
    const op = desc.getIoOp() orelse return -5; // -EIO
    const offset = desc.start_sector * 512;
    const length = desc.nr_sectors * 512;

    switch (op) {
        .read => { /* fill buffer with data */ },
        .write => { /* store data from buffer */ },
        .flush => { /* sync to persistent storage */ },
        .discard => { /* mark region as unused */ },
        else => return -95, // -EOPNOTSUPP
    }
    return 0;
}
```

Then pass it to `queue.processCompletions(myHandler)`.
