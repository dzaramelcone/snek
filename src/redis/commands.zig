//! Typed command builders for Redis operations.
//! Pure functions that produce RESP3 command arrays — no IO, no connection.

const std = @import("std");

// ---- String commands ----

pub fn get(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn set(key: []const u8, value: []const u8) [3][]const u8 {
    _ = .{ key, value };
    return undefined;
}

pub fn setex(key: []const u8, seconds: u32, value: []const u8) [4][]const u8 {
    _ = .{ key, seconds, value };
    return undefined;
}

pub fn psetex(key: []const u8, milliseconds: u64, value: []const u8) [4][]const u8 {
    _ = .{ key, milliseconds, value };
    return undefined;
}

pub fn mget(key_list: []const []const u8) []const []const u8 {
    _ = .{key_list};
    return undefined;
}

pub fn mset(pairs: []const [2][]const u8) []const []const u8 {
    _ = .{pairs};
    return undefined;
}

pub fn incr(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn decr(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn incrby(key: []const u8, amount: i64) [3][]const u8 {
    _ = .{ key, amount };
    return undefined;
}

// ---- Hash commands ----

pub fn hget(key: []const u8, field: []const u8) [3][]const u8 {
    _ = .{ key, field };
    return undefined;
}

pub fn hset(key: []const u8, field: []const u8, value: []const u8) [4][]const u8 {
    _ = .{ key, field, value };
    return undefined;
}

pub fn hgetall(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn hdel(key: []const u8, field: []const u8) [3][]const u8 {
    _ = .{ key, field };
    return undefined;
}

pub fn hexists(key: []const u8, field: []const u8) [3][]const u8 {
    _ = .{ key, field };
    return undefined;
}

// ---- List commands ----

pub fn lpush(key: []const u8, value: []const u8) [3][]const u8 {
    _ = .{ key, value };
    return undefined;
}

pub fn rpush(key: []const u8, value: []const u8) [3][]const u8 {
    _ = .{ key, value };
    return undefined;
}

pub fn lpop(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn rpop(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn lrange(key: []const u8, start: i64, stop: i64) [4][]const u8 {
    _ = .{ key, start, stop };
    return undefined;
}

pub fn llen(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

// ---- Set commands ----

pub fn sadd(key: []const u8, member: []const u8) [3][]const u8 {
    _ = .{ key, member };
    return undefined;
}

pub fn srem(key: []const u8, member: []const u8) [3][]const u8 {
    _ = .{ key, member };
    return undefined;
}

pub fn smembers(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn sismember(key: []const u8, member: []const u8) [3][]const u8 {
    _ = .{ key, member };
    return undefined;
}

pub fn sunion(key_list: []const []const u8) []const []const u8 {
    _ = .{key_list};
    return undefined;
}

pub fn sinter(key_list: []const []const u8) []const []const u8 {
    _ = .{key_list};
    return undefined;
}

// ---- Sorted set commands ----

pub fn zadd(key: []const u8, score: f64, member: []const u8) [4][]const u8 {
    _ = .{ key, score, member };
    return undefined;
}

pub fn zrem(key: []const u8, member: []const u8) [3][]const u8 {
    _ = .{ key, member };
    return undefined;
}

pub fn zrange(key: []const u8, start: i64, stop: i64) [4][]const u8 {
    _ = .{ key, start, stop };
    return undefined;
}

pub fn zrangebyscore(key: []const u8, min: f64, max: f64) [4][]const u8 {
    _ = .{ key, min, max };
    return undefined;
}

pub fn zscore(key: []const u8, member: []const u8) [3][]const u8 {
    _ = .{ key, member };
    return undefined;
}

// ---- Key commands ----

pub fn del(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn exists(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn expire(key: []const u8, seconds: u32) [3][]const u8 {
    _ = .{ key, seconds };
    return undefined;
}

pub fn ttl(key: []const u8) [2][]const u8 {
    _ = .{key};
    return undefined;
}

pub fn keys(pattern: []const u8) [2][]const u8 {
    _ = .{pattern};
    return undefined;
}

/// SCAN with cursor iteration. Returns (new_cursor, keys).
pub fn scan(cursor: u64, pattern: []const u8, count: u32) [6][]const u8 {
    _ = .{ cursor, pattern, count };
    return undefined;
}

/// Cursor iterator for SCAN. Tracks cursor state across calls.
pub const ScanIterator = struct {
    cursor: u64,
    pattern: []const u8,
    count: u32,
    done: bool,

    pub fn init(pattern: []const u8, count: u32) ScanIterator {
        return .{ .cursor = 0, .pattern = pattern, .count = count, .done = false };
    }

    /// Build the next SCAN command. Returns null when iteration is complete.
    pub fn nextCommand(self: *ScanIterator) ?[6][]const u8 {
        _ = .{self};
        return undefined;
    }

    /// Update cursor from SCAN response.
    pub fn updateCursor(self: *ScanIterator, new_cursor: u64) void {
        _ = .{ self, new_cursor };
    }
};

test "build GET command" {}

test "build SET with expiry" {}

test "build HGETALL" {}

test "build PSETEX" {}

test "scan cursor iteration" {}
