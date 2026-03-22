//! Dependency injection resolution engine (Zig side).
//!
//! Builds a DependencyGraph at startup from @app.injectable registrations,
//! validates acyclicity and completeness, and resolves dependencies
//! per-request with scope-aware caching.
//!
//! Three scopes: singleton (app lifetime), request (per-request),
//! transient (per-injection site).
//!
//! Sources:
//!   - DI graph design from ASP.NET Core (python/snek/REFERENCES_di.md — gold standard)
//!   - Scope management from Zenject (python/snek/REFERENCES_di.md section 15)

const std = @import("std");
const ffi = @import("ffi.zig");

// ── Scope ───────────────────────────────────────────────────────────

/// Source: Zenject scope model (python/snek/REFERENCES_di.md section 15).
pub const Scope = enum {
    /// App lifetime. Created once, shared across all requests.
    singleton,
    /// Per-request. Created once per request, shared within that request.
    request,
    /// Per-injection site. New instance every time it's injected.
    transient,
};

// ── Injectable metadata ─────────────────────────────────────────────

pub const InjectableInfo = struct {
    /// Qualified name of the injectable type/function.
    name: []const u8,
    /// The Python factory (function or generator).
    factory: *ffi.PyObject,
    /// Scope for caching.
    scope: Scope,
    /// Names of dependencies this injectable requires.
    dependencies: []const []const u8,
    /// Whether the factory is a yield-based generator (lifecycle management).
    is_generator: bool,
};

// ── DependencyGraph ─────────────────────────────────────────────────

/// Built at startup from all @app.injectable registrations.
/// Validated before the first request arrives.
/// Source: ASP.NET Core DI container — graph validation at startup, not at
/// first request (python/snek/REFERENCES_di.md).
pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(InjectableInfo),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(InjectableInfo).init(allocator),
        };
    }

    /// Register an injectable in the graph.
    pub fn register(self: *DependencyGraph, info: InjectableInfo) !void {
        _ = .{ self, info };
    }

    /// Validate the graph at startup:
    /// - Detect circular dependencies (error)
    /// - Detect missing dependencies (error)
    /// - Verify scope compatibility (singleton cannot depend on request)
    pub fn validateGraph(self: *DependencyGraph) !void {
        _ = self;
    }

    /// Check for circular dependencies via DFS.
    fn detectCycles(self: *DependencyGraph) !void {
        _ = self;
    }

    /// Check that all declared dependencies exist in the graph.
    fn checkMissingDeps(self: *DependencyGraph) !void {
        _ = self;
    }

    /// Verify scope rules: singleton must not depend on request/transient.
    fn checkScopeCompatibility(self: *DependencyGraph) !void {
        _ = self;
    }

    /// Get topological order for resolution.
    pub fn topologicalOrder(self: *DependencyGraph) ![]const []const u8 {
        _ = self;
        return undefined;
    }

    pub fn deinit(self: *DependencyGraph) void {
        self.nodes.deinit();
    }
};

// ── SingletonCache ──────────────────────────────────────────────────

/// App-lifetime cache for singleton-scoped injectables.
pub const SingletonCache = struct {
    cache: std.StringHashMap(*ffi.PyObject),

    pub fn init(allocator: std.mem.Allocator) SingletonCache {
        return .{ .cache = std.StringHashMap(*ffi.PyObject).init(allocator) };
    }

    pub fn get(self: *SingletonCache, name: []const u8) ?*ffi.PyObject {
        return self.cache.get(name);
    }

    pub fn put(self: *SingletonCache, name: []const u8, value: *ffi.PyObject) !void {
        _ = .{ self, name, value };
    }

    pub fn deinit(self: *SingletonCache) void {
        self.cache.deinit();
    }
};

// ── Per-request resolution ──────────────────────────────────────────

/// Resolve all dependencies for a handler invocation.
/// Uses the graph, singleton cache, per-request cache, and the current request.
///
/// Request (Zig) ←→ RequestContext (Python) ←→ DI resolution reads from Request
///
/// The request parameter gives resolvers access to request-scoped context
/// (request ID, user, trace, state dict) so DI factories can depend on
/// request data without global state.
pub fn resolveForRequest(
    graph: *DependencyGraph,
    singletons: *SingletonCache,
    handler_deps: []const []const u8,
    request: *anyopaque,
) ![]const *ffi.PyObject {
    _ = .{ graph, singletons, handler_deps, request };
    return undefined;
}

// ── Override for testing ────────────────────────────────────────────

/// Replace an injectable's factory without monkey-patching.
/// Used in tests: `app.override(db_session, fake_db_session)`.
pub fn overrideInjectable(graph: *DependencyGraph, name: []const u8, replacement: *ffi.PyObject) !void {
    _ = .{ graph, name, replacement };
}

// ── Undefined sentinel ──────────────────────────────────────────────

// Stub functions return Zig's builtin `undefined` as placeholder values.

// ── Tests ───────────────────────────────────────────────────────────

test "validate acyclic graph" {}

test "detect circular dependency" {}

test "detect missing dependency" {}

test "scope compatibility check" {}

test "resolve singleton scope" {}

test "resolve request scope" {}

test "resolve transient scope" {}

test "override injectable for testing" {}

test "topological resolution order" {}
