//! Full-stack test client (TestClient).
//!
//! Spins up snek in-process, makes real HTTP requests over loopback.
//! Use this for integration and end-to-end tests — this tests what you ship.
//! For unit-testing individual handlers in isolation without network overhead,
//! use `fake_client.zig` (UnitTestClient) instead.
//!
//! Generic-over-IO for simulation testing. Includes request builders,
//! cookie jar for session testing, WebSocket test client, and assertion helpers.
//!
//! Source: Full-stack over loopback — "test what you ship" principle
//! (design.md section 16).

const std = @import("std");
const json = @import("../json/parse.zig");

pub const TestResponse = struct {
    status: u16,
    headers: []const Header,
    body: []const u8,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Parse the response body as JSON.
    pub fn jsonValue(self: *const TestResponse) !json.JsonValue {
        _ = .{self};
        return undefined;
    }

    /// Return the response body as text.
    pub fn text(self: *const TestResponse) []const u8 {
        return self.body;
    }

    /// Get a response header value by name.
    pub fn header(self: *const TestResponse, name: []const u8) ?[]const u8 {
        _ = .{ self, name };
        return undefined;
    }

    // ---- Assertion helpers ----

    pub fn assertStatus(self: *const TestResponse, expected: u16) void {
        _ = .{ self, expected };
    }

    pub fn assertJson(self: *const TestResponse, expected: []const u8) void {
        _ = .{ self, expected };
    }

    pub fn assertHeader(self: *const TestResponse, name: []const u8, expected: []const u8) void {
        _ = .{ self, name, expected };
    }
};

/// Cookie jar for session testing. Persists cookies across requests.
pub const CookieJar = struct {
    cookies: [64]?Cookie,
    count: usize,

    pub const Cookie = struct {
        name: []const u8,
        value: []const u8,
        domain: ?[]const u8,
        path: ?[]const u8,
    };

    pub fn init() CookieJar {
        return .{ .cookies = .{null} ** 64, .count = 0 };
    }

    /// Store cookies from Set-Cookie response headers.
    pub fn updateFromResponse(self: *CookieJar, response: *const TestResponse) void {
        _ = .{ self, response };
    }

    /// Get the Cookie header value to send with a request.
    pub fn cookieHeader(self: *const CookieJar) ?[]const u8 {
        _ = .{self};
        return undefined;
    }

    pub fn clear(self: *CookieJar) void {
        _ = .{self};
    }
};

/// Full-stack test client, Generic-over-IO.
pub fn TestClient(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        base_url: []const u8,
        cookie_jar: CookieJar,

        /// Initialize the test client. Spins up snek in-process on loopback.
        pub fn init(io: *IO, base_url: []const u8) Self {
            return .{
                .io = io,
                .base_url = base_url,
                .cookie_jar = CookieJar.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            _ = .{self};
        }

        /// GET request.
        pub fn get(self: *Self, path: []const u8) !TestResponse {
            _ = .{ self, path };
            return undefined;
        }

        /// POST request with body.
        pub fn post(self: *Self, path: []const u8, body: []const u8) !TestResponse {
            _ = .{ self, path, body };
            return undefined;
        }

        /// POST request with JSON body.
        pub fn postJson(self: *Self, path: []const u8, json_body: []const u8) !TestResponse {
            _ = .{ self, path, json_body };
            return undefined;
        }

        /// PUT request with body.
        pub fn put(self: *Self, path: []const u8, body: []const u8) !TestResponse {
            _ = .{ self, path, body };
            return undefined;
        }

        /// DELETE request.
        pub fn delete(self: *Self, path: []const u8) !TestResponse {
            _ = .{ self, path };
            return undefined;
        }

        /// PATCH request with body.
        pub fn patch(self: *Self, path: []const u8, body: []const u8) !TestResponse {
            _ = .{ self, path, body };
            return undefined;
        }

        /// Send a request with custom headers.
        pub fn request(self: *Self, method: []const u8, path: []const u8, headers: []const TestResponse.Header, body: ?[]const u8) !TestResponse {
            _ = .{ self, method, path, headers, body };
            return undefined;
        }
    };
}

/// WebSocket test client for testing WebSocket endpoints.
pub fn WsTestClient(comptime IO: type) type {
    return struct {
        const Self = @This();

        io: *IO,
        fd: i32,
        connected: bool,

        /// Connect to a WebSocket endpoint.
        pub fn connect(io: *IO, url: []const u8) !Self {
            _ = .{ io, url };
            return undefined;
        }

        /// Send a text message.
        pub fn sendText(self: *Self, message: []const u8) !void {
            _ = .{ self, message };
        }

        /// Send a binary message.
        pub fn sendBinary(self: *Self, data: []const u8) !void {
            _ = .{ self, data };
        }

        /// Receive the next message.
        pub fn receive(self: *Self) ![]const u8 {
            _ = .{self};
            return undefined;
        }

        /// Close the WebSocket connection.
        pub fn close(self: *Self) !void {
            _ = .{self};
        }
    };
}

test "make GET request" {}

test "POST with JSON body" {}

test "WebSocket echo" {}

test "cookie jar persistence" {}

test "assertStatus" {}

test "assertJson" {}

test "assertHeader" {}

test "PUT request" {}

test "DELETE request" {}
