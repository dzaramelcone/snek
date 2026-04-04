//! Shared library entry point for _snek Python extension module.
//! Exports PyInit__snek for Python to load.

const std = @import("std");
const snek_log = @import("log.zig");

pub const std_options: std.Options = .{
    .logFn = snek_log.logFn,
};

pub const python = struct {
    pub const ffi = @import("python/ffi.zig");
    pub const module = @import("python/module.zig");
    pub const driver = @import("python/driver.zig");
};

pub const http = struct {
    pub const router = @import("http/router.zig");
    pub const response = @import("http/response.zig");
};
pub const net = struct {
    pub const http1 = @import("net/http1.zig");
};

// Force the linker to include PyInit__snek by referencing it.
comptime {
    _ = &python.module.PyInit__snek;
}
