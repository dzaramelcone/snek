//! snek — high-performance Python web framework with a Zig backend.
//! Top-level module re-exporting the public API surface.

pub const net = struct {
    pub const http1 = @import("net/http1.zig");
};

pub const python = struct {
    pub const ffi = @import("python/ffi.zig");
    pub const driver = @import("python/driver.zig");
    pub const module = @import("python/module.zig");
    pub const subinterp = @import("python/subinterp.zig");
};

pub const db = struct {
    pub const wire = @import("db/wire.zig");
    pub const auth = @import("db/auth.zig");
    pub const query = @import("db/query.zig");
};

pub const http = struct {
    pub const response = @import("http/response.zig");
    pub const router = @import("http/router.zig");
};

pub const testing = struct {
    pub const simulation = @import("testing/simulation.zig");
};
