//! macOS/BSD kqueue fallback for async I/O.
//! No zero-copy, no SQPOLL — dev fallback, not the production target.

pub const Kqueue = struct {
    fd: i32,
    max_events: u32,

    pub fn init(max_events: u32) !Kqueue {
        _ = .{max_events};
        return undefined;
    }

    pub fn deinit(self: *Kqueue) void {
        _ = .{self};
    }

    pub fn addRead(self: *Kqueue, fd: i32, user_data: u64) !void {
        _ = .{ self, fd, user_data };
    }

    pub fn addWrite(self: *Kqueue, fd: i32, user_data: u64) !void {
        _ = .{ self, fd, user_data };
    }

    pub fn addTimer(self: *Kqueue, interval_ms: u64, user_data: u64) !void {
        _ = .{ self, interval_ms, user_data };
    }

    pub fn poll(self: *Kqueue, timeout_ms: i32) ![]KqueueEvent {
        _ = .{ self, timeout_ms };
        return undefined;
    }
};

pub const KqueueEvent = struct {
    fd: i32,
    filter: i16,
    flags: u16,
    user_data: u64,
};

test "init kqueue" {}

test "add and poll events" {}
