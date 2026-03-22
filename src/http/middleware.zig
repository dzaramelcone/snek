//! Middleware pipeline: before/after hook model between router and handler.
//!
//! Before hooks inspect/modify the request and can short-circuit (return a
//! response without calling the handler). After hooks inspect/modify the
//! response after the handler runs. This is the "two-pass" model — simpler
//! than onion/call_next wrapping and sufficient for the minimum viable layer.
//!
//! Also includes: TimingMiddleware (self-contained, no external dep),
//! LifecycleHooks, BackgroundTaskRunner.
//!
//! Sources:
//!   - Two-tier architecture: TurboAPI pattern (src/http/REFERENCES_middleware.md)
//!   - BackgroundTaskRunner from Starlette BackgroundTask (docs/GAPS_RESEARCH.md)

const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

// ---------------------------------------------------------------------------
// Hook function types
// ---------------------------------------------------------------------------

/// A handler function: takes a request, returns a response.
pub const HandlerFn = *const fn (*Request) Response;

/// Before-request hook: may inspect/modify request.
/// Return non-null Response to short-circuit (skip handler + remaining hooks).
pub const BeforeHook = *const fn (*Request) ?Response;

/// After-request hook: may inspect/modify the response after the handler ran.
pub const AfterHook = *const fn (*const Request, *Response) void;

// ---------------------------------------------------------------------------
// Timing middleware (self-contained — no external dependency)
// ---------------------------------------------------------------------------

/// Measures request duration in Zig, formats as X-Response-Time header value.
pub const TimingMiddleware = struct {
    start_ns: u64,

    pub fn start() TimingMiddleware {
        return .{ .start_ns = @intCast(std.time.nanoTimestamp()) };
    }

    pub fn elapsedNs(self: *const TimingMiddleware) u64 {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return now - self.start_ns;
    }

    /// Format elapsed time as "N.NNNms" into buf. Returns the written slice.
    pub fn formatHeader(self: *const TimingMiddleware, buf: []u8) []const u8 {
        const elapsed_us = self.elapsedNs() / 1000;
        const ms = elapsed_us / 1000;
        const frac = elapsed_us % 1000;
        const result = std.fmt.bufPrint(buf, "{d}.{d:0>3}ms", .{ ms, frac }) catch return buf[0..0];
        return result;
    }
};

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

/// Middleware pipeline with before/after hooks around a handler.
/// Before hooks run in registration order; after hooks run in registration order.
/// A before hook returning non-null short-circuits the entire chain.
pub const Pipeline = struct {
    before: [16]BeforeHook,
    before_count: usize,
    after: [16]AfterHook,
    after_count: usize,

    pub fn init() Pipeline {
        return .{
            .before = undefined,
            .before_count = 0,
            .after = undefined,
            .after_count = 0,
        };
    }

    /// Register a before-request hook.
    pub fn addBefore(self: *Pipeline, hook: BeforeHook) void {
        if (self.before_count < self.before.len) {
            self.before[self.before_count] = hook;
            self.before_count += 1;
        }
    }

    /// Register an after-request hook.
    pub fn addAfter(self: *Pipeline, hook: AfterHook) void {
        if (self.after_count < self.after.len) {
            self.after[self.after_count] = hook;
            self.after_count += 1;
        }
    }

    /// Execute: run before hooks, call handler, run after hooks.
    /// If any before hook returns a Response, short-circuit immediately.
    pub fn execute(self: *const Pipeline, request: *Request, handler: HandlerFn) Response {
        for (self.before[0..self.before_count]) |hook| {
            if (hook(request)) |response| return response;
        }
        var response = handler(request);
        for (self.after[0..self.after_count]) |hook| {
            hook(request, &response);
        }
        return response;
    }
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// Zig-native lifecycle hook function.
pub const LifecycleFn = *const fn () void;

/// Application lifecycle hooks: on_startup, on_shutdown.
pub const LifecycleHooks = struct {
    startup_hooks: [32]LifecycleFn,
    startup_count: usize,
    shutdown_hooks: [32]LifecycleFn,
    shutdown_count: usize,

    pub fn init() LifecycleHooks {
        return .{
            .startup_hooks = undefined,
            .startup_count = 0,
            .shutdown_hooks = undefined,
            .shutdown_count = 0,
        };
    }

    pub fn onStartup(self: *LifecycleHooks, hook: LifecycleFn) void {
        if (self.startup_count < self.startup_hooks.len) {
            self.startup_hooks[self.startup_count] = hook;
            self.startup_count += 1;
        }
    }

    pub fn onShutdown(self: *LifecycleHooks, hook: LifecycleFn) void {
        if (self.shutdown_count < self.shutdown_hooks.len) {
            self.shutdown_hooks[self.shutdown_count] = hook;
            self.shutdown_count += 1;
        }
    }

    pub fn runStartup(self: *const LifecycleHooks) void {
        for (self.startup_hooks[0..self.startup_count]) |hook| hook();
    }

    pub fn runShutdown(self: *const LifecycleHooks) void {
        for (self.shutdown_hooks[0..self.shutdown_count]) |hook| hook();
    }
};

// ---------------------------------------------------------------------------
// Background tasks
// ---------------------------------------------------------------------------

/// Zig-native background task function.
pub const TaskFn = *const fn () void;

/// Fire-and-forget task queue. Tasks enqueued during request handling,
/// drained after response is sent or on graceful shutdown.
/// Source: Starlette BackgroundTask pattern (docs/GAPS_RESEARCH.md).
pub const BackgroundTaskRunner = struct {
    tasks: [256]TaskFn,
    task_count: usize,

    pub fn init() BackgroundTaskRunner {
        return .{
            .tasks = undefined,
            .task_count = 0,
        };
    }

    pub fn enqueue(self: *BackgroundTaskRunner, task: TaskFn) void {
        if (self.task_count < self.tasks.len) {
            self.tasks[self.task_count] = task;
            self.task_count += 1;
        }
    }

    /// Drain all pending tasks (run each, then clear queue).
    pub fn drain(self: *BackgroundTaskRunner) void {
        for (self.tasks[0..self.task_count]) |task| task();
        self.task_count = 0;
    }

    pub fn hasPending(self: *const BackgroundTaskRunner) bool {
        return self.task_count > 0;
    }
};

// ============================================================
// Tests
// ============================================================

// -- Shared test helpers (file-scoped mutable state for test hooks) ---------

var test_counter: u32 = 0;

fn resetTestState() void {
    test_counter = 0;
}

fn makeRequest() Request {
    return Request.fromRaw(.GET, "/test", .http11, &.{}, null);
}

fn echoHandler(req: *Request) Response {
    _ = req;
    return Response.text("ok");
}

// -- 1. Empty pipeline calls handler directly ------------------------------

test "empty pipeline calls handler directly" {
    var p = Pipeline.init();
    var req = makeRequest();
    const resp = p.execute(&req, echoHandler);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body.?);
}

// -- 2. Before hook runs before handler ------------------------------------

fn beforeIncrement(_: *Request) ?Response {
    test_counter += 1;
    return null; // continue chain
}

fn handlerChecksCounter(_: *Request) Response {
    // Counter should already be 1 (before hook ran first).
    return if (test_counter == 1) Response.text("good") else Response.init(500);
}

test "before hook runs before handler" {
    resetTestState();
    var p = Pipeline.init();
    p.addBefore(beforeIncrement);
    var req = makeRequest();
    const resp = p.execute(&req, handlerChecksCounter);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("good", resp.body.?);
}

// -- 3. After hook runs after handler (modifies response header) -----------

fn afterAddHeader(_: *const Request, resp: *Response) void {
    _ = resp.setHeader("X-After", "applied");
}

test "after hook modifies response" {
    var p = Pipeline.init();
    p.addAfter(afterAddHeader);
    var req = makeRequest();
    const resp = p.execute(&req, echoHandler);
    // The after hook should have added X-After header.
    try std.testing.expectEqual(@as(usize, 2), resp.header_count);
    // First header is Content-Type from text(), second is X-After.
    try std.testing.expectEqualStrings("X-After", resp.headers[1].name);
    try std.testing.expectEqualStrings("applied", resp.headers[1].value);
}

// -- 4. Before hook short-circuits -----------------------------------------

fn authHookDeny(_: *Request) ?Response {
    return Response.init(401);
}

fn unreachableHandler(_: *Request) Response {
    // Should never be called.
    return Response.init(500);
}

test "before hook short-circuits" {
    var p = Pipeline.init();
    p.addBefore(authHookDeny);
    var req = makeRequest();
    const resp = p.execute(&req, unreachableHandler);
    try std.testing.expectEqual(@as(u16, 401), resp.status);
}

// -- 5. Multiple hooks execute in order ------------------------------------

fn beforeFirst(_: *Request) ?Response {
    test_counter += 1; // 0 -> 1
    return null;
}

fn beforeSecond(_: *Request) ?Response {
    test_counter += 10; // 1 -> 11
    return null;
}

fn afterFirst(_: *const Request, _: *Response) void {
    test_counter += 100; // 11 -> 111
}

fn afterSecond(_: *const Request, _: *Response) void {
    test_counter += 1000; // 111 -> 1111
}

test "multiple hooks execute in order" {
    resetTestState();
    var p = Pipeline.init();
    p.addBefore(beforeFirst);
    p.addBefore(beforeSecond);
    p.addAfter(afterFirst);
    p.addAfter(afterSecond);
    var req = makeRequest();
    _ = p.execute(&req, echoHandler);
    try std.testing.expectEqual(@as(u32, 1111), test_counter);
}

// -- 6. Timing middleware formats header -----------------------------------

test "timing middleware formats header" {
    const tm = TimingMiddleware{ .start_ns = 0 };
    // We can't control nanoTimestamp in test, but we can test formatHeader
    // with a known elapsed by constructing carefully.
    // Instead: just verify the format function doesn't crash and returns "ms".
    _ = tm; // TimingMiddleware tested via formatHeader with real time below.

    // Test format with a synthetic start that guarantees >0 elapsed.
    const tm2 = TimingMiddleware.start();
    var buf: [32]u8 = undefined;
    const hdr = tm2.formatHeader(&buf);
    // Must end with "ms".
    try std.testing.expect(hdr.len >= 5); // at minimum "0.000ms"
    try std.testing.expect(std.mem.endsWith(u8, hdr, "ms"));
}

// -- 7. Lifecycle hooks ----------------------------------------------------

var lifecycle_trace: u32 = 0;

fn startupHook() void {
    lifecycle_trace += 1;
}

fn shutdownHook() void {
    lifecycle_trace += 10;
}

test "lifecycle startup and shutdown" {
    lifecycle_trace = 0;
    var lc = LifecycleHooks.init();
    lc.onStartup(startupHook);
    lc.onShutdown(shutdownHook);
    lc.runStartup();
    try std.testing.expectEqual(@as(u32, 1), lifecycle_trace);
    lc.runShutdown();
    try std.testing.expectEqual(@as(u32, 11), lifecycle_trace);
}

// -- 8. Background task runner ---------------------------------------------

var bg_trace: u32 = 0;

fn bgTaskA() void {
    bg_trace += 1;
}

fn bgTaskB() void {
    bg_trace += 10;
}

test "background task drain" {
    bg_trace = 0;
    var runner = BackgroundTaskRunner.init();
    try std.testing.expect(!runner.hasPending());
    runner.enqueue(bgTaskA);
    runner.enqueue(bgTaskB);
    try std.testing.expect(runner.hasPending());
    runner.drain();
    try std.testing.expectEqual(@as(u32, 11), bg_trace);
    try std.testing.expect(!runner.hasPending());
}

// -- 9. Short-circuit stops remaining before hooks -------------------------

fn shortCircuitEarly(_: *Request) ?Response {
    test_counter += 1;
    return Response.init(403);
}

fn neverReachedHook(_: *Request) ?Response {
    test_counter += 1000; // should NOT run
    return null;
}

test "short-circuit stops remaining before hooks" {
    resetTestState();
    var p = Pipeline.init();
    p.addBefore(shortCircuitEarly);
    p.addBefore(neverReachedHook);
    var req = makeRequest();
    const resp = p.execute(&req, unreachableHandler);
    try std.testing.expectEqual(@as(u16, 403), resp.status);
    try std.testing.expectEqual(@as(u32, 1), test_counter);
}
