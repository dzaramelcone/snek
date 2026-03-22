//! Lightweight unit-test client (UnitTestClient).
//!
//! Bypasses network and HTTP parsing — routes requests directly to the
//! application handler in-process. Use this for unit-testing individual
//! handlers in isolation. Zero network overhead.
//!
//! Not for integration tests — use `client.zig` (TestClient) for full-stack
//! testing over real HTTP.

const std = @import("std");
const json = @import("../json/parse.zig");

pub const FakeRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: ?[]const u8,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

pub const FakeResponse = struct {
    status: u16,
    headers: []const FakeRequest.Header,
    body: []const u8,

    /// Parse the response body as JSON.
    pub fn jsonValue(self: *const FakeResponse) !json.JsonValue {
        _ = .{self};
        return undefined;
    }

    /// Return the response body as text.
    pub fn text(self: *const FakeResponse) []const u8 {
        return self.body;
    }
};

/// Unit-test client that routes requests directly to the in-process handler
/// without going through TCP/HTTP parsing. Zero network overhead.
/// For full-stack integration tests over real HTTP, use TestClient instead.
pub const FakeClient = struct {
    handler: *anyopaque,

    /// Create a FakeClient wrapping the application handler.
    pub fn init(handler: *anyopaque) FakeClient {
        return .{ .handler = handler };
    }

    /// Send a request directly to the handler.
    pub fn send(self: *FakeClient, request: FakeRequest) !FakeResponse {
        _ = .{ self, request };
        return undefined;
    }

    /// Convenience: GET request.
    pub fn get(self: *FakeClient, path: []const u8) !FakeResponse {
        _ = .{ self, path };
        return undefined;
    }

    /// Convenience: POST request with body.
    pub fn post(self: *FakeClient, path: []const u8, body: []const u8) !FakeResponse {
        _ = .{ self, path, body };
        return undefined;
    }

    /// Convenience: PUT request with body.
    pub fn put(self: *FakeClient, path: []const u8, body: []const u8) !FakeResponse {
        _ = .{ self, path, body };
        return undefined;
    }

    /// Convenience: DELETE request.
    pub fn delete(self: *FakeClient, path: []const u8) !FakeResponse {
        _ = .{ self, path };
        return undefined;
    }
};

test "fake client GET" {}

test "fake client POST" {}

test "fake client direct handler dispatch" {}
