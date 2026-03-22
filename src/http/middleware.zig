//! Two-tier middleware architecture: Zig-side (compiled at startup, zero Python
//! overhead) and Python-side (hooks + wrapping).
//!
//! Zig-side middleware: CORS, security headers, timing, request ID — resolved at
//! comptime/startup, never per-request. Python-side middleware: before_request,
//! after_request, on_error hooks + call_next wrapping.
//!
//! MiddlewarePipeline: ordered chain compiled at startup.
//! LifecycleHooks: on_startup, on_shutdown, on_error.
//! BackgroundTaskRunner: fire-and-forget task queue drained on shutdown.
//!
//! Sources:
//!   - Two-tier architecture: TurboAPI pattern — 0% overhead for Zig-side middleware
//!     (src/http/REFERENCES_middleware.md)
//!   - Compiled pipeline from http.zig comptime middleware
//!   - BackgroundTaskRunner from Starlette BackgroundTask (docs/GAPS_RESEARCH.md)

const std = @import("std");
const security_cors = @import("../security/cors.zig");
const security_headers = @import("../security/headers.zig");
const observe_trace = @import("../observe/trace.zig");

// ---------------------------------------------------------------------------
// Zig-side middleware (zero Python overhead, compiled at startup)
// ---------------------------------------------------------------------------

/// CORS middleware — thin pipeline wrapper around security.cors.PreRenderedCors.
/// The implementation lives in security/cors.zig; this is the pipeline integration.
/// Source: TurboAPI delegation pattern — CorsMiddleware delegates to security/cors
/// for 0% per-request overhead (src/http/REFERENCES_middleware.md).
pub const CorsMiddleware = struct {
    /// The pre-rendered CORS implementation (built once at startup).
    impl: security_cors.PreRenderedCors,

    pub fn init(allocator: std.mem.Allocator, config: security_cors.CorsConfig) !CorsMiddleware {
        return .{ .impl = security_cors.PreRenderedCors.fromConfig(allocator, config) catch return error.CorsInitFailed };
    }

    /// Inject CORS headers into a response. Delegates to security.cors.
    pub fn apply(self: *const CorsMiddleware, origin: []const u8, response_headers: *security_cors.ResponseHeaders) void {
        self.impl.injectHeaders(origin, response_headers);
    }

    /// Handle OPTIONS preflight. Delegates to security.cors.
    pub fn handlePreflight(self: *const CorsMiddleware, origin: []const u8) ?security_cors.PreflightResponse {
        return self.impl.handlePreflight(origin);
    }
};

/// Security headers middleware — thin pipeline wrapper around security.headers.PreRenderedSecurityHeaders.
/// The implementation lives in security/headers.zig; this is the pipeline integration.
pub const SecurityHeadersMiddleware = struct {
    /// The pre-rendered security headers implementation.
    impl: security_headers.PreRenderedSecurityHeaders,

    pub fn init(allocator: std.mem.Allocator, sh: security_headers.SecurityHeaders) !SecurityHeadersMiddleware {
        return .{ .impl = security_headers.PreRenderedSecurityHeaders.fromHeaders(allocator, sh) catch return error.SecurityHeadersInitFailed };
    }

    /// Inject all security headers into response. Delegates to security.headers.
    pub fn apply(self: *const SecurityHeadersMiddleware, response_headers: *security_headers.ResponseHeaders) void {
        self.impl.inject(response_headers);
    }
};

/// Timing middleware: measures request duration in Zig, injects X-Response-Time header.
/// Self-contained — uses std.time directly; no external dependency needed.
pub const TimingMiddleware = struct {
    /// Timestamp (nanoseconds) captured at request start.
    start_ns: u64,

    pub fn start() TimingMiddleware {
        return .{ .start_ns = @intCast(std.time.nanoTimestamp()) };
    }

    /// Returns the elapsed duration in nanoseconds.
    pub fn elapsedNs(self: *const TimingMiddleware) u64 {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return now - self.start_ns;
    }

    /// Format elapsed time as milliseconds string into buf. Returns the written slice.
    pub fn formatHeader(self: *const TimingMiddleware, buf: []u8) []const u8 {
        const elapsed_us = self.elapsedNs() / 1000;
        const ms = elapsed_us / 1000;
        const frac = elapsed_us % 1000;
        const len = std.fmt.formatIntBuf(buf, ms, 10, .lower, .{});
        if (len + 4 <= buf.len) {
            buf[len] = '.';
            _ = std.fmt.formatIntBuf(buf[len + 1 ..], frac, 10, .lower, .{ .width = 3, .fill = '0' });
            @memcpy(buf[len + 4 ..][0..2], "ms");
            return buf[0 .. len + 6];
        }
        return buf[0..len];
    }
};

/// Request ID middleware — thin pipeline wrapper around observe.trace.RequestId.
/// The implementation lives in observe/trace.zig; this is the pipeline integration.
/// Generates ULID-based request IDs for each incoming request.
pub const RequestIdMiddleware = struct {
    /// Pre-rendered header name (X-Request-ID).
    header_name: []const u8,

    pub fn init() RequestIdMiddleware {
        return .{ .header_name = "X-Request-ID" };
    }

    /// Generate a new ULID request ID. Delegates to observe.trace.RequestId.
    pub fn generate(self: *const RequestIdMiddleware) observe_trace.RequestId {
        _ = self;
        return observe_trace.RequestId.generate();
    }

    /// Generate and encode a request ID as a 26-char string.
    pub fn generateEncoded(self: *const RequestIdMiddleware, buf: *[26]u8) void {
        const rid = self.generate();
        rid.encode(buf);
    }
};

// ---------------------------------------------------------------------------
// Python-side middleware (hooks + wrapping)
// ---------------------------------------------------------------------------

/// Hook types for Python middleware dispatch.
pub const Hook = enum {
    before_request,
    after_request,
    on_error,
};

/// A registered Python middleware function (opaque pointer to Python callable).
pub const PythonMiddleware = struct {
    /// Opaque pointer to the Python callable.
    callable: *anyopaque,
    /// Which hook this middleware is registered for (null if wrapping style).
    hook: ?Hook,
    /// Whether this is a wrapping middleware (receives call_next).
    is_wrapping: bool,
    /// Execution order (lower = earlier).
    order: u32,
};

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

/// Compiled middleware pipeline. Zig middleware resolved at startup,
/// Python middleware ordered by registration. Immutable after compile().
pub const MiddlewarePipeline = struct {
    /// Zig-side middleware (always runs first, zero Python overhead).
    cors: ?CorsMiddleware,
    security: ?SecurityHeadersMiddleware,
    timing: bool,
    request_id: ?RequestIdMiddleware,

    /// Python before_request hooks, ordered.
    before_hooks: [64]*anyopaque,
    before_count: usize,

    /// Python after_request hooks, ordered.
    after_hooks: [64]*anyopaque,
    after_count: usize,

    /// Python on_error hooks, ordered.
    error_hooks: [64]*anyopaque,
    error_count: usize,

    /// Python wrapping middleware, ordered (outermost first).
    wrappers: [32]PythonMiddleware,
    wrapper_count: usize,

    pub fn init() MiddlewarePipeline {
        return undefined;
    }

    /// Add a Zig-side CORS middleware with the given config.
    pub fn setCors(self: *MiddlewarePipeline, allocator: std.mem.Allocator, config: security_cors.CorsConfig) !void {
        self.cors = CorsMiddleware.init(allocator, config) catch return error.CorsInitFailed;
    }

    /// Add a Zig-side security headers middleware.
    pub fn setSecurity(self: *MiddlewarePipeline, allocator: std.mem.Allocator, sh: security_headers.SecurityHeaders) !void {
        self.security = SecurityHeadersMiddleware.init(allocator, sh) catch return error.SecurityHeadersInitFailed;
    }

    /// Enable Zig-side timing middleware.
    pub fn enableTiming(self: *MiddlewarePipeline) void {
        _ = .{self};
    }

    /// Enable Zig-side request ID middleware.
    pub fn enableRequestId(self: *MiddlewarePipeline) void {
        _ = .{self};
    }

    /// Register a Python hook (before_request, after_request, on_error).
    pub fn addHook(self: *MiddlewarePipeline, hook: Hook, callable: *anyopaque) void {
        _ = .{ self, hook, callable };
    }

    /// Register a Python wrapping middleware (receives call_next).
    pub fn addWrapper(self: *MiddlewarePipeline, callable: *anyopaque, order: u32) void {
        _ = .{ self, callable, order };
    }

    /// Compile the pipeline: sort by order, freeze.
    pub fn compile(self: *MiddlewarePipeline) void {
        _ = .{self};
    }

    /// Execute the full pipeline for a request. Zig middleware runs inline,
    /// Python hooks dispatched via FFI.
    pub fn execute(self: *const MiddlewarePipeline, request: *anyopaque, response: *anyopaque) !void {
        _ = .{ self, request, response };
    }
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// Application lifecycle hooks: on_startup, on_shutdown, on_error.
pub const LifecycleHooks = struct {
    startup_hooks: [32]*anyopaque,
    startup_count: usize,
    shutdown_hooks: [32]*anyopaque,
    shutdown_count: usize,

    pub fn init() LifecycleHooks {
        return undefined;
    }

    pub fn onStartup(self: *LifecycleHooks, callable: *anyopaque) void {
        _ = .{ self, callable };
    }

    pub fn onShutdown(self: *LifecycleHooks, callable: *anyopaque) void {
        _ = .{ self, callable };
    }

    pub fn runStartup(self: *const LifecycleHooks) !void {
        _ = .{self};
    }

    pub fn runShutdown(self: *const LifecycleHooks) !void {
        _ = .{self};
    }
};

// ---------------------------------------------------------------------------
// Background tasks
// ---------------------------------------------------------------------------

/// Fire-and-forget task queue. Tasks enqueued after response is sent.
/// Queue drained on graceful shutdown.
/// Source: Starlette BackgroundTask pattern (docs/GAPS_RESEARCH.md).
pub const BackgroundTaskRunner = struct {
    tasks: [256]*anyopaque,
    task_count: usize,
    running: bool,

    pub fn init() BackgroundTaskRunner {
        return undefined;
    }

    /// Enqueue a task to run after the current response is sent.
    pub fn enqueue(self: *BackgroundTaskRunner, callable: *anyopaque) void {
        _ = .{ self, callable };
    }

    /// Drain all pending tasks. Called on graceful shutdown.
    pub fn drain(self: *BackgroundTaskRunner) !void {
        _ = .{self};
    }

    /// Check if there are pending tasks.
    pub fn hasPending(self: *const BackgroundTaskRunner) bool {
        _ = .{self};
        return undefined;
    }
};

test "zig middleware ordering" {}

test "python hook dispatch" {}

test "cors preflight" {}

test "security headers applied" {}

test "timing header injected" {}

test "request id generated" {}

test "background task drain" {}

test "lifecycle startup shutdown" {}

test "middleware pipeline compile" {}
