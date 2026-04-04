const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const io_uring = @import("io_uring.zig");
const uring_ring = @import("uring_ring.zig");
const log = std.log.scoped(.@"snek/uring_recv_group");

pub const DEFAULT_BUFFER_SIZE: u32 = 64 * 1024;
pub const DEFAULT_BUFFER_COUNT: u16 = 64;
pub const DEFAULT_GROUP_ID: u16 = 1;

const page_align = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const Lease = struct {
    buffer_id: u16,
    bytes: []u8,
};

/// Worker-local provided-buffer group for uring receives.
///
/// This is not true receive zero-copy on its own, but it uses the same
/// lease/refill ownership shape that the ZC receive path will require.
pub const Group = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,
    br: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    storage: []align(std.heap.page_size_min) u8,
    checked_out: []bool,
    buffer_size: u32,
    buffer_count: u16,
    group_id: u16,
    in_use_count: usize = 0,

    pub fn init(
        fd: posix.fd_t,
        allocator: std.mem.Allocator,
        group_id: u16,
        buffer_size: u32,
        buffer_count: u16,
    ) !Group {
        if (buffer_size == 0 or buffer_count == 0) return error.InvalidConfiguration;
        if (!std.math.isPowerOfTwo(buffer_count)) return error.BufferCountMustBePowerOfTwo;

        const total_bytes = @as(usize, buffer_size) * @as(usize, buffer_count);
        const storage = try std.heap.page_allocator.alignedAlloc(u8, page_align, total_bytes);
        errdefer std.heap.page_allocator.free(storage);

        const checked_out = try allocator.alloc(bool, buffer_count);
        errdefer allocator.free(checked_out);
        @memset(checked_out, false);

        const br = try uring_ring.setupBufRing(fd, buffer_count, group_id, .{ .inc = false });
        errdefer uring_ring.freeBufRing(fd, br, buffer_count, group_id) catch |e| {
            log.err("freeBufRing failed during init rollback: {}", .{e});
        };

        uring_ring.bufRingInit(br);
        const mask = uring_ring.bufRingMask(buffer_count);

        var idx: u16 = 0;
        while (idx < buffer_count) : (idx += 1) {
            const start = @as(usize, idx) * @as(usize, buffer_size);
            const buf = storage[start .. start + buffer_size];
            uring_ring.bufRingAdd(br, buf, idx, mask, idx);
        }
        uring_ring.bufRingAdvance(br, buffer_count);

        return .{
            .fd = fd,
            .allocator = allocator,
            .br = br,
            .storage = storage,
            .checked_out = checked_out,
            .buffer_size = buffer_size,
            .buffer_count = buffer_count,
            .group_id = group_id,
        };
    }

    pub fn deinit(self: *Group) !void {
        try uring_ring.freeBufRing(self.fd, self.br, self.buffer_count, self.group_id);
        std.heap.page_allocator.free(self.storage);
        self.allocator.free(self.checked_out);
        self.* = undefined;
    }

    pub fn groupId(self: *const Group) u16 {
        return self.group_id;
    }

    pub fn bufferCount(self: *const Group) usize {
        return self.buffer_count;
    }

    pub fn inUseCount(self: *const Group) usize {
        return self.in_use_count;
    }

    pub fn freeCount(self: *const Group) usize {
        return self.buffer_count - self.in_use_count;
    }

    pub fn totalBytes(self: *const Group) usize {
        return @as(usize, self.buffer_size) * @as(usize, self.buffer_count);
    }

    pub fn take(self: *Group, completion: io_uring.Completion) !Lease {
        if (completion.result <= 0) return error.InvalidCompletion;
        if (completion.buffer_more) return error.IncrementalBufferUnsupported;

        const buffer_id = completion.buffer_id orelse return error.NoBufferSelected;
        if (buffer_id >= self.buffer_count) return error.BufferIdInvalid;
        if (self.checked_out[buffer_id]) return error.BufferAlreadyCheckedOut;

        const len: usize = @intCast(completion.result);
        if (len > self.buffer_size) return error.BufferOverflow;

        self.checked_out[buffer_id] = true;
        self.in_use_count += 1;

        return .{
            .buffer_id = buffer_id,
            .bytes = self.bufferSlice(buffer_id)[0..len],
        };
    }

    pub fn release(self: *Group, lease: Lease) void {
        std.debug.assert(lease.buffer_id < self.buffer_count);
        std.debug.assert(self.checked_out[lease.buffer_id]);

        self.checked_out[lease.buffer_id] = false;
        self.in_use_count -= 1;

        const mask = uring_ring.bufRingMask(self.buffer_count);
        uring_ring.bufRingAdd(self.br, self.bufferSlice(lease.buffer_id), lease.buffer_id, mask, 0);
        uring_ring.bufRingAdvance(self.br, 1);
    }

    fn bufferSlice(self: *Group, buffer_id: u16) []u8 {
        const start = @as(usize, buffer_id) * @as(usize, self.buffer_size);
        return self.storage[start .. start + self.buffer_size];
    }
};
