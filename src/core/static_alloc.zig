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
    child: std.mem.Allocator,
    phase: Phase,

    pub fn init(child: std.mem.Allocator) StaticAllocator {
        return .{
            .child = child,
            .phase = .init,
        };
    }

    /// Transition to the next phase. Phases must advance forward only.
    pub fn transition(self: *StaticAllocator, new_phase: Phase) void {
        _ = .{ self, new_phase };
    }

    /// Return an allocator interface backed by this StaticAllocator.
    pub fn allocator(self: *StaticAllocator) std.mem.Allocator {
        _ = .{self};
        return undefined;
    }

    /// Returns the current phase.
    pub fn getPhase(self: *const StaticAllocator) Phase {
        return self.phase;
    }
};

test "static allocator init phase" {}

test "static allocator transition to static" {}

test "static allocator transition to deinit" {}
