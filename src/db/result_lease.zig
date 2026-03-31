const std = @import("std");

pub const CAPACITY: usize = 64 * 1024;
pub const DEFAULT_CACHE_LIMIT: usize = 64;
pub const DEFAULT_MAX_LIVE_SLABS: usize = 1024;

const PoolState = struct {
    allocator: std.mem.Allocator,
    cache_limit: usize = DEFAULT_CACHE_LIMIT,
    max_live_slabs: usize = DEFAULT_MAX_LIVE_SLABS,
    live_slabs: usize = 0,
    free_head: ?*Slab = null,
    free_count: usize = 0,
    refs: usize = 1,
    closing: bool = false,

    fn retain(self: *PoolState) void {
        self.refs += 1;
    }

    fn release(self: *PoolState) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) {
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    }

    fn destroySlab(self: *PoolState, slab: *Slab) void {
        std.debug.assert(self.live_slabs > 0);
        self.live_slabs -= 1;
        slab.state = null;
        const allocator = self.allocator;
        self.release();
        allocator.destroy(slab);
    }

    fn destroyFreeList(self: *PoolState) void {
        var cursor = self.free_head;
        self.free_head = null;
        self.free_count = 0;
        while (cursor) |slab| {
            cursor = slab.next_free;
            self.destroySlab(slab);
        }
    }

    fn recycle(self: *PoolState, slab: *Slab) void {
        if (self.closing or self.free_count >= self.cache_limit) {
            self.destroySlab(slab);
            return;
        }

        slab.next_free = self.free_head;
        self.free_head = slab;
        self.free_count += 1;
    }
};

/// Worker-owned pool of fixed-size slabs.
///
/// The same slab type backs transport receive buffers and exported result
/// leases, but those are expected to come from distinct pool instances.
/// When the last reference is released, the slab returns to its pool's free
/// list. Pool state stays alive until all outstanding slabs are gone.
pub const SlabPool = struct {
    state: ?*PoolState = null,

    pub fn init(allocator: std.mem.Allocator, cache_limit: usize, max_live_slabs: usize) !SlabPool {
        const state = try allocator.create(PoolState);
        state.* = .{
            .allocator = allocator,
            .cache_limit = cache_limit,
            .max_live_slabs = max_live_slabs,
        };
        return .{ .state = state };
    }

    pub fn deinit(self: *SlabPool) void {
        const state = self.state orelse return;
        self.state = null;
        state.closing = true;
        state.destroyFreeList();
        state.release();
    }

    pub fn acquire(self: *SlabPool) !*Slab {
        const state = self.state orelse return error.SlabPoolClosed;
        if (state.closing) return error.SlabPoolClosed;

        if (state.free_head) |slab| {
            state.free_head = slab.next_free;
            state.free_count -= 1;
            slab.reset(state);
            return slab;
        }

        if (state.live_slabs >= state.max_live_slabs) return error.SlabPoolExhausted;

        const slab = try state.allocator.create(Slab);
        slab.* = .{};
        state.live_slabs += 1;
        state.retain();
        slab.reset(state);
        return slab;
    }

    pub fn liveSlabs(self: *const SlabPool) usize {
        return if (self.state) |state| state.live_slabs else 0;
    }

    pub fn freeCount(self: *const SlabPool) usize {
        return if (self.state) |state| state.free_count else 0;
    }

    pub fn maxLiveSlabs(self: *const SlabPool) usize {
        return if (self.state) |state| state.max_live_slabs else 0;
    }
};

/// Fixed-size refcounted slab for transport/result bytes.
///
/// Slabs are acquired from a worker pool. Users retain leases via `retain()`,
/// and the last `release()` returns the slab to the pool.
pub const Slab = struct {
    state: ?*PoolState = null,
    allocator: std.mem.Allocator = undefined,
    refs: usize = 1,
    next_free: ?*Slab = null,
    data: [CAPACITY]u8 = undefined,

    fn reset(self: *Slab, state: *PoolState) void {
        self.state = state;
        self.allocator = state.allocator;
        self.refs = 1;
        self.next_free = null;
    }

    pub fn retain(self: *Slab) *Slab {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *Slab) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs > 0) return;

        if (self.state) |state| {
            state.recycle(self);
        } else {
            self.allocator.destroy(self);
        }
    }

    pub fn bytes(self: *Slab) []u8 {
        return self.data[0..];
    }

    pub fn constBytes(self: *const Slab) []const u8 {
        return self.data[0..];
    }
};

/// First-class lease over result bytes.
///
/// A lease may retain a transport slab for zero-copy export, or it may own a
/// dedicated slab from a result pool. Either way, the row/model layer holds a
/// lease rather than a raw recv buffer pointer.
pub const ResultLease = struct {
    slab: ?*Slab = null,

    pub fn isEmpty(self: *const ResultLease) bool {
        return self.slab == null;
    }

    pub fn initBorrowed(slab: *Slab) ResultLease {
        return .{ .slab = slab.retain() };
    }

    pub fn initOwned(pool: *SlabPool) !ResultLease {
        return .{ .slab = try pool.acquire() };
    }

    pub fn retain(self: *const ResultLease) ResultLease {
        return if (self.slab) |slab|
            .{ .slab = slab.retain() }
        else
            .{};
    }

    pub fn release(self: *ResultLease) void {
        if (self.slab) |slab| {
            self.slab = null;
            slab.release();
        }
    }

    pub fn bytes(self: *ResultLease) []u8 {
        return self.slab.?.bytes();
    }

    pub fn constBytes(self: *const ResultLease) []const u8 {
        return if (self.slab) |slab| slab.constBytes() else &.{};
    }
};

test "pool enforces live slab ceiling and reuses released slabs" {
    var pool = try SlabPool.init(std.testing.allocator, 1, 1);
    defer pool.deinit();

    const slab = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.liveSlabs());
    try std.testing.expectError(error.SlabPoolExhausted, pool.acquire());

    slab.release();
    try std.testing.expectEqual(@as(usize, 1), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.liveSlabs());

    const reused = try pool.acquire();
    try std.testing.expectEqual(slab, reused);
    reused.release();
}

test "pool destroys released slabs beyond cache limit" {
    var pool = try SlabPool.init(std.testing.allocator, 0, 1);
    defer pool.deinit();

    const slab = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.liveSlabs());
    slab.release();

    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.liveSlabs());
}

test "result lease keeps slab alive until final release" {
    var pool = try SlabPool.init(std.testing.allocator, 1, 1);
    defer pool.deinit();

    var lease = try ResultLease.initOwned(&pool);
    var shared = lease.retain();

    lease.release();
    try std.testing.expectEqual(@as(usize, 0), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.liveSlabs());

    shared.release();
    try std.testing.expectEqual(@as(usize, 1), pool.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.liveSlabs());
}

test "live lease can outlive pool handle and release safely after deinit" {
    var pool = try SlabPool.init(std.testing.allocator, 1, 1);
    var lease = try ResultLease.initOwned(&pool);

    pool.deinit();
    lease.release();
}
