//! Postgres client: blocking TCP connect with startup/auth handshake.
//!
//! Provides Client.connect for the startup protocol (auth + parameter negotiation).
//! Uses wire.zig for message encoding/decoding and auth.zig for MD5/cleartext auth.
//! The returned Client.fd is handed off to the pipeline for async query execution.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const wire = @import("wire.zig");
const auth = @import("auth.zig");

// ─── Client ──────────────────────────────────────────────────────────

pub const Client = struct {
    fd: posix.socket_t,
    allocator: mem.Allocator,

    const read_buf_size = 8192;

    const BackendMessage = struct {
        tag: u8,
        payload: []u8,
        buf: [read_buf_size]u8,
    };

    /// Connect to a Postgres server, perform startup and authentication.
    /// Handles trust, cleartext, and MD5 auth. Returns error on connection failure.
    pub fn connect(
        allocator: mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
    ) !Client {
        const fd = if (host.len > 0 and host[0] == '/')
            try connectUnix(host, port)
        else
            try connectTcp(host, port);
        errdefer posix.close(fd);

        var client = Client{ .fd = fd, .allocator = allocator };

        var startup_buf: [256]u8 = undefined;
        const startup_msg = wire.encodeStartupMessage(&startup_buf, user, database);
        try client.sendAll(startup_msg);

        try client.handleStartupResponse(user, password);

        return client;
    }

    // ─── Internal helpers ────────────────────────────────────────────

    /// Connect via Unix domain socket. Path is the socket directory,
    /// socket file is `.s.PGSQL.<port>` per PG convention.
    fn connectUnix(dir: []const u8, port: u16) !posix.socket_t {
        var path_buf: [108]u8 = undefined; // sun_path max
        const path = std.fmt.bufPrint(&path_buf, "{s}/.s.PGSQL.{d}\x00", .{ dir, port }) catch
            return error.InvalidAddress;
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memcpy(addr.path[0..path.len], path[0..path.len]);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        return fd;
    }

    /// Connect via TCP. Handles both numeric IPs and hostnames.
    fn connectTcp(host: []const u8, port: u16) !posix.socket_t {
        const stream = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
        return stream.handle;
    }

    fn sendAll(self: *Client, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try posix.write(self.fd, data[sent..]);
            if (n == 0) return error.ConnectionRefused;
            sent += n;
        }
    }

    fn readExact(self: *Client, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try posix.read(self.fd, buf[total..]);
            if (n == 0) return error.ConnectionRefused;
            total += n;
        }
    }

    /// Read the next complete backend message. Returns tag + payload in a stack-allocated buffer.
    fn readBackendMessage(self: *Client) !BackendMessage {
        var header_buf: [5]u8 = undefined;
        try self.readExact(&header_buf);
        const header = try wire.readMessageHeader(&header_buf);
        const payload_len = header.length - 4; // length includes itself but not tag

        var result = BackendMessage{
            .tag = header.tag,
            .payload = undefined,
            .buf = undefined,
        };

        if (payload_len > read_buf_size) return error.MessageTooLarge;
        try self.readExact(result.buf[0..payload_len]);
        result.payload = result.buf[0..payload_len];
        return result;
    }

    fn handleStartupResponse(self: *Client, user: []const u8, password: ?[]const u8) !void {
        while (true) {
            const msg = try self.readBackendMessage();
            switch (msg.tag) {
                wire.BackendTag.authentication => {
                    const auth_type = try wire.parseAuthType(msg.payload);
                    switch (auth_type) {
                        .ok => {}, // AuthenticationOk — continue reading
                        .cleartext_password => {
                            const pw = password orelse return error.AuthenticationFailed;
                            var pw_buf: [256]u8 = undefined;
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, pw);
                            try self.sendAll(pw_msg);
                        },
                        .md5_password => {
                            const pw = password orelse return error.AuthenticationFailed;
                            const salt = try wire.parseMd5Salt(msg.payload);
                            const md5_hash = auth.computeMd5Password(user, pw, salt);
                            var pw_buf: [256]u8 = undefined;
                            const pw_msg = wire.encodePasswordMessage(&pw_buf, &md5_hash);
                            try self.sendAll(pw_msg);
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                wire.BackendTag.parameter_status => {
                    // Ignore for now — tracked params are a Phase 11 concern.
                },
                wire.BackendTag.backend_key_data => {
                    // Store pid/secret for cancel — ignored for MVP.
                },
                wire.BackendTag.ready_for_query => {
                    return; // Startup complete
                },
                wire.BackendTag.error_response => {
                    return error.ServerError;
                },
                else => {
                    // Skip unknown messages during startup
                },
            }
        }
    }
};
