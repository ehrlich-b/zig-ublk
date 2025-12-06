//! Queue runner for ublk IO handling
//!
//! Handles IO operations for a single ublk queue via /dev/ublkcN

const std = @import("std");
const linux = std.os.linux;

const ring = @import("ring.zig");
const uapi = @import("uapi.zig");

const IoUring128 = ring.IoUring128;
const IoUringCqe32 = ring.IoUringCqe32;

/// Tag state for the per-tag state machine
pub const TagState = enum {
    /// FETCH_REQ submitted, waiting for completion
    in_flight_fetch,
    /// We own the descriptor, can process IO
    owned,
    /// COMMIT_AND_FETCH_REQ submitted, waiting for completion
    in_flight_commit,
};

/// Queue runner handles IO for a single ublk queue
pub const Queue = struct {
    device_id: u32,
    queue_id: u16,
    depth: u16,
    char_fd: std.posix.fd_t,
    uring: IoUring128,

    // mmap'd regions
    desc_mmap: []align(std.heap.page_size_min) u8,
    buf_mmap: []align(std.heap.page_size_min) u8,

    // Typed views into mmap'd memory
    descriptors: []volatile uapi.UblksrvIoDesc,
    buffers_base: [*]u8,

    // Per-tag state tracking
    tag_states: []TagState,

    pub const InitError = error{
        DeviceNotFound,
        PermissionDenied,
        MmapFailed,
        OutOfMemory,
    } || std.posix.OpenError || IoUring128.InitError;

    /// Initialize a queue runner for the given device
    pub fn init(device_id: u32, queue_id: u16, depth: u16, allocator: std.mem.Allocator) InitError!Queue {
        // Open character device /dev/ublkcN
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/dev/ublkc{d}\x00", .{device_id}) catch unreachable;

        const char_fd = std.posix.open(path[0 .. path.len - 1], .{ .ACCMODE = .RDWR }, 0) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DeviceNotFound,
                error.AccessDenied => error.PermissionDenied,
                else => err,
            };
        };
        errdefer std.posix.close(char_fd);

        // Create io_uring for this queue
        var uring_instance = try IoUring128.init(depth);
        errdefer uring_instance.deinit();

        // Calculate mmap sizes
        const page_size = std.heap.page_size_min;
        const desc_size_raw = @as(usize, depth) * @sizeOf(uapi.UblksrvIoDesc);
        const desc_size = std.mem.alignForward(usize, desc_size_raw, page_size);
        const buf_size = @as(usize, depth) * uapi.IO_BUFFER_SIZE_PER_TAG;

        // mmap offset for this queue's descriptors
        const mmap_offset: u64 = @as(u64, queue_id) * desc_size;

        // mmap descriptor array (read-only from userspace)
        const desc_mmap = std.posix.mmap(
            null,
            desc_size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED, .POPULATE = true },
            char_fd,
            mmap_offset,
        ) catch return error.MmapFailed;
        errdefer std.posix.munmap(desc_mmap);

        // mmap IO buffers (anonymous, read-write)
        const buf_mmap = std.posix.mmap(
            null,
            buf_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MmapFailed;
        errdefer std.posix.munmap(buf_mmap);

        // Allocate tag state array
        const tag_states = allocator.alloc(TagState, depth) catch return error.OutOfMemory;
        @memset(tag_states, .in_flight_fetch);

        // Create typed views
        const descriptors: []volatile uapi.UblksrvIoDesc = @as([*]volatile uapi.UblksrvIoDesc, @ptrCast(@alignCast(desc_mmap.ptr)))[0..depth];

        return Queue{
            .device_id = device_id,
            .queue_id = queue_id,
            .depth = depth,
            .char_fd = char_fd,
            .uring = uring_instance,
            .desc_mmap = desc_mmap,
            .buf_mmap = buf_mmap,
            .descriptors = descriptors,
            .buffers_base = buf_mmap.ptr,
            .tag_states = tag_states,
        };
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        allocator.free(self.tag_states);
        std.posix.munmap(self.buf_mmap);
        std.posix.munmap(self.desc_mmap);
        self.uring.deinit();
        std.posix.close(self.char_fd);
    }

    /// Get the IO buffer for a specific tag
    pub fn getBuffer(self: *Queue, tag: u16) []u8 {
        const offset = @as(usize, tag) * uapi.IO_BUFFER_SIZE_PER_TAG;
        return self.buffers_base[offset..][0..uapi.IO_BUFFER_SIZE_PER_TAG];
    }

    /// Submit initial FETCH_REQ for all tags (called before START_DEV)
    pub fn prime(self: *Queue) QueueError!void {
        for (0..self.depth) |tag_usize| {
            const tag: u16 = @intCast(tag_usize);
            try self.submitFetchReq(tag);
        }
        // Submit all at once
        _ = try self.uring.submit();
    }

    /// Submit a FETCH_REQ for a specific tag
    fn submitFetchReq(self: *Queue, tag: u16) QueueError!void {
        const sqe = try self.uring.getSqe();

        // Prepare URING_CMD for FETCH_REQ
        sqe.prepUringCmd(uapi.ublkIoCmd(.fetch_req), self.char_fd);

        // Encode user_data: tag in low 16 bits, queue_id in bits 16-31, high bit = 0 for fetch
        sqe.user_data = (@as(u64, self.queue_id) << 16) | @as(u64, tag);

        // Fill IO command in SQE cmd area
        const io_cmd = sqe.getCmd(uapi.UblksrvIoCmd);
        const buffer_addr = @intFromPtr(self.buffers_base) + @as(usize, tag) * uapi.IO_BUFFER_SIZE_PER_TAG;
        io_cmd.* = .{
            .qid = self.queue_id,
            .tag = tag,
            .result = 0,
            .addr = buffer_addr,
        };

        self.tag_states[tag] = .in_flight_fetch;
    }

    /// Submit a COMMIT_AND_FETCH_REQ for a specific tag
    fn submitCommitAndFetch(self: *Queue, tag: u16, result: i32) QueueError!void {
        const sqe = try self.uring.getSqe();

        // Prepare URING_CMD for COMMIT_AND_FETCH_REQ
        sqe.prepUringCmd(uapi.ublkIoCmd(.commit_and_fetch_req), self.char_fd);

        // Encode user_data: high bit = 1 for commit
        sqe.user_data = (1 << 63) | (@as(u64, self.queue_id) << 16) | @as(u64, tag);

        // Fill IO command
        const io_cmd = sqe.getCmd(uapi.UblksrvIoCmd);
        const buffer_addr = @intFromPtr(self.buffers_base) + @as(usize, tag) * uapi.IO_BUFFER_SIZE_PER_TAG;
        io_cmd.* = .{
            .qid = self.queue_id,
            .tag = tag,
            .result = result,
            .addr = buffer_addr,
        };

        self.tag_states[tag] = .in_flight_commit;
    }

    /// IO handler callback type
    pub const IoHandler = *const fn (queue_ptr: *Queue, tag: u16, desc: uapi.UblksrvIoDesc, buffer: []u8) i32;

    /// Process one batch of completions. Returns number processed.
    pub fn processCompletions(self: *Queue, handler: IoHandler) QueueError!u32 {
        // Wait for at least one completion
        _ = try self.uring.submitAndWait(1);

        var cqes: [64]IoUringCqe32 = undefined;
        const count = self.uring.copyCqes(&cqes);

        for (cqes[0..count]) |cqe| {
            const user_data = cqe.user_data;
            const tag: u16 = @truncate(user_data & 0xFFFF);
            const result = cqe.res;

            if (tag >= self.depth) continue;

            if (result < 0) {
                // Error from kernel
                std.log.err("Queue {d} tag {d}: error {d}", .{ self.queue_id, tag, result });
                continue;
            }

            // State machine
            const state = self.tag_states[tag];

            switch (state) {
                .in_flight_fetch, .in_flight_commit => {
                    if (result == 0) {
                        // IO request ready - read descriptor and process
                        self.tag_states[tag] = .owned;
                        const desc = self.descriptors[tag];

                        // Skip empty descriptors (keepalive)
                        if (desc.op_flags == 0 and desc.nr_sectors == 0) {
                            try self.submitCommitAndFetch(tag, 0);
                            continue;
                        }

                        // Call handler to process IO
                        const buffer = self.getBuffer(tag);
                        const io_result = handler(self, tag, desc, buffer);

                        // Calculate result: nr_sectors * 512 for success, negative errno for error
                        const commit_result: i32 = if (io_result >= 0)
                            @as(i32, @intCast(desc.nr_sectors)) << 9
                        else
                            io_result;

                        try self.submitCommitAndFetch(tag, commit_result);
                    }
                },
                .owned => {
                    // Shouldn't get completion in owned state
                    std.log.warn("Queue {d} tag {d}: unexpected completion in owned state", .{ self.queue_id, tag });
                },
            }
        }

        // Flush any pending submissions
        _ = try self.uring.submit();

        return count;
    }

    pub const QueueError = error{
        SubmissionQueueFull,
        SystemResources,
        FileDescriptorInvalid,
        CompletionQueueOvercommitted,
        SubmissionQueueEntryInvalid,
        BufferInvalid,
        Unexpected,
    };
};
