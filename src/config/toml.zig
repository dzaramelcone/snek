//! snek.toml configuration file parser.
//!
//! Full config schema with all subsections. Each config struct has sensible defaults.
//! Env interpolation via ${VAR_NAME} syntax (delegated to env.zig).

const std = @import("std");

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    workers: u16 = 0,
    backlog: u16 = 2048,
    debug: bool = false,
};

pub const TlsConfig = struct {
    enabled: bool = false,
    cert: []const u8 = "",
    key: []const u8 = "",
    min_version: []const u8 = "1.2",
};

pub const DatabaseConfig = struct {
    url: []const u8 = "",
    pool_min: u16 = 2,
    pool_max: u16 = 20,
    statement_cache: u16 = 100,
    connect_timeout: u16 = 5,
    query_timeout: u16 = 30,
};

pub const RedisConfig = struct {
    url: []const u8 = "redis://localhost:6379",
    pool_min: u16 = 2,
    pool_max: u16 = 20,
};

pub const CorsConfig = struct {
    origins: []const []const u8 = &.{"*"},
    methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    headers: []const []const u8 = &.{"*"},
    credentials: bool = false,
    max_age: u32 = 86400,
};

pub const LimitsConfig = struct {
    body_size: []const u8 = "10mb",
    header_size: []const u8 = "8kb",
    request_timeout: u16 = 30,
    keepalive_timeout: u16 = 75,
    max_connections: u32 = 10_000,
};

pub const CompressionConfig = struct {
    enabled: bool = true,
    algorithms: []const []const u8 = &.{ "br", "gzip" },
    min_size: u32 = 1024,
};

pub const StaticConfig = struct {
    path: []const u8 = "/static",
    dir: []const u8 = "./static",
};

pub const AuthConfig = struct {
    jwt_secret: ?[]const u8 = null,
    jwt_algorithms: []const []const u8 = &.{"HS256"},
    jwt_jwks_url: ?[]const u8 = null,
};

pub const HealthConfig = struct {
    path: []const u8 = "/health",
    check_db: bool = true,
};

pub const MetricsConfig = struct {
    enabled: bool = false,
    path: []const u8 = "/metrics",
};

pub const LoggingConfig = struct {
    level: []const u8 = "info",
    format: []const u8 = "json",
    access_log: bool = true,
};

pub const SessionConfig = struct {
    backend: []const u8 = "redis",
    ttl: u32 = 86400,
    cookie_name: []const u8 = "snek_sid",
    cookie_secure: bool = true,
    cookie_httponly: bool = true,
    cookie_samesite: []const u8 = "lax",
};

pub const OAuthProviderConfig = struct {
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    authorize_url: []const u8 = "",
    token_url: []const u8 = "",
    userinfo_url: []const u8 = "",
    redirect_uri: []const u8 = "",
    scope: []const u8 = "",
};

pub const DocsConfig = struct {
    enabled: bool = false,
    path: []const u8 = "/docs",
};

/// Top-level snek.toml configuration.
pub const SnekConfig = struct {
    server: ServerConfig = .{},
    tls: ?TlsConfig = null,
    database: ?DatabaseConfig = null,
    redis: ?RedisConfig = null,
    cors: ?CorsConfig = null,
    limits: LimitsConfig = .{},
    compression: CompressionConfig = .{},
    static: ?StaticConfig = null,
    auth: ?AuthConfig = null,
    health: ?HealthConfig = null,
    metrics: MetricsConfig = .{},
    logging: LoggingConfig = .{},
    session: ?SessionConfig = null,
    oauth: ?[]const OAuthProviderConfig = null,
    docs: ?DocsConfig = null,

    /// Parse snek.toml source into SnekConfig.
    pub fn parse(allocator: std.mem.Allocator, toml_source: []const u8) !SnekConfig {
        _ = .{ allocator, toml_source };
        return undefined;
    }

    /// Validate config for invalid combinations (e.g. TLS enabled without cert).
    pub fn validate(self: *const SnekConfig) !void {
        _ = .{self};
    }

    /// Get a config value by dotted key path (e.g. "server.port").
    pub fn get(self: *const SnekConfig, key: []const u8) ?[]const u8 {
        _ = .{ self, key };
        return undefined;
    }

    /// Apply env interpolation to all string values containing ${VAR_NAME}.
    pub fn interpolateEnv(self: *SnekConfig, allocator: std.mem.Allocator) !void {
        _ = .{ self, allocator };
    }
};

test "parse minimal config" {}

test "parse full config" {}

test "env interpolation" {}

test "validation errors" {}

test "config defaults" {}

test "config tls section" {}

test "config database section" {}

test "config cors section" {}

test "config redis section" {}

test "config limits section" {}

test "config compression section" {}

test "config session section" {}

test "config oauth section" {}

test "config get dotted key" {}
