//! Zig-only module — server, http, router without Python dependencies.
pub const server = @import("server.zig");
pub const http = struct {
    pub const response = @import("http/response.zig");
    pub const router = @import("http/router.zig");
};
pub const net = struct {
    pub const http1 = @import("net/http1.zig");
};
