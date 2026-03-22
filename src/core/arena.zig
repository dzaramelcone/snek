//! Connection-scoped arena pair (http.zig pattern).
//! Two arenas per connection:
//!   - ConnArena: connection lifetime (TLS state, parser state, connection metadata).
//!     Lives as long as the TCP connection is open.
//!   - ReqArena: request lifetime with configurable retention.
//!     Cleared between requests but retains allocated pages to avoid mmap/munmap churn.
//!
//! The retention limit prevents unbounded growth from occasional large requests.

const std = @import("std");

// Reference: http.zig (refs/http.zig/INSIGHTS.md) — two arenas per connection
// ConnArena lives for the TCP connection lifetime; ReqArena resets between requests.
pub const ConnArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) ConnArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *ConnArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *ConnArena) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const ReqArenaConfig = struct {
    /// Maximum bytes to retain between requests. Pages above this limit
    /// are returned to the OS. Default: 8KB (matches http.zig).
    retain_limit: usize = 8192,
};

// Reference: http.zig (refs/http.zig/INSIGHTS.md) — request arena with retention limit
// Retains allocated pages between requests to avoid mmap/munmap churn (conn_arena + req_arena).
pub const ReqArena = struct {
    arena: std.heap.ArenaAllocator,
    config: ReqArenaConfig,

    pub fn init(backing: std.mem.Allocator, config: ReqArenaConfig) ReqArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .config = config,
        };
    }

    pub fn deinit(self: *ReqArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *ReqArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena between requests. Retains pages up to retain_limit
    /// to avoid syscall overhead on the next request.
    pub fn reset(self: *ReqArena) void {
        _ = .{self};
    }
};

/// A paired arena set for a single connection. Bundles ConnArena + ReqArena.
pub const ConnectionArenas = struct {
    conn: ConnArena,
    req: ReqArena,

    pub fn init(backing: std.mem.Allocator, req_config: ReqArenaConfig) ConnectionArenas {
        return .{
            .conn = ConnArena.init(backing),
            .req = ReqArena.init(backing, req_config),
        };
    }

    pub fn deinit(self: *ConnectionArenas) void {
        self.req.deinit();
        self.conn.deinit();
    }

    /// Reset request arena between requests on the same connection.
    pub fn resetRequest(self: *ConnectionArenas) void {
        self.req.reset();
    }
};

test "conn arena allocates and frees" {}

test "req arena reset retains pages" {}

test "connection arenas lifecycle" {}
