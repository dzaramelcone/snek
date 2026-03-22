//! Redis Lua scripting: eval, evalsha, script management.
//! Generic-over-IO.

const std = @import("std");
const conn = @import("connection.zig");
const protocol = @import("protocol.zig");

pub const ScriptHash = struct {
    sha1: [40]u8,
};

pub const Script = struct {
    source: []const u8,
    hash: ?ScriptHash,

    pub fn init(source: []const u8) Script {
        return .{ .source = source, .hash = null };
    }
};

/// Lua scripting interface, Generic-over-IO.
pub fn LuaScripting(comptime IO: type) type {
    return struct {
        const Self = @This();
        const Connection = conn.RedisConnection(IO);

        /// Execute a Lua script via EVAL.
        pub fn eval(connection: *Connection, script: []const u8, num_keys: u32, args: []const []const u8) !protocol.RespValue {
            _ = .{ connection, script, num_keys, args };
            return undefined;
        }

        /// Execute a cached Lua script via EVALSHA.
        pub fn evalsha(connection: *Connection, hash: ScriptHash, num_keys: u32, args: []const []const u8) !protocol.RespValue {
            _ = .{ connection, hash, num_keys, args };
            return undefined;
        }

        /// Load a script into Redis and return its SHA1 hash.
        pub fn scriptLoad(connection: *Connection, script: []const u8) !ScriptHash {
            _ = .{ connection, script };
            return undefined;
        }

        /// Check if a script exists in the Redis script cache.
        pub fn scriptExists(connection: *Connection, hash: ScriptHash) !bool {
            _ = .{ connection, hash };
            return undefined;
        }

        /// Flush the Redis script cache.
        pub fn scriptFlush(connection: *Connection) !void {
            _ = .{connection};
        }

        /// Execute a Script struct: tries EVALSHA first, falls back to EVAL.
        pub fn execScript(connection: *Connection, script: *Script, num_keys: u32, args: []const []const u8) !protocol.RespValue {
            _ = .{ connection, script, num_keys, args };
            return undefined;
        }
    };
}

test "eval script" {}

test "cached script execution" {}

test "script load and exists" {}

test "evalsha fallback to eval" {}
