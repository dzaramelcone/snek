//! StaticAllocator — TigerBeetle pattern for hot-path I/O buffers only.
//! Three states: init (allocations allowed), static (crashes on alloc),
//! deinit (only frees allowed).
//!
//! Wraps the allocator used for hot-path I/O buffers only. Does NOT cover
//! per-request arenas or infrequent runtime allocations like JWKS refresh.
//!
//! During `init` phase, all allocations go through the child. After calling
//! `transition(.static)`, any allocation attempt is a hard crash — this
//! enforces that hot-path memory is pre-allocated at startup.
//! During `deinit` phase, only frees are allowed for cleanup.
//!
//! Scope: connection pool, coroutine frames, request/response buffers,
//! io_uring SQE/CQE rings. Per-request arenas and general-purpose
//! allocations (config reload, JWKS, OpenAPI) use separate allocators.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Alignment = mem.Alignment;

pub const Phase = enum {
    /// Startup phase: allocations allowed.
    init,
    /// Runtime phase: allocations crash immediately.
    static,
    /// Shutdown phase: only frees allowed.
    deinit,
};

// Inspired by: TigerBeetle (refs/tigerbeetle/INSIGHTS.md) — StaticAllocator pattern
// Source: TigerBeetle src/static_allocator.zig — three-phase allocator that enforces
// all memory is pre-allocated at startup, guaranteeing no OOM after init.
pub const StaticAllocator = struct {
    child: mem.Allocator,
    phase: Phase,

    pub fn init(child: mem.Allocator) StaticAllocator {
        return .{ .child = child, .phase = .init };
    }

    /// Transition to the next phase. Phases must advance forward only.
    pub fn transition(self: *StaticAllocator, new_phase: Phase) void {
        const current = @intFromEnum(self.phase);
        const next = @intFromEnum(new_phase);
        assert(next > current);
        self.phase = new_phase;
    }

    /// Return an allocator interface backed by this StaticAllocator.
    pub fn allocator(self: *StaticAllocator) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Returns the current phase.
    pub fn getPhase(self: *const StaticAllocator) Phase {
        return self.phase;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.phase == .init);
        return self.child.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.phase == .init);
        return self.child.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.phase == .init);
        return self.child.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.phase != .static);
        self.child.rawFree(buf, buf_align, ret_addr);
    }
};

test "static allocator init phase" {
    var sa = StaticAllocator.init(std.testing.allocator);
    const a = sa.allocator();
    const buf = try a.alloc(u8, 64);
    a.free(buf);
}

test "static allocator transition to static" {
    var sa = StaticAllocator.init(std.testing.allocator);
    try std.testing.expectEqual(Phase.init, sa.getPhase());
    sa.transition(.static);
    try std.testing.expectEqual(Phase.static, sa.getPhase());
}

test "static allocator alloc-free-alloc during init" {
    var sa = StaticAllocator.init(std.testing.allocator);
    const a = sa.allocator();
    const buf1 = try a.alloc(u8, 64);
    a.free(buf1);
    // Must be able to allocate again — still in init phase
    const buf2 = try a.alloc(u8, 64);
    a.free(buf2);
    try std.testing.expectEqual(Phase.init, sa.getPhase());
}

test "static allocator transition to deinit" {
    var sa = StaticAllocator.init(std.testing.allocator);
    const a = sa.allocator();
    const buf = try a.alloc(u8, 64);
    sa.transition(.static);
    sa.transition(.deinit);
    try std.testing.expectEqual(Phase.deinit, sa.getPhase());
    a.free(buf);
}
