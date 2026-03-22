//! Coroutine driving protocol: the heart of snek's Python integration.
//!
//! Drives Python coroutines via `coro.send()`, intercepts sentinel objects
//! at the send boundary, dispatches I/O operations to the Zig runtime,
//! and resumes coroutines with results.
//!
//! Generic over IO backend for deterministic simulation testing.
//!
//! Sources:
//!   - Sentinel/trap-based coroutine driving from curio
//!     (src/python/REFERENCES_eventloop.md — curio is the intellectual ancestor)

const ffi = @import("ffi.zig");
const gil = @import("gil.zig");

// ── Sentinel types (tagged union) ───────────────────────────────────
//
// Each sentinel represents an I/O operation that Python code requested
// via `await`. The driver intercepts these at the `send()` boundary
// and dispatches them to the Zig runtime.
// Source: curio kernel trap design — sentinels are the Zig equivalent of curio's
// trap objects (src/python/REFERENCES_eventloop.md).

pub const DbOperation = enum {
    fetch,
    fetch_one,
    execute,
};

pub const HttpMethod = enum {
    get,
    post,
    put,
    patch,
    delete,
    head,
    options,
};

pub const Sentinel = union(enum) {
    db_query: DbQuery,
    redis_op: RedisOp,
    http_op: HttpOp,
    sleep: Sleep,
    gather: Gather,
    ws_send: WsSend,
    ws_recv: WsRecv,
    spawn: Spawn,
};

pub const DbQuery = struct {
    query_text: []const u8,
    params: ?*ffi.PyObject,
    operation: DbOperation,
};

pub const RedisOp = struct {
    command: []const u8,
    args: ?*ffi.PyObject,
};

pub const HttpOp = struct {
    method: HttpMethod,
    url: []const u8,
    headers: ?*ffi.PyDict,
    body: ?[]const u8,
};

pub const Sleep = struct {
    duration_ns: u64,
};

pub const Gather = struct {
    ops: []const Sentinel,
};

pub const WsSend = struct {
    frame_data: []const u8,
};

pub const WsRecv = struct {
    // Waits for the next WebSocket frame from the client.
};

pub const Spawn = struct {
    func: *ffi.PyObject,
    args: ?*ffi.PyTuple,
};

// ── CoroutineDriver ─────────────────────────────────────────────────

pub fn CoroutineDriver(comptime IO: type) type {
    return struct {
        const Self = @This();

        coro: ?*ffi.PyObject,
        state: State,
        io: *IO,

        pub const State = enum {
            idle,
            driving,
            suspended,
            completed,
            errored,
        };

        pub fn init(coro: *ffi.PyObject, io: *IO) Self {
            return .{
                .coro = coro,
                .state = .idle,
                .io = io,
            };
        }

        /// Drive the coroutine to completion. Sends values, intercepts
        /// sentinels, dispatches I/O, and resumes until StopIteration.
        pub fn drive(self: *Self) !void {
            _ = self;
        }

        /// Send a value to the coroutine. Returns the yielded sentinel
        /// or null on StopIteration (completion).
        pub fn sendValue(self: *Self, value: ?*ffi.PyObject) !?Sentinel {
            _ = .{ self, value };
            return null;
        }

        /// Classify a yielded PyObject as a Sentinel variant.
        pub fn classifySentinel(self: *Self, obj: *ffi.PyObject) !Sentinel {
            _ = .{ self, obj };
            return undefined;
        }

        /// Resume the coroutine with the result of a completed I/O op.
        pub fn handleCompletion(self: *Self, result: *ffi.PyObject) !void {
            _ = .{ self, result };
        }

        /// Handle a Python exception: extract structured error info,
        /// propagate back as a Zig error or HTTP response.
        pub fn handlePythonException(self: *Self) !PythonError {
            _ = self;
            return undefined;
        }

        pub fn deinit(self: *Self) void {
            if (self.coro) |c| {
                ffi.pyDecref(c);
                self.coro = null;
            }
        }

        // Stub functions return Zig's builtin `undefined` as placeholder values.
    };
}

// ── Structured Python error ─────────────────────────────────────────

pub const PythonError = struct {
    exc_type_name: []const u8,
    message: []const u8,
    traceback: ?[]const u8,
    http_status: ?u16,
};

// ── Tests ───────────────────────────────────────────────────────────

// Stub functions return Zig's builtin `undefined` as placeholder values.

test "drive simple handler" {}

test "intercept DbQuery sentinel" {}

test "intercept RedisOp sentinel" {}

test "intercept HttpOp sentinel" {}

test "intercept Sleep sentinel" {}

test "gather parallel dispatch" {}

test "ws send and recv sentinels" {}

test "spawn background task sentinel" {}

test "handle Python exception" {}

test "coroutine completion via StopIteration" {}
