//! snek — high-performance Python web framework with a Zig backend.
//! Top-level module re-exporting the public API surface.

pub const net = struct {
    pub const tcp = @import("net/tcp.zig");
    pub const tls = @import("net/tls.zig");
    pub const http1 = @import("net/http1.zig");
    pub const http2 = @import("net/http2.zig");
    pub const websocket = @import("net/websocket.zig");
};

pub const python = struct {
    pub const ffi = @import("python/ffi.zig");
    pub const gil = @import("python/gil.zig");
    pub const driver = @import("python/driver.zig");
    pub const coerce = @import("python/coerce.zig");
    pub const module = @import("python/module.zig");
    pub const context = @import("python/context.zig");
    pub const inject = @import("python/inject.zig");
    pub const subinterp = @import("python/subinterp.zig");
};

pub const db = struct {
    pub const wire = @import("db/wire.zig");
    pub const query = @import("db/query.zig");
    pub const types = @import("db/types.zig");
    pub const auth = @import("db/auth.zig");
};

pub const redis = struct {
    pub const protocol = @import("redis/protocol.zig");
};

pub const http = struct {
    pub const request = @import("http/request.zig");
    pub const response = @import("http/response.zig");
    pub const router = @import("http/router.zig");
    pub const middleware = @import("http/middleware.zig");
    pub const cookies = @import("http/cookies.zig");
    pub const compress = @import("http/compress.zig");
    pub const validate = @import("http/validate.zig");
};

pub const json = struct {
    pub const parse = @import("json/parse.zig");
    pub const serialize = @import("json/serialize.zig");
};

pub const security = struct {
    pub const cors = @import("security/cors.zig");
    pub const headers = @import("security/headers.zig");
    pub const jwt = @import("security/jwt.zig");
};

pub const observe = struct {
    pub const log = @import("observe/log.zig");
    pub const health = @import("observe/health.zig");
};

pub const config = struct {
    pub const toml = @import("config/toml.zig");
    pub const env = @import("config/env.zig");
};

pub const cli = struct {
    pub const main = @import("cli/main.zig");
    pub const commands = @import("cli/commands.zig");
};

pub const testing = struct {
    pub const client = @import("testing/client.zig");
    pub const conformance = @import("testing/conformance.zig");
    pub const simulation = @import("testing/simulation.zig");
};
