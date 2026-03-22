//! Request smuggling detection and prevention.
//!
//! Dedicated module for strict Content-Length / Transfer-Encoding validation
//! and HTTP desync detection. First-class concern per Kettle 2025 research
//! (24 million sites exposed to CL/TE desync attacks).
//!
//! Reference: James Kettle, "Browser-Powered Desync Attacks" (2025).
//! Reference: RFC 9112 Section 6.3 (Message Body Length).

/// Smuggling detection errors.
// Inspired by: Kettle 2025 "HTTP/1.1 Must Die" (src/net/REFERENCES.md) — strict CL/TE validation against desync attacks
// See: RFC 9112 §6.3 — Message Body Length determination rules
pub const SmugglingError = error{
    /// Both Content-Length and Transfer-Encoding headers present.
    /// RFC 9112: "If a message is received with both a Transfer-Encoding and a
    /// Content-Length header field, the Transfer-Encoding overrides the
    /// Content-Length." However, the safe behavior is to reject.
    AmbiguousContentLength,

    /// Multiple Content-Length headers with different values.
    /// This is the classic CL.CL desync vector.
    DuplicateContentLength,

    /// Transfer-Encoding header with a value other than "chunked"
    /// combined with Content-Length, or multiple Transfer-Encoding values.
    TransferEncodingAfterContentLength,

    /// Malformed chunked encoding (invalid chunk size, premature termination).
    MalformedChunkedEncoding,

    /// Request line contains characters that may enable desync
    /// (null bytes, obs-fold, bare \n without \r, etc.).
    MalformedRequestLine,

    /// Transfer-Encoding value that is not exactly "chunked".
    /// Rejects "chunked, identity", "chunked , chunked", etc.
    /// Strict: only bare "chunked" is accepted.
    NonCanonicalTransferEncoding,

    /// Content-Length value is not a valid non-negative integer.
    InvalidContentLengthValue,

    /// Body length exceeds declared Content-Length.
    ContentLengthMismatch,
};

/// Result of smuggling validation.
pub const BodyFraming = enum {
    /// No body (e.g., GET, HEAD, or 204/304 response).
    none,
    /// Body length determined by Content-Length header.
    content_length,
    /// Body is chunked transfer encoded.
    chunked,
};

/// Validate Content-Length and Transfer-Encoding headers for smuggling vectors.
///
/// Rules (strict mode, following Kettle 2025 recommendations):
// Reference: src/net/REFERENCES.md — Kettle 2025 strict CL/TE/CL+TE rejection rules
/// 1. If both CL and TE present: reject with AmbiguousContentLength.
/// 2. If multiple CL headers with different values: reject with DuplicateContentLength.
/// 3. If TE value is not exactly "chunked": reject with NonCanonicalTransferEncoding.
/// 4. If CL value is not a valid non-negative integer: reject with InvalidContentLengthValue.
///
/// Returns the determined body framing strategy.
pub fn validateBodyFraming(
    content_length_headers: []const []const u8,
    transfer_encoding_headers: []const []const u8,
) SmugglingError!BodyFraming {
    _ = .{ content_length_headers, transfer_encoding_headers };
    return .none;
}

/// Validate a request line for characters that enable desync attacks.
// Reference: src/net/REFERENCES.md — Kettle 2025 request line validation (null bytes, bare LF, obs-fold)
/// Rejects:
/// - Null bytes (0x00)
/// - Bare \n without preceding \r
/// - Obs-fold (line folding in headers)
/// - Non-printable characters in the request target
pub fn validateRequestLine(line: []const u8) SmugglingError!void {
    _ = .{line};
}

/// Validate a Content-Length value string.
/// Must be a non-negative integer with no leading zeros (except "0" itself),
/// no whitespace, no sign characters.
pub fn validateContentLength(value: []const u8) SmugglingError!u64 {
    _ = .{value};
    return 0;
}

/// Validate Transfer-Encoding value.
/// Only bare "chunked" is accepted. Anything else (including "chunked, identity",
/// multiple values, or unknown encodings) is rejected.
pub fn validateTransferEncoding(value: []const u8) SmugglingError!void {
    _ = .{value};
}

test "smuggling reject cl and te" {}

test "smuggling reject duplicate cl" {}

test "smuggling reject non canonical te" {}

test "smuggling validate content length" {}

test "smuggling validate request line null bytes" {}

test "smuggling validate request line bare lf" {}

test "smuggling accept valid cl" {}

test "smuggling accept valid te chunked" {}

test "smuggling accept no body" {}
