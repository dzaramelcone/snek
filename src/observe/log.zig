//! Structured JSON logging with per-subsystem log levels.
//!
//! Output: stderr by default, configurable.
//! Format: JSON or text (configurable).
//! Access log: method, path, status, duration_ms, request_id, remote_addr.

const std = @import("std");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    /// Parse level from string (e.g. from snek.toml).
    pub fn fromString(s: []const u8) ?LogLevel {
        _ = .{s};
        return undefined;
    }

    /// Whether this level is enabled given a minimum threshold.
    pub fn isEnabled(self: LogLevel, min: LogLevel) bool {
        _ = .{ self, min };
        return undefined;
    }
};

pub const Format = enum {
    json,
    text,
};

/// A single structured log entry.
pub const LogEntry = struct {
    timestamp: i64,
    level: LogLevel,
    subsystem: []const u8,
    message: []const u8,
    /// Arbitrary key-value fields for structured context.
    fields: [16][2][]const u8,
    field_count: usize,

    /// Serialize this entry to JSON.
    pub fn toJson(self: *const LogEntry, buf: []u8) !usize {
        _ = .{ self, buf };
        return undefined;
    }

    /// Serialize this entry to human-readable text.
    pub fn toText(self: *const LogEntry, buf: []u8) !usize {
        _ = .{ self, buf };
        return undefined;
    }
};

/// Access log entry for HTTP requests.
pub const AccessLogEntry = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
    duration_ms: u64,
    request_id: []const u8,
    remote_addr: []const u8,
    bytes_sent: u64,

    /// Serialize as a structured log entry.
    pub fn toLogEntry(self: *const AccessLogEntry) LogEntry {
        _ = .{self};
        return undefined;
    }
};

/// Logger with per-subsystem log levels and configurable output.
pub const Logger = struct {
    /// Global minimum log level.
    level: LogLevel,
    /// Output format (json or text).
    format: Format,
    /// Output writer (stderr by default).
    output: ?*anyopaque,
    /// Subsystem name for scoped logging.
    subsystem: []const u8,

    /// Create a logger from snek.toml [logging] config.
    pub fn fromConfig(subsystem: []const u8, level: LogLevel, format: Format) Logger {
        _ = .{ subsystem, level, format };
        return undefined;
    }

    /// Create a scoped child logger with a different subsystem name.
    pub fn scoped(self: *const Logger, subsystem: []const u8) Logger {
        _ = .{ self, subsystem };
        return undefined;
    }

    pub fn debug(self: *const Logger, msg: []const u8, fields: anytype) void {
        _ = .{ self, msg, fields };
    }

    pub fn info(self: *const Logger, msg: []const u8, fields: anytype) void {
        _ = .{ self, msg, fields };
    }

    pub fn warn(self: *const Logger, msg: []const u8, fields: anytype) void {
        _ = .{ self, msg, fields };
    }

    pub fn err(self: *const Logger, msg: []const u8, fields: anytype) void {
        _ = .{ self, msg, fields };
    }

    /// Write an access log entry for an HTTP request.
    pub fn accessLog(self: *const Logger, entry: AccessLogEntry) void {
        _ = .{ self, entry };
    }
};

test "log entry serialization" {}

test "log entry to json" {}

test "log entry to text" {}

test "access log format" {}

test "level filtering" {}

test "level from string" {}

test "scoped logger" {}

test "logger from config" {}
