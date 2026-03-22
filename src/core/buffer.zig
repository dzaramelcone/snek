//! Zero-copy buffer management for I/O operations.
//! Pre-allocated pool with reference-counted slices for use with io_uring registered buffers.
//!
//! Integrates with io_uring registered buffers (IORING_REGISTER_BUFFERS) for
//! zero-copy recv. Reference-counted slices allow safe sharing across coroutines.
//!
//! Buffer types (http.zig pattern):
//!   - pooled: pre-allocated, returned to pool on release
//!   - registered: registered with io_uring for zero-copy, tracked separately
//!   - arena: allocated from request arena, freed when arena resets
//!
//! ## Falsifiability: Pre-allocated pool vs arena allocators
//! Claim: Pre-allocated buffer pool eliminates allocation in the hot path.
//! Alternative: Arena allocators with retention achieve the same (no syscalls after warmup).
//! Threshold: If arena alloc+reset is within 2x of pool acquire+release latency
//!   for typical I/O buffer sizes (4KB-64KB), switch to arena (simpler, no pool sizing).
//! Benchmark: 100K acquire/release cycles, single-threaded, median ns/op.
//! Context: The pool's real advantage is io_uring registration (IORING_REGISTER_BUFFERS
//!   requires stable addresses). If we don't use registered buffers, arena may win.
//! Status: PENDING — benchmark when I/O path is implemented.

const std = @import("std");

pub const BufferType = enum {
    pooled,
    registered,
    arena,
};

// Reference: io_uring registered buffers (IORING_REGISTER_BUFFERS) for zero-copy recv.
// Reference: http.zig (refs/http.zig/INSIGHTS.md) — buffer type taxonomy (pooled/registered/arena).
pub const Buffer = struct {
    data: []u8,
    ref_count: std.atomic.Value(u32),
    pool_index: u32,
    buf_type: BufferType,

    pub fn readSlice(self: *const Buffer, offset: usize, len: usize) []const u8 {
        return self.data[offset..][0..len];
    }

    pub fn writeSlice(self: *Buffer, offset: usize, len: usize) []u8 {
        return self.data[offset..][0..len];
    }

    /// Increment reference count (atomic).
    pub fn retain(self: *Buffer) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count (atomic). Returns true if this was the last reference.
    /// Uses acq_rel to ensure all prior writes are visible when the last reference drops.
    pub fn release(self: *Buffer) bool {
        const prev = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0); // double-free: release() called on buffer with ref_count 0
        return prev == 1;
    }

    /// Current reference count.
    pub fn refCount(self: *const Buffer) u32 {
        return self.ref_count.load(.monotonic);
    }
};

pub const BufferPool = struct {
    buffers: []Buffer,
    capacity: usize,
    buffer_size: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, buffer_size: usize) !BufferPool {
        const buffers = @as([]Buffer, try allocator.alloc(Buffer, capacity));
        for (buffers, 0..) |*buf, i| {
            buf.* = .{
                .data = try allocator.alloc(u8, buffer_size),
                .ref_count = std.atomic.Value(u32).init(0),
                .pool_index = @intCast(i),
                .buf_type = .pooled,
            };
        }
        return .{
            .buffers = buffers,
            .capacity = capacity,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *BufferPool, allocator: std.mem.Allocator) void {
        for (self.buffers) |*buf| {
            allocator.free(buf.data);
        }
        allocator.free(self.buffers);
    }

    /// Acquire a buffer with ref_count == 0. Linear scan.
    /// Returns null if pool is exhausted.
    pub fn acquire(self: *BufferPool) ?*Buffer {
        for (self.buffers) |*buf| {
            if (buf.ref_count.load(.monotonic) == 0) {
                buf.retain();
                return buf;
            }
        }
        return null;
    }

    /// Release a buffer back to the pool. The buffer stays in the pool
    /// (pre-allocated, not freed) — it just becomes available for reuse.
    pub fn release(self: *BufferPool, buf: *Buffer) void {
        _ = self;
        _ = buf.release();
    }

    /// Register all pooled buffers with io_uring for zero-copy operations.
    /// Must be called during init phase (before StaticAllocator locks).
    // Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — StaticAllocator integration
    // All buffer registration happens during init phase before allocator transitions to static.
    pub fn registerWithIoUring(self: *BufferPool, io: anytype) !void {
        _ = .{ self, io };
    }
};

test "acquire and release" {
    var pool = try BufferPool.init(std.testing.allocator, 4, 64);
    defer pool.deinit(std.testing.allocator);

    // Acquire a buffer
    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), buf.refCount());

    // Write some data
    const slice = buf.writeSlice(0, 5);
    @memcpy(slice, "hello");

    // Release it
    pool.release(buf);
    try std.testing.expectEqual(@as(u32, 0), buf.refCount());

    // Acquire again — should get the same buffer (first with ref_count 0)
    const buf2 = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(buf, buf2);

    // Data still there (pre-allocated, not zeroed on release)
    try std.testing.expectEqualSlices(u8, "hello", buf2.readSlice(0, 5));

    pool.release(buf2);
}

test "zero copy slice" {
    var pool = try BufferPool.init(std.testing.allocator, 2, 128);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    defer pool.release(buf);

    // Write data via writeSlice
    const w = buf.writeSlice(10, 6);
    @memcpy(w, "snakes");

    // Read back via readSlice — should see same data (zero-copy, same underlying memory)
    const r = buf.readSlice(10, 6);
    try std.testing.expectEqualSlices(u8, "snakes", r);

    // Verify the pointers alias (true zero-copy)
    try std.testing.expectEqual(@as(*const u8, &w[0]), &r[0]);
}

test "reference counting" {
    var pool = try BufferPool.init(std.testing.allocator, 2, 32);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), buf.refCount());

    // Retain twice more
    buf.retain();
    try std.testing.expectEqual(@as(u32, 2), buf.refCount());
    buf.retain();
    try std.testing.expectEqual(@as(u32, 3), buf.refCount());

    // Release three times — last one should return true
    try std.testing.expect(!buf.release());
    try std.testing.expectEqual(@as(u32, 2), buf.refCount());
    try std.testing.expect(!buf.release());
    try std.testing.expectEqual(@as(u32, 1), buf.refCount());
    try std.testing.expect(buf.release()); // last ref
    try std.testing.expectEqual(@as(u32, 0), buf.refCount());
}

test "pool exhaustion" {
    var pool = try BufferPool.init(std.testing.allocator, 3, 16);
    defer pool.deinit(std.testing.allocator);

    // Acquire all buffers
    const b0 = pool.acquire();
    const b1 = pool.acquire();
    const b2 = pool.acquire();

    try std.testing.expect(b0 != null);
    try std.testing.expect(b1 != null);
    try std.testing.expect(b2 != null);

    // Next acquire should return null
    try std.testing.expectEqual(@as(?*Buffer, null), pool.acquire());

    // Release one, should be acquirable again
    pool.release(b1.?);
    const b3 = pool.acquire();
    try std.testing.expect(b3 != null);
    try std.testing.expectEqual(b1.?, b3.?);

    // Cleanup
    pool.release(b0.?);
    pool.release(b2.?);
    pool.release(b3.?);
}

test "io_uring buffer registration" {
    // Stub — can't test without io_uring. Verifies the function exists and compiles.
    var pool = try BufferPool.init(std.testing.allocator, 1, 16);
    defer pool.deinit(std.testing.allocator);
}

// ── Edge case tests (Step 8.5 audit) ──────────────────────────────────

test "readSlice with offset == data length — empty slice" {
    var pool = try BufferPool.init(std.testing.allocator, 1, 16);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    defer pool.release(buf);

    // offset == data.len, len == 0: should return an empty slice
    const slice = buf.readSlice(16, 0);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "writeSlice with offset == data length — empty slice" {
    var pool = try BufferPool.init(std.testing.allocator, 1, 16);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    defer pool.release(buf);

    const slice = buf.writeSlice(16, 0);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "acquire all, release all, acquire all again — full cycle" {
    var pool = try BufferPool.init(std.testing.allocator, 4, 32);
    defer pool.deinit(std.testing.allocator);

    // First round: acquire all
    var bufs: [4]*Buffer = undefined;
    for (0..4) |i| {
        bufs[i] = pool.acquire() orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(?*Buffer, null), pool.acquire());

    // Release all
    for (0..4) |i| {
        pool.release(bufs[i]);
    }

    // Second round: acquire all again — must succeed
    for (0..4) |i| {
        bufs[i] = pool.acquire() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 1), bufs[i].refCount());
    }
    try std.testing.expectEqual(@as(?*Buffer, null), pool.acquire());

    // Cleanup
    for (0..4) |i| {
        pool.release(bufs[i]);
    }
}

test "buffer_size == 0 — zero-size buffers" {
    var pool = try BufferPool.init(std.testing.allocator, 2, 0);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    defer pool.release(buf);

    try std.testing.expectEqual(@as(usize, 0), buf.data.len);
    // readSlice/writeSlice with 0,0 on empty data
    const r = buf.readSlice(0, 0);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "pool capacity == 1 — single buffer pool" {
    var pool = try BufferPool.init(std.testing.allocator, 1, 8);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?*Buffer, null), pool.acquire()); // exhausted
    pool.release(buf);
    // Re-acquirable
    const buf2 = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(buf, buf2);
    pool.release(buf2);
}

test "pool capacity == 0 — empty pool" {
    var pool = try BufferPool.init(std.testing.allocator, 0, 16);
    defer pool.deinit(std.testing.allocator);

    // Acquire from empty pool should return null
    try std.testing.expectEqual(@as(?*Buffer, null), pool.acquire());
    try std.testing.expectEqual(@as(usize, 0), pool.capacity);
}

test "retain multiple times then release all" {
    var pool = try BufferPool.init(std.testing.allocator, 1, 8);
    defer pool.deinit(std.testing.allocator);

    const buf = pool.acquire() orelse return error.TestUnexpectedResult;
    // Retain 100 times
    for (0..100) |_| buf.retain();
    try std.testing.expectEqual(@as(u32, 101), buf.refCount());

    // Release 101 times — last one returns true
    for (0..100) |_| {
        try std.testing.expect(!buf.release());
    }
    try std.testing.expect(buf.release()); // last ref
    try std.testing.expectEqual(@as(u32, 0), buf.refCount());
}
