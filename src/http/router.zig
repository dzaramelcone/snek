//! Compiled radix trie router with per-method dispatch trees.
//!
//! Design: matchit-inspired compressed radix trie. Separate tree per HTTP method
//! for reduced search space. Static segments take priority over parameters.
//! Route conflict detection at startup. Zero-copy path param extraction via
//! slices into the original URL. Immutable after compilation.
//!
//! HEAD auto-generated from GET. OPTIONS auto-generated for CORS.
//! 405 MethodNotAllowed with Allow header when path matches but method doesn't.
//!
//! Sources:
//!   - matchit/axum compiled radix trie (src/http/REFERENCES_router.md)
//!     Target: 2.45us/130 routes benchmark
//!   - Per-method trees and static-over-param priority from matchit

const std = @import("std");

/// HTTP methods with separate dispatch trees.
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) ?Method {
        _ = .{s};
        return undefined;
    }
};

/// Zero-copy path parameter: name + value are slices into the original URL.
pub const PathParam = struct {
    name: []const u8,
    value: []const u8,
};

/// Result of matching a URL against the router.
pub const RouteMatch = struct {
    handler: ?*anyopaque,
    params: [16]PathParam,
    param_count: usize,
    /// Which method actually matched (HEAD may resolve to GET handler).
    matched_method: Method,
};

/// Route metadata for introspection and CLI `snek routes`.
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: ?*anyopaque,
    name: ?[]const u8,
};

/// Describes a conflict between two registered routes.
pub const RouteConflict = struct {
    path_a: []const u8,
    path_b: []const u8,
    method: Method,
};

/// Segment type within a route pattern.
const SegmentKind = enum {
    /// Literal path segment, e.g. "users".
    static,
    /// Named parameter, e.g. "{id}" — matches one segment.
    param,
    /// Catch-all, e.g. "{rest:path}" — matches remaining path, must be terminal.
    catch_all,
};

/// A compressed radix trie node.
///
/// Path segments are stored compressed (e.g. "/api/v1" as a single segment
/// when no branching occurs). Children ordered by priority: static > param > catch_all,
/// then by handler count in subtree (descending) for cache-friendly first-match.
/// Source: matchit crate's compressed radix trie node layout (src/http/REFERENCES_router.md).
pub const RadixNode = struct {
    /// Compressed path segment stored at this node.
    segment: []const u8,
    /// Segment kind determines matching behavior.
    kind: SegmentKind,
    /// Parameter name if kind is param or catch_all.
    param_name: ?[]const u8,
    /// Children ordered by priority (static first, then param, then catch_all).
    children: [64]*RadixNode,
    child_count: usize,
    /// Handler if this node terminates a registered route.
    handler: ?*anyopaque,
    /// Number of handlers in this subtree (for priority ordering).
    priority: u32,
};

/// Per-method radix tree. One tree per HTTP method.
/// Source: matchit/axum per-method dispatch — separate tree per HTTP method
/// reduces search space vs single-tree routers (src/http/REFERENCES_router.md).
const MethodTree = struct {
    root: RadixNode,
    route_count: usize,
};

/// Compiled radix trie router with per-method dispatch.
pub const Router = struct {
    /// One radix tree per HTTP method.
    trees: [7]MethodTree,
    /// All registered routes for introspection.
    routes: [512]Route,
    route_count: usize,
    /// Whether the router has been compiled (frozen).
    compiled: bool,

    pub fn init() Router {
        return undefined;
    }

    /// Register a route. Must be called before compile().
    pub fn addRoute(self: *Router, method: Method, path: []const u8, handler: *anyopaque) !void {
        _ = .{ self, method, path, handler };
    }

    /// Register a named route.
    pub fn addNamedRoute(self: *Router, method: Method, path: []const u8, handler: *anyopaque, name: []const u8) !void {
        _ = .{ self, method, path, handler, name };
    }

    /// Compile and freeze the router. Detects conflicts, computes priorities,
    /// orders children, generates HEAD from GET, OPTIONS from all methods.
    /// After this call the router is immutable.
    pub fn compile(self: *Router) !void {
        _ = .{self};
    }

    /// Match a URL path against the compiled router.
    /// Returns null if no route matches. Tries HEAD → GET fallback.
    /// If path matches but method doesn't, returns MethodNotAllowed (see matchOrError).
    pub fn match(self: *const Router, method: Method, path: []const u8) ?RouteMatch {
        _ = .{ self, method, path };
        return undefined;
    }

    /// Match with full error reporting: returns the match, or a 405 with allowed methods.
    pub fn matchOrError(self: *const Router, method: Method, path: []const u8) MatchResult {
        _ = .{ self, method, path };
        return undefined;
    }

    /// List all registered routes. Used by `snek routes` CLI command.
    pub fn listRoutes(self: *const Router) []const Route {
        _ = .{self};
        return undefined;
    }

    /// Detect route conflicts (e.g. "/users/{id}" vs "/users/{name}").
    /// Called during compile(). Returns conflicts if any.
    pub fn detectConflicts(self: *const Router) ![]const RouteConflict {
        _ = .{self};
        return undefined;
    }

    /// Generate Allow header value for a given path (for 405 responses).
    pub fn allowedMethods(self: *const Router, path: []const u8) []const u8 {
        _ = .{ self, path };
        return undefined;
    }
};

/// Result of matchOrError: either a match, a 405 with Allow header, or 404.
pub const MatchResult = union(enum) {
    found: RouteMatch,
    method_not_allowed: struct {
        allow_header: []const u8,
    },
    not_found: void,
};

/// Comptime route compilation: if routes are known at comptime, build the
/// radix trie at compile time for zero startup cost.
pub fn ComptimeRouter(comptime routes: []const struct { method: Method, path: []const u8 }) type {
    _ = .{routes};
    return struct {
        pub fn match(method: Method, path: []const u8) ?RouteMatch {
            _ = .{ method, path };
            return undefined;
        }
    };
}

test "static priority over param" {}

test "conflict detection" {}

test "param extraction" {}

test "method not allowed with allow header" {}

test "head auto-generated from get" {}

test "options auto-generated" {}

test "catch-all matching" {}

test "list routes for cli" {}

test "comptime route compilation" {}
