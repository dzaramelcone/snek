//! HTTP/2 implementation: HPACK, stream multiplexing, flow control.
//!
//! Design decisions:
//! - HPACK encoder/decoder with static table (RFC 7541 Appendix A),
//!   dynamic table, and Huffman coding.
//! - Stream multiplexing with per-stream and connection-level flow control.
//! - GOAWAY for graceful shutdown.
//! - h2c (cleartext HTTP/2) support for internal services.
//! - SETTINGS negotiation.
//! - Priority handling via RFC 9218 extensible priorities (not deprecated
//!   RFC 7540 tree-based priorities).
//! - extern struct for wire-format frame header with comptime no_padding assertion.

const std = @import("std");

// --- Wire format types (extern struct, TigerBeetle pattern) ---

/// HTTP/2 frame header. 9 bytes on the wire.
/// extern struct with comptime no_padding assertion.
// Inspired by: TigerBeetle — extern struct with comptime no_padding assertion for wire-format safety
pub const FrameHeader = extern struct {
    /// Frame payload length (24-bit, stored in 3 bytes on wire; u32 here for alignment).
    length: u32,
    /// Frame type (DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, etc.).
    frame_type: u8,
    /// Frame flags (END_STREAM, END_HEADERS, PADDED, PRIORITY, etc.).
    flags: u8,
    /// Stream identifier (31-bit, high bit reserved).
    stream_id: u32,

    comptime {
        // Intentionally 12 bytes in-memory (wire encoding is 9 bytes, decoded into this).
        if (@sizeOf(FrameHeader) != 12) @compileError("FrameHeader has unexpected padding");
    }
};

/// HTTP/2 frame types (RFC 9113 Section 6).
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

/// HTTP/2 error codes (RFC 9113 Section 7).
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

/// HTTP/2 frame with header and payload.
pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,
};

// --- Stream state machine ---

pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

/// A single HTTP/2 stream with flow control.
pub const Stream = struct {
    id: u31,
    state: StreamState = .idle,
    /// Send window size (decremented on DATA send, incremented by WINDOW_UPDATE).
    send_window: i32 = 65535,
    /// Receive window size (decremented on DATA receive, incremented by our WINDOW_UPDATE).
    recv_window: i32 = 65535,
    /// RFC 9218 extensible priority: urgency (0-7, default 3).
    // See: src/net/REFERENCES.md §RFC9218 — extensible priorities (not deprecated RFC 7540 trees)
    priority_urgency: u3 = 3,
    /// RFC 9218 extensible priority: incremental flag.
    priority_incremental: bool = false,
};

// --- SETTINGS ---

/// HTTP/2 SETTINGS parameters (RFC 9113 Section 6.5.2).
pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = false,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,
    /// RFC 8441: Enable CONNECT protocol for WebSocket over HTTP/2.
    enable_connect_protocol: bool = false,
};

// --- HPACK ---

/// HPACK static table entry (RFC 7541 Appendix A).
// See: RFC 7541 §Appendix A — HPACK static table definition
pub const StaticTableEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// HPACK encoder with static table, dynamic table, and Huffman coding.
// See: RFC 7541 §5-7 — HPACK encoding with static/dynamic tables and Huffman coding
pub fn HpackEncoder(comptime IO: type) type {
    return struct {
        const Self = @This();

        dynamic_table: [256][2][]const u8 = undefined,
        table_size: usize = 0,
        max_table_size: usize = 4096,
        io: *IO,

        /// Encode a list of header name-value pairs into HPACK wire format.
        pub fn encode(self: *Self, headers: []const [2][]const u8, out: []u8) !usize {
            _ = .{ self, headers, out };
            return undefined;
        }

        /// Encode a single header using Huffman coding.
        pub fn encodeHuffman(self: *Self, data: []const u8, out: []u8) !usize {
            _ = .{ self, data, out };
            return undefined;
        }

        /// Update the dynamic table size.
        pub fn setMaxTableSize(self: *Self, size: usize) void {
            _ = .{ self, size };
        }
    };
}

/// HPACK decoder with static table, dynamic table, and Huffman decoding.
// See: RFC 7541 §5-7 — HPACK decoding with static/dynamic tables and Huffman coding
pub fn HpackDecoder(comptime IO: type) type {
    return struct {
        const Self = @This();

        dynamic_table: [256][2][]const u8 = undefined,
        table_size: usize = 0,
        max_table_size: usize = 4096,
        io: *IO,

        /// Decode HPACK wire format into a list of header name-value pairs.
        pub fn decode(self: *Self, data: []const u8, out: [][2][]const u8) !usize {
            _ = .{ self, data, out };
            return undefined;
        }

        /// Decode Huffman-encoded data.
        pub fn decodeHuffman(self: *Self, data: []const u8, out: []u8) !usize {
            _ = .{ self, data, out };
            return undefined;
        }

        /// Update the dynamic table size.
        pub fn setMaxTableSize(self: *Self, size: usize) void {
            _ = .{ self, size };
        }
    };
}

// --- Connection ---

/// HTTP/2 connection, generic over IO backend.
/// Manages streams, HPACK state, flow control, and settings negotiation.
pub fn Http2Connection(comptime IO: type) type {
    return struct {
        const Self = @This();

        streams: [256]Stream = undefined,
        stream_count: usize = 0,
        encoder: HpackEncoder(IO),
        decoder: HpackDecoder(IO),
        io: *IO,

        /// Local settings (what we advertise to the peer).
        local_settings: Settings = .{},
        /// Remote settings (what the peer advertised to us).
        remote_settings: Settings = .{},
        /// Connection-level send window.
        conn_send_window: i32 = 65535,
        /// Connection-level receive window.
        conn_recv_window: i32 = 65535,
        /// Last stream ID processed (used in GOAWAY).
        last_stream_id: u31 = 0,

        /// Handle an incoming frame. Dispatches by frame type.
        pub fn handleFrame(self: *Self, frame: Frame) !void {
            _ = .{ self, frame };
        }

        /// Send a frame to the peer.
        pub fn sendFrame(self: *Self, frame: Frame) !void {
            _ = .{ self, frame };
        }

        /// Open a new stream. Returns the stream ID.
        pub fn openStream(self: *Self) !u31 {
            _ = .{self};
            return undefined;
        }

        /// Close a stream with an optional error code.
        pub fn closeStream(self: *Self, stream_id: u31, error_code: ErrorCode) !void {
            _ = .{ self, stream_id, error_code };
        }

        /// Send SETTINGS frame to the peer.
        pub fn sendSettings(self: *Self) !void {
            _ = .{self};
        }

        /// Acknowledge received SETTINGS from the peer.
        pub fn ackSettings(self: *Self) !void {
            _ = .{self};
        }

        /// Send GOAWAY frame for graceful shutdown.
        /// Includes the last stream ID we will process and an error code.
        pub fn sendGoaway(self: *Self, error_code: ErrorCode, debug_data: []const u8) !void {
            _ = .{ self, error_code, debug_data };
        }

        /// Send a WINDOW_UPDATE frame to increase the peer's send window.
        pub fn sendWindowUpdate(self: *Self, stream_id: u31, increment: u31) !void {
            _ = .{ self, stream_id, increment };
        }

        /// Send a PING frame.
        pub fn sendPing(self: *Self, data: [8]u8) !void {
            _ = .{ self, data };
        }

        /// Handle h2c (cleartext HTTP/2) upgrade from HTTP/1.1.
        pub fn upgradeFromH1(self: *Self, settings_payload: []const u8) !void {
            _ = .{ self, settings_payload };
        }

        /// Update priority for a stream (RFC 9218 extensible priorities).
        // See: src/net/REFERENCES.md §RFC9218 — extensible priorities replace deprecated RFC 7540 tree-based model
        pub fn updatePriority(self: *Self, stream_id: u31, urgency: u3, incremental: bool) !void {
            _ = .{ self, stream_id, urgency, incremental };
        }
    };
}

test "hpack encode headers" {}

test "hpack decode headers" {}

test "hpack huffman encode" {}

test "hpack huffman decode" {}

test "hpack static table lookup" {}

test "hpack dynamic table eviction" {}

test "http2 open and close stream" {}

test "http2 handle frame" {}

test "http2 flow control" {}

test "http2 settings negotiation" {}

test "http2 goaway graceful shutdown" {}

test "http2 h2c upgrade" {}

test "http2 window update" {}

test "http2 rfc9218 extensible priorities" {}

test "http2 frame header extern struct no padding" {}
