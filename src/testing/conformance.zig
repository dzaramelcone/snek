//! Internal conformance test stubs for protocol implementations.
//!
//! Sources:
//!   - Autobahn for WebSocket conformance testing
//!   - h2spec for HTTP/2 conformance testing
//!   - testssl.sh for TLS conformance testing

pub const HttpConformance = struct {
    pub fn testChunkedEncoding(self: *HttpConformance) void {
        _ = self;
    }

    pub fn testKeepalive(self: *HttpConformance) void {
        _ = self;
    }

    pub fn testPipelining(self: *HttpConformance) void {
        _ = self;
    }

    pub fn testContinue(self: *HttpConformance) void {
        _ = self;
    }

    pub fn testContentLength(self: *HttpConformance) void {
        _ = self;
    }

    pub fn testMethodOverride(self: *HttpConformance) void {
        _ = self;
    }
};

/// Source: Autobahn WebSocket testsuite.
pub const WsConformance = struct {
    pub fn testFraming(self: *WsConformance) void {
        _ = self;
    }

    pub fn testFragmentation(self: *WsConformance) void {
        _ = self;
    }

    pub fn testUtf8(self: *WsConformance) void {
        _ = self;
    }

    pub fn testClose(self: *WsConformance) void {
        _ = self;
    }

    pub fn testPingPong(self: *WsConformance) void {
        _ = self;
    }

    pub fn testCompression(self: *WsConformance) void {
        _ = self;
    }
};

/// Source: h2spec HTTP/2 conformance testing tool.
pub const H2Conformance = struct {
    pub fn testHpack(self: *H2Conformance) void {
        _ = self;
    }

    pub fn testStreamMux(self: *H2Conformance) void {
        _ = self;
    }

    pub fn testFlowControl(self: *H2Conformance) void {
        _ = self;
    }

    pub fn testGoaway(self: *H2Conformance) void {
        _ = self;
    }

    pub fn testSettings(self: *H2Conformance) void {
        _ = self;
    }
};

pub const PgConformance = struct {
    pub fn testScramAuth(self: *PgConformance) void {
        _ = self;
    }

    pub fn testMd5Auth(self: *PgConformance) void {
        _ = self;
    }

    pub fn testExtendedQuery(self: *PgConformance) void {
        _ = self;
    }

    pub fn testPreparedStatements(self: *PgConformance) void {
        _ = self;
    }

    pub fn testTypeMapping(self: *PgConformance) void {
        _ = self;
    }
};

test "http conformance chunked encoding" {}

test "http conformance keepalive" {}

test "http conformance pipelining" {}

test "http conformance 100-continue" {}

test "http conformance content-length" {}

test "http conformance method override" {}

test "ws conformance framing" {}

test "ws conformance fragmentation" {}

test "ws conformance utf8" {}

test "ws conformance close" {}

test "ws conformance ping pong" {}

test "ws conformance compression" {}

test "h2 conformance hpack" {}

test "h2 conformance stream mux" {}

test "h2 conformance flow control" {}

test "h2 conformance goaway" {}

test "h2 conformance settings" {}

test "pg conformance scram auth" {}

test "pg conformance md5 auth" {}

test "pg conformance extended query" {}

test "pg conformance prepared statements" {}

test "pg conformance type mapping" {}
