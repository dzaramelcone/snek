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
        _ = self.arena.reset(.{ .retain_with_limit = self.config.retain_limit });
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

test "conn arena allocates and frees" {
    var ca = ConnArena.init(std.testing.allocator);
    defer ca.deinit();
    const alloc = ca.allocator();
    const buf = alloc.alloc(u8, 256) catch unreachable;
    buf[0] = 42;
    std.testing.expectEqual(@as(u8, 42), buf[0]) catch unreachable;
}

test "req arena reset retains pages" {
    var ra = ReqArena.init(std.testing.allocator, .{ .retain_limit = 8192 });
    defer ra.deinit();
    const alloc = ra.allocator();

    // First allocation
    const buf1 = alloc.alloc(u8, 128) catch unreachable;
    buf1[0] = 0xAA;
    const ptr1 = @intFromPtr(buf1.ptr);

    // Reset — pages retained up to limit
    ra.reset();

    // Second allocation reuses retained pages
    const buf2 = alloc.alloc(u8, 128) catch unreachable;
    const ptr2 = @intFromPtr(buf2.ptr);
    std.testing.expectEqual(ptr1, ptr2) catch unreachable;
}

test "connection arenas lifecycle" {
    var arenas = ConnectionArenas.init(std.testing.allocator, .{});
    defer arenas.deinit();

    // Allocate from both arenas
    const conn_buf = arenas.conn.allocator().alloc(u8, 64) catch unreachable;
    conn_buf[0] = 1;
    const req_buf = arenas.req.allocator().alloc(u8, 64) catch unreachable;
    req_buf[0] = 2;

    // Reset request arena between requests
    arenas.resetRequest();

    // Request arena still usable after reset
    const req_buf2 = arenas.req.allocator().alloc(u8, 64) catch unreachable;
    req_buf2[0] = 3;
    std.testing.expectEqual(@as(u8, 3), req_buf2[0]) catch unreachable;
}
