//! Shared handler/runtime types used by the active server pipelines.

const http1 = @import("net/http1.zig");
const router_mod = @import("http/router.zig");
const response_mod = @import("http/response.zig");
const subinterp = @import("python/subinterp.zig");

pub const HandlerFn = *const fn (*const http1.Request) response_mod.Response;

pub const PyHandlerFlags = extern struct {
    needs_request: bool = true,
    needs_params: bool = false,
    no_args: bool = false,
    is_async: bool = false,
};

/// Everything needed to handle a request. Shared across server implementations.
pub const RequestContext = struct {
    router: *const router_mod.Router,
    handlers: *const [64]?HandlerFn,
    py_handler_ids: *const [64]?u32,
    py_handler_flags: ?*const [64]PyHandlerFlags = null,
    py_ctx: ?*PyContext = null,
};

/// Per-thread Python context for handler invocations.
pub const PyContext = struct {
    py: *subinterp.WorkerPyContext,
};
