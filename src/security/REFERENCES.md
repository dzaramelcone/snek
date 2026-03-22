# Security Implementation References

State-of-the-art security implementations across high-performance systems languages (C, Rust, Go, Zig).
Research compiled March 2026.

---

## Table of Contents

1. [TLS Implementations](#1-tls-implementations)
2. [JWT Libraries](#2-jwt-libraries)
3. [CORS Implementations](#3-cors-implementations)
4. [CSRF Protection](#4-csrf-protection)
5. [Security Header Injection](#5-security-header-injection)
6. [Rate Limiting Algorithms](#6-rate-limiting-algorithms)
7. [ACME / Let's Encrypt Automation](#7-acme--lets-encrypt-automation)
8. [Certificate Hot-Reloading](#8-certificate-hot-reloading)
9. [mTLS Implementations](#9-mtls-implementations)
10. [SCRAM-SHA-256 Authentication](#10-scram-sha-256-authentication)
11. [Timing-Safe Comparison Functions](#11-timing-safe-comparison-functions)
12. [Secret Management](#12-secret-management)
13. [Request Signing / HMAC](#13-request-signing--hmac)
14. [Content Security Policy Generation](#14-content-security-policy-generation)
15. [OWASP Recommendations for Web Servers](#15-owasp-recommendations-for-web-servers)

---

## 1. TLS Implementations

### 1.1 rustls (Rust)

- **URL:** <https://github.com/rustls/rustls>
- **Language:** Rust
- **Production exposure:** Used by Cloudflare, curl (optional backend), Deno, many Rust web frameworks. Funded by ISRG/Prossimo with full-time development through March 2026.

**Key design decisions:**
- Memory-safe by construction: no C code in the TLS state machine. Eliminates entire classes of CVEs that plague OpenSSL.
- Does NOT implement: export ciphersuites (FREAK/Logjam), CBC mode ciphersuites (POODLE), RSA key exchange (ROBOT/Marvin Attack), SSLv2/SSLv3, or TLS compression (CRIME).
- Delegates cryptographic primitives to `ring` or `aws-lc-rs`, keeping the TLS logic separate from raw crypto.
- Scales nearly linearly with core count; server-side handshake latency roughly 2x lower than OpenSSL in 2025 benchmarks.
- API designed to be hard to misuse: no "insecure renegotiation" knobs.

**CVE history:**
- CVE in rustls 0.23.13: DoS via fragmented ClientHello (panic). Patched quickly.
- Pre-0.16.0: DoS via non-writable client causing event loop. Minor.
- No memory corruption CVEs ever. The design eliminates this by construction.

**Lessons learned:**
- Memory safety removes the most dangerous vulnerability class. The remaining attack surface is logic bugs and DoS, which are far less severe.
- Performance is no longer a valid argument against memory-safe TLS: rustls matches or beats OpenSSL.

### 1.2 OpenSSL (C)

- **URL:** <https://www.openssl.org/> / <https://github.com/openssl/openssl>
- **Language:** C
- **Production exposure:** Ubiquitous. Default TLS on most Linux distributions, used by Apache, nginx, curl, and thousands of other projects.

**Key design decisions:**
- Maximum protocol/cipher coverage for backward compatibility.
- ~500,000 lines of code (vs ~6,000 for s2n-tls, ~20,000 for rustls).
- Extreme flexibility: can be configured securely or insecurely.

**CVE history (selected major incidents):**
- **CVE-2014-0160 (Heartbleed):** Buffer over-read in TLS heartbeat extension. Affected 17% of all SSL servers. Private keys, passwords, session tokens exposed. The defining event that catalyzed the memory-safety movement.
- **CVE-2024-4741:** Use-after-free in `SSL_free_buffers`. Crash or RCE.
- **CVE-2024-12797:** MitM attack on TLS/DTLS when using RFC 7250 raw public keys.
- **CVE-2025-9230, CVE-2025-9231, CVE-2025-9232 (September 2025):** Critical cluster enabling private key recovery, RCE, and DoS.
- 19 vulnerabilities addressed in 2023 alone, 4+ in 2024.

**Lessons learned:**
- Flexibility is a double-edged sword. Most OpenSSL CVEs come from code that exists for backward compatibility with obsolete protocols.
- The sheer size of the codebase makes auditing impractical. Heartbleed went undetected for 2 years.
- Memory-unsafe languages in security-critical code are a systemic risk.

### 1.3 BoringSSL (C/C++/Assembly)

- **URL:** <https://boringssl.googlesource.com/boringssl/>
- **Language:** C, C++, Assembly
- **Production exposure:** Powers Chrome, Android, Cloudflare, Fastly. All Google production services.

**Key design decisions:**
- Fork of OpenSSL created because Google had accumulated 70+ custom patches.
- Aggressively strips legacy code, removes outdated cipher suites.
- Forces modern configurations (opinionated defaults).
- CRYPTO_BUFFER for deduplicating X.509 certificates in memory.
- ML-KEM (post-quantum) variants with ~40% less memory than reference implementations.
- Not intended for general third-party use; no stable API guarantee.

**CVE history:**
- Substantially fewer CVEs than OpenSSL due to reduced attack surface.
- Benefits from Google's fuzzing infrastructure (OSS-Fuzz, ClusterFuzz).

**Lessons learned:**
- Opinionated defaults are better than flexible defaults for security.
- Reducing code surface area is itself a security measure.

### 1.4 s2n-tls (C)

- **URL:** <https://github.com/aws/s2n-tls>
- **Language:** C99
- **Production exposure:** Used across AWS services.

**Key design decisions:**
- Only ~6,000 lines of TLS code (vs OpenSSL's ~500,000). Designed explicitly for auditability.
- State machine is encoded as linearized arrays, completely separated from message parsing. Prevents SMACK-style join-of-state-machines vulnerabilities.
- **Formally verified:** HMAC and DRBG implementations proven correct using Galois SAW (Software Analysis Workbench) against Cryptol specifications.
- **Continuous formal verification:** Proofs are automatically re-established at every code change in CI.
- Uses TCP socket corking for throughput optimization.
- Delegates crypto to OpenSSL libcrypto or AWS-LC.

**CVE history:**
- Very few public CVEs. The formal verification catches many bugs before release.

**Lessons learned:**
- Formal verification in CI is achievable and practical for critical code paths.
- Small code size + formal proofs is the gold standard for C-based security code.
- Even in C, you can achieve high assurance if scope is deliberately limited.

### 1.5 Zig TLS Options

**tls.zig**
- **URL:** <https://github.com/ianic/tls.zig>
- **Language:** Zig
- Supports TLS 1.2/1.3 client and TLS 1.3 server with client authentication.
- Tested against Facebook, eBay, Google Drive, GitHub.
- Pure Zig; no C dependencies.

**boring_tls (Zig + BoringSSL)**
- **URL:** <https://github.com/Thomvanoorschot/boring_tls>
- Memory-safe TLS for Zig built on BoringSSL.
- Client and server implementations.

**iguanaTLS**
- **URL:** <https://github.com/alexnask/iguanaTLS>
- Minimal, experimental TLS 1.2 in Zig.

**Zig stdlib `crypto/tls`**
- **URL:** <https://github.com/ziglang/zig/blob/master/lib/std/crypto/tls.zig>
- TLS 1.3 client in the standard library.
- Minimal, no external dependencies.

**Lessons learned:**
- Zig TLS ecosystem is still maturing. For production, linking BoringSSL via boring_tls is the most battle-tested path.
- Pure-Zig implementations are valuable for embedded/constrained environments where C dependencies are undesirable.

---

## 2. JWT Libraries

### 2.1 jsonwebtoken (Rust)

- **URL:** <https://github.com/Keats/jsonwebtoken>
- **Language:** Rust
- **Production exposure:** Most popular Rust JWT crate. Widely used in production Rust web services.

**Key design decisions:**
- Requires explicit algorithm specification on decode (mitigates algorithm confusion).
- Supports RS256/384/512, ES256/384, HS256/384/512, EdDSA.
- Validation struct forces explicit configuration of expected claims (exp, iss, aud, etc.).

**CVE history:**
- No known CVEs in the Rust crate itself. The Rust type system prevents many vulnerability classes (e.g., null pointer deref, buffer overflow in parsing).

**Lessons learned:**
- Typed algorithm selection at compile time eliminates the "alg: none" and algorithm confusion attack classes entirely.
- This is the model to follow: make insecure configurations unrepresentable.

### 2.2 golang-jwt (Go)

- **URL:** <https://github.com/golang-jwt/jwt>
- **Language:** Go
- **Production exposure:** De facto standard Go JWT library. Used by HashiCorp Vault, Kubernetes, many others.

**Key design decisions:**
- Successor to dgrijalva/jwt-go after the original was abandoned.
- Strict algorithm validation required when parsing.
- Supports custom claims via interfaces.

**CVE history:**
- **CVE-2025-30204:** DoS via excessive memory allocation during header parsing. `ParseUnverified` splits JWT on `.` using `strings.Split`, creating O(n) allocations for inputs with many periods. Fixed in v5.2.2 and v4.5.2.

**Lessons learned:**
- Even in memory-safe languages, algorithmic complexity attacks (ReDoS, allocation bombs) remain a threat.
- `ParseUnverified` functions are inherently dangerous and should carry severe warnings.

### 2.3 jose4j (Java)

- **URL:** <https://bitbucket.org/b_c/jose4j>
- **Language:** Java
- **Production exposure:** Widely used in enterprise Java (Spring Security, OpenSearch, etc.).

**CVE history:**
- **CVE-2023-51775:** DoS via large PBES2 Count (p2c) value causing excessive CPU consumption. Fixed in 0.9.4.
- **RSA1_5 chosen ciphertext attack:** Susceptible to Bleichenbacher-style attack. Fixed in 0.9.3.
- **Elliptic Curve private key disclosure:** Invalid Curve Attack in ECDH-ES. Fixed in 0.5.5.
- **CVE-2026-29000 (pac4j-jwt, downstream):** Authentication bypass in JwtAuthenticator for encrypted JWTs.

**Lessons learned:**
- JWE (encrypted JWT) implementations are dramatically harder to get right than JWS (signed JWT).
- PBES2 without iteration count limits is a DoS vector. Always enforce max iterations.
- RSA1_5 should be avoided entirely in new implementations; use RSA-OAEP or ECDH-ES.

### 2.4 Cross-Cutting JWT Vulnerabilities (2025-2026)

**CVE-2026-22817, CVE-2026-27804, CVE-2026-23552:** Algorithm confusion attacks across multiple frameworks. Root cause: trusting the attacker-controlled `alg` header field.

**Universal mitigation:** ALWAYS specify allowed algorithms server-side. NEVER let the JWT header dictate the verification algorithm.

---

## 3. CORS Implementations

### 3.1 tower-http CorsLayer (Rust)

- **URL:** <https://docs.rs/tower-http/latest/tower_http/cors/>
- **Language:** Rust
- **Production exposure:** Standard CORS middleware for Axum, Tonic, and all Tower-based Rust services.

**Key design decisions:**
- Type-safe origin, method, and header configuration.
- `AllowOrigin::exact()` and `AllowOrigin::predicate()` encourage specific origin configuration.
- CORS layer wraps authentication middleware so OPTIONS preflight requests aren't rejected for missing credentials.
- Integrates with Tower's `Layer`/`Service` abstractions for composability.

**Lessons learned:**
- `.allow_any_origin()` combined with credentials is a well-known misconfiguration. The library should (and does) warn about this.
- CORS must be the outermost middleware to handle preflight before auth rejects the request.

### 3.2 rs/cors (Go)

- **URL:** <https://github.com/rs/cors>
- **Language:** Go
- **Production exposure:** Most popular Go CORS middleware. Used by many production Go services.

**Key design decisions:**
- net/http compatible handler.
- Explicitly blocks the dangerous combination of `AllowedOrigins: *` + `AllowCredentials: true`.
- Debug mode for development, recommended to disable in production.

**CVE/Security issues:**
- Excessive heap allocations when processing malicious preflight requests with many commas in `Access-Control-Request-Headers`. DoS vector.

**Lessons learned:**
- CORS middleware must sanitize/limit the size of request headers to prevent allocation-based DoS.
- Wildcard origins should never be combined with credentials. The library enforces this at runtime.

### 3.3 jub0bs/cors (Go)

- **URL:** <https://github.com/jub0bs/cors>
- **Language:** Go
- Self-described as "perhaps the best CORS middleware library for Go." More opinionated and security-focused than rs/cors.

---

## 4. CSRF Protection

### 4.1 Strategies (Language-Agnostic)

**Synchronizer Token Pattern (stateful):**
- Server generates a unique token per session, stores it server-side.
- Token included in forms/headers, validated on submission.
- Most secure but requires session storage.

**Double Submit Cookie (stateless):**
- Random value sent as both a cookie and a request parameter/header.
- Server verifies they match.
- Stateless but vulnerable if attacker can set cookies (subdomain attacks).

**Signed Double Submit Cookie (recommended stateless approach):**
- Cookie value is HMAC(session_id + random, server_secret).
- Ties token to session, prevents forgery even if attacker can read cookies.
- OWASP-recommended for stateless architectures.

**SameSite Cookie Attribute:**
- `SameSite=Strict` or `SameSite=Lax` prevents cookies from being sent on cross-site requests.
- Defense-in-depth; should not be sole CSRF protection.

**Custom Request Header:**
- Require a custom header (e.g., `X-Requested-With`) on state-changing requests.
- Browsers prevent cross-origin requests from setting custom headers without CORS preflight.
- Simple and effective for API-only services.

### 4.2 Key Reference

- **OWASP CSRF Prevention Cheat Sheet:** <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- **csrf-csrf (Node.js reference impl):** <https://github.com/Psifi-Solutions/csrf-csrf>

**Lessons learned:**
- Double submit without HMAC signing is insufficient if attacker controls any subdomain.
- SameSite cookies are defense-in-depth, not a replacement for tokens.
- CSRF protection is irrelevant for pure token-based auth (Bearer tokens) since the browser never automatically attaches them. Only cookie-based auth needs CSRF protection.

---

## 5. Security Header Injection

### 5.1 Helmet.js (Node.js - Reference Implementation)

- **URL:** <https://helmetjs.github.io/> / <https://github.com/helmetjs/helmet>
- **Language:** JavaScript/TypeScript
- Sets 13 HTTP security response headers with sensible defaults.

### 5.2 helmet-core / axum-helmet (Rust)

- **URL:** <https://docs.rs/helmet-core> / <https://github.com/danielkov/rust-helmet>
- **Language:** Rust
- Port of Helmet.js for Rust web frameworks.
- Adapters for Axum (`axum-helmet`) and ntex (`ntex-helmet`).
- Highly configurable via builder pattern.

### 5.3 goddtriffin/helmet (Go)

- **URL:** <https://github.com/goddtriffin/helmet>
- **Language:** Go
- Collection of 12 security middleware functions inspired by Helmet.js.

### 5.4 Recommended Security Headers

| Header | Purpose | OWASP Recommendation |
|--------|---------|---------------------|
| `Strict-Transport-Security` | Force HTTPS | `max-age=31536000; includeSubDomains; preload` |
| `Content-Security-Policy` | Prevent XSS, injection | See [CSP section](#14-content-security-policy-generation) |
| `X-Content-Type-Options` | Prevent MIME sniffing | `nosniff` |
| `X-Frame-Options` | Prevent clickjacking | `DENY` or `SAMEORIGIN` |
| `Referrer-Policy` | Control referrer leaks | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | Disable browser features | Restrict camera, mic, geolocation, etc. |
| `Cross-Origin-Opener-Policy` | Isolate browsing context | `same-origin` |
| `Cross-Origin-Embedder-Policy` | Require CORP | `require-corp` |
| `Cross-Origin-Resource-Policy` | Restrict resource loading | `same-origin` |
| `X-Permitted-Cross-Domain-Policies` | Restrict Flash/PDF | `none` |
| `Cache-Control` | Prevent caching sensitive data | `no-store` for sensitive responses |

**Headers to REMOVE:**
- `X-Powered-By` — information disclosure
- `Server` — information disclosure (or set to generic value)

**Lessons learned:**
- Headers are defense-in-depth. They do not replace secure code but significantly raise the bar for exploitation.
- `X-XSS-Protection` is now deprecated by OWASP. Modern browsers have removed their XSS auditors. Use CSP instead.

---

## 6. Rate Limiting Algorithms

### 6.1 Token Bucket

**How it works:** Bucket holds tokens; requests consume tokens. Tokens refill at a fixed rate up to a max capacity.

**Trade-offs:**
- Allows bursts up to bucket capacity while enforcing long-term average.
- Only needs to store: current token count + last refill timestamp.
- Best general-purpose algorithm for APIs.

### 6.2 Leaky Bucket

**How it works:** Requests enter a FIFO queue (bucket). Processed at a constant rate. Overflow is discarded.

**Trade-offs:**
- Smooths bursty traffic to constant output rate.
- Cannot accommodate legitimate traffic spikes.
- Good for: network shaping, protecting downstream services with strict capacity.

### 6.3 Sliding Window Log

**How it works:** Maintains timestamp log of each request. Counts requests in the trailing window.

**Trade-offs:**
- Most accurate: no boundary effects.
- Memory-intensive: stores one timestamp per request per client.
- Good for: low-volume, high-precision rate limiting.

### 6.4 Sliding Window Counter (Hybrid)

**How it works:** Combines fixed windows with weighted average across the boundary.

**Trade-offs:**
- Less memory than log, more accurate than fixed window.
- Best balance for most production use cases.

### 6.5 Generic Cell Rate Algorithm (GCRA)

**How it works:** Theoretical arrival time tracking. Used by `governor` crate.

**Trade-offs:**
- Single timestamp storage per key.
- Mathematically equivalent to leaky bucket but more elegant.
- Used in ATM networks, now adopted for HTTP rate limiting.

### 6.6 Implementations

**governor (Rust)**
- **URL:** <https://github.com/boinkor-net/governor>
- Implements GCRA. High-performance, production-ready.
- Lock-free, designed for concurrent use.

**tower_governor (Rust)**
- **URL:** <https://github.com/benwis/tower-governor>
- Tower middleware wrapper around `governor`.
- Key extraction: peer IP, X-Forwarded-For, X-Real-IP, custom keys.
- Must use `.into_make_service_with_connect_info::<SocketAddr>` for IP extraction.

**uber-go/ratelimit (Go)**
- **URL:** <https://github.com/uber-go/ratelimit>
- Leaky bucket implementation. Minimal API: `Take()` blocks until allowed.
- Supports "slack" for accumulated unused capacity.

**tollbooth (Go)**
- **URL:** <https://github.com/didip/tollbooth>
- HTTP middleware using token bucket (via `x/time/rate`).
- Fixed RemoteIP vulnerability by replacing `SetIPLookups` with `SetIPLookup`.

**Lessons learned:**
- IP-based rate limiting is easily circumvented by distributed attackers. Layer with authentication-based limits.
- Trust `X-Forwarded-For` only if you control the reverse proxy. Otherwise, use peer IP.
- Rate limit headers (`RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`) help legitimate clients self-throttle. Use them.

---

## 7. ACME / Let's Encrypt Automation

### 7.1 certmagic (Go)

- **URL:** <https://github.com/caddyserver/certmagic>
- **Language:** Go
- **Production exposure:** Core of Caddy server. Millions of sites. In production since before Let's Encrypt public beta (2015).

**Key design decisions:**
- One line of code for fully-automated HTTPS with HTTP->HTTPS redirects.
- Works behind load balancers and in cluster/fleet environments (1 to 1,000+ servers).
- Supports On-Demand TLS (provision certificates at request time).
- OCSP stapling and automatic renewal.
- When ACME CAs had outages, Caddy was sometimes the only client that didn't experience downtime.

**Lessons learned:**
- The gold standard for ACME automation. Any implementation should study certmagic's approach to error recovery and OCSP handling.

### 7.2 lego (Go)

- **URL:** <https://github.com/go-acme/lego>
- **Language:** Go
- ACME v2 client and library. ~180 DNS providers supported.
- 10 years of maintenance. Underlies certmagic.

### 7.3 instant-acme (Rust)

- **URL:** <https://github.com/InstantDomain/instant-acme>
- **Language:** Rust
- Async, pure-Rust ACME (RFC 8555) client on tokio + rustls.
- Used in production at Instant Domain Search.
- Supports: ARI, profiles, external account binding, key rollover, certificate revocation.
- ~73K downloads/month.

### 7.4 rustls-acme (Rust)

- **URL:** <https://docs.rs/rustls-acme>
- **Language:** Rust
- Automatic TLS certificate management using rustls. Higher-level than instant-acme.

### 7.5 certbot (Python)

- **URL:** <https://github.com/certbot/certbot>
- **Language:** Python
- EFF's original Let's Encrypt client. Not embeddable as a library.
- Best for standalone server certificate management, not for embedding in application code.

### 7.6 Go autocert (Go stdlib)

- **URL:** <https://pkg.go.dev/golang.org/x/crypto/acme/autocert>
- Minimal ACME client in Go extended standard library.
- certmagic is the recommended upgrade path for production use.

**Lessons learned:**
- ACME automation should handle: rate limits, CAA records, DNS propagation delays, OCSP stapling, and graceful certificate rotation.
- On-Demand TLS is powerful but must be gated (allowlist) to prevent abuse (attacker triggering certificate issuance for arbitrary domains).

---

## 8. Certificate Hot-Reloading

### 8.1 tls-hot-reload (Rust)

- **URL:** <https://github.com/sebadob/tls-hot-reload>
- **Language:** Rust
- Wait-free and lock-free TLS certificate hot-reload for rustls.
- Spawns file watchers that detect modifications and reload certificates without service interruption.
- Minimal overhead: no internal locking on certificate resolution.

### 8.2 certman (Go)

- **URL:** <https://github.com/dyson/certman>
- **Language:** Go
- Watches certificate and key files for changes, reloads on modification.
- Uses Go's `tls.Config.GetCertificate` callback.

### 8.3 ghostunnel/certloader (Go)

- **URL:** <https://pkg.go.dev/github.com/ghostunnel/ghostunnel/certloader>
- **Language:** Go
- Supports PEM files, PKCS#12 keystores, PKCS#11 hardware modules, macOS Keychain.
- Production-grade: used by Ghostunnel (Square).

### 8.4 Standard Go Pattern

```
// Use GetCertificate callback for hot-reloading
tlsConfig := &tls.Config{
    GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
        return tls.LoadX509KeyPair(certFile, keyFile)
    },
}
```

**Lessons learned:**
- Lock-free/wait-free reload is critical for high-throughput servers. Mutex-based reload causes latency spikes.
- File watching (inotify/kqueue) is more responsive than polling.
- Always validate the new certificate before swapping. A malformed cert should not take down TLS.

---

## 9. mTLS Implementations

### 9.1 Design Principles

- Both client and server present certificates; both verify the other.
- Commonly used for service-to-service communication (zero-trust networks).
- Server sets `tls.RequireAndVerifyClientCert` (Go) or equivalent.

### 9.2 Go mTLS

- **URL:** <https://github.com/haoel/mTLS> (example)
- Standard library `crypto/tls` has full mTLS support.
- Set `ClientAuth: tls.RequireAndVerifyClientCert` and `ClientCAs` pool.
- Minimum TLS 1.2; prefer 1.3.

### 9.3 Rust mTLS

- **URL:** <https://github.com/camelop/rust-mtls-example>
- rustls has full mTLS support via `ClientCertVerifier` trait.
- Can use either native-tls or rustls backends.

### 9.4 Production Best Practices

- Use a private CA for mTLS certificates (not public CAs).
- Automate issuance, renewal, and revocation (consider SPIFFE/SPIRE).
- Never use self-signed certificates in production.
- Implement certificate revocation checking (CRL or OCSP).
- Store private keys in HSMs or secure enclaves where possible.

**Lessons learned:**
- mTLS certificate lifecycle management is the hard part, not the TLS handshake itself.
- SPIFFE/SPIRE or similar identity frameworks (Istio, Linkerd) handle the lifecycle automatically.
- Client certificate validation must check: expiry, revocation, CA chain, and expected identity (SAN/CN).

---

## 10. SCRAM-SHA-256 Authentication

### 10.1 Overview

SCRAM (Salted Challenge Response Authentication Mechanism) per RFC 5802 and RFC 7677. Provides mutual authentication without transmitting the password.

**How it works:**
1. Client sends username + nonce.
2. Server responds with salt, iteration count, server nonce.
3. Client computes `SaltedPassword = PBKDF2(password, salt, iterations)`, derives `ClientKey` and `StoredKey`.
4. Client sends proof. Server verifies. Server sends its own proof. Client verifies.
5. Neither side ever sees the other's password.

### 10.2 Rust Implementations

**scram crate**
- **URL:** <https://docs.rs/scram>
- Implements SCRAM-SHA-256 per RFC 5802/7677.
- Does NOT support channel binding (limits protection against MitM).

**rustbase/scram**
- **URL:** <https://github.com/rustbase/scram>
- Client and server implementations.

### 10.3 Go Implementations

**xdg/scram**
- **URL:** <https://pkg.go.dev/github.com/xdg/scram>
- Default minimum PBKDF2 iteration count of 4096.
- Errors if server requests fewer iterations (security protection).

**franz-go/pkg/sasl/scram**
- **URL:** <https://pkg.go.dev/github.com/twmb/franz-go/pkg/sasl/scram>
- SCRAM for Kafka authentication.

### 10.4 C Implementation

**GNU SASL (gsasl)**
- **URL:** <https://www.gnu.org/software/gsasl/>
- Full SASL framework including SCRAM-SHA-256.

**Lessons learned:**
- Channel binding (SCRAM-SHA-256-PLUS with `tls-server-end-point` or `tls-unique`) is critical for preventing MitM attacks. Without it, SCRAM is vulnerable to relay attacks.
- Minimum PBKDF2 iterations should be enforced client-side (4096 minimum, 10000+ recommended as of 2026).
- Store only `StoredKey` and `ServerKey` (never `SaltedPassword`) to limit damage from database compromise.

---

## 11. Timing-Safe Comparison Functions

### 11.1 The Problem

Standard string/byte comparison short-circuits on first mismatch. Timing difference leaks information about how many leading bytes match, enabling byte-by-byte secret recovery.

### 11.2 Go: crypto/subtle

- **URL:** <https://pkg.go.dev/crypto/subtle>
- `ConstantTimeCompare(x, y []byte) int` — returns 1 if equal, 0 if not.
- Uses bitwise XOR accumulation. Does NOT hide length information.
- For passwords: compare fixed-length hashes, not raw passwords.

### 11.3 Rust: subtle crate (dalek-cryptography)

- **URL:** <https://github.com/dalek-cryptography/subtle>
- `ConstantTimeEq` trait returns `Choice` (not `bool`) to prevent accidental branching on the result.
- Uses volatile reads to prevent compiler optimization of constant-time code back into branches.
- `Choice` type makes it harder to accidentally use the result in a non-constant-time branch.

**Key design insight:** Returning `Choice` instead of `bool` is brilliant. It forces the caller to explicitly convert to a boolean, making timing-unsafe usage syntactically obvious.

### 11.4 Go: consistenttime equivalent

- Go's `crypto/subtle` is the standard. The `subtle` Rust crate was modeled after it.

### 11.5 C

- OpenSSL: `CRYPTO_memcmp()`
- libsodium: `sodium_memcmp()`
- Both use volatile or assembly barriers to prevent optimization.

**Lessons learned:**
- The compiler is your enemy here. It can and will optimize constant-time code into branches unless you use volatile reads, inline assembly, or compiler barriers.
- Length information leaks are acceptable when comparing fixed-length hashes (which you should always be doing).
- The Rust `Choice` type pattern (algebraic type instead of boolean) should be adopted by any new implementation.

---

## 12. Secret Management

### 12.1 In-Process Secret Storage

**secret-vault-rs (Rust)**
- **URL:** <https://github.com/abdolence/secret-vault-rs>
- Memory-backed storage with optional envelope encryption via Google/AWS KMS.
- Automatic secret refresh from external sources.
- Memory zeroization on drop.
- Snapshot support for performance-critical secrets (pre-decrypted).

**zeroize crate (Rust)**
- **URL:** <https://docs.rs/zeroize>
- Securely zeros memory on drop using stable Rust primitives that guarantee the operation won't be optimized away.
- Essential for any secret held in memory.

**secrets crate (Rust)**
- **URL:** <https://docs.rs/secrets>
- `mlock()`-protected memory pages, guard pages, `mprotect()` access controls.
- Prevents secrets from being swapped to disk.

### 12.2 External Secret Management

**HashiCorp Vault / OpenBao**
- **URL:** <https://www.vaultproject.io/> / <https://github.com/openbao/openbao>
- Dynamic secrets, lease-based access, audit logging.
- HashiCorp moved to BSL; OpenBao is the open-source fork.

**SOPS (Secrets OPerationS)**
- **URL:** <https://github.com/getsops/sops>
- Encrypts secrets in-place in YAML/JSON/ENV/INI files.
- Supports AWS KMS, GCP KMS, Azure Key Vault, age, PGP.
- Git-friendly: diffs show which keys changed, not values.

**Infisical**
- **URL:** <https://infisical.com/>
- Open-source secret management platform. MIT licensed.
- SDKs for many languages. Growing fast as Vault alternative.

### 12.3 Configuration Best Practices

- Never store secrets in source code or version control.
- Use envelope encryption: encrypt secrets with a DEK, encrypt the DEK with a KEK from KMS.
- Zeroize secrets in memory immediately after use.
- Use `mlock()` to prevent secrets from being swapped to disk.
- Rotate secrets automatically. Short-lived credentials > long-lived secrets.
- Audit all secret access.

**Lessons learned:**
- The biggest secret management failures are organizational, not technical: hardcoded credentials, secrets in git history, shared API keys.
- SOPS + age is the simplest secure approach for small teams.
- For Rust specifically: `zeroize` + `secrecy` crates should be used for any secret value.

---

## 13. Request Signing / HMAC

### 13.1 How HMAC Request Signing Works

1. Client and server share a secret key (never transmitted).
2. Client constructs a canonical string from the request (method, path, timestamp, body hash).
3. Client computes `HMAC-SHA256(canonical_string, secret_key)` and sends it in a header.
4. Server reconstructs the canonical string and verifies the HMAC.
5. If match: request is authentic and unmodified.

### 13.2 Rust Implementations

**ring::hmac**
- **URL:** <https://docs.rs/ring/latest/ring/hmac/>
- Part of the `ring` crate (334M+ downloads). Battle-tested.
- `Key`, `sign()`, `verify()` API.

**hmac crate (RustCrypto)**
- **URL:** <https://docs.rs/hmac>
- Pure-Rust HMAC. Two implementations: `Hmac` (with ipad/opad caching) and `SimpleHmac`.

**iron-hmac (Rust/Iron framework)**
- **URL:** <https://docs.rs/iron-hmac>
- BeforeMiddleware for verifying, AfterMiddleware for signing.

### 13.3 Go Implementation

- Standard library: `crypto/hmac` + `crypto/sha256`.
- **Critical:** Always use `hmac.Equal()` instead of `==`. Standard comparison leaks timing information.

### 13.4 Acquia HTTP HMAC Spec

- **URL:** <https://github.com/acquia/http-hmac-spec>
- Formal specification for HMAC-based HTTP authentication.
- Defines canonical request format, header placement, version negotiation.

### 13.5 Best Practices

- Include a timestamp in the signed message. Reject requests older than 5 minutes (clock skew tolerance).
- Include the request body hash to prevent body tampering.
- Use HMAC-SHA256 or stronger. Never SHA1/MD5.
- Store keys in environment variables or secrets manager.
- Log failed verification attempts for intrusion detection.

---

## 14. Content Security Policy Generation

### 14.1 Rust Libraries

**csp crate**
- **URL:** <https://docs.rs/csp>
- Typed structure-based CSP builder. Makes typos in directive names impossible.

**content-security-policy crate**
- **URL:** <https://docs.rs/content-security-policy>
- Parses CSP strings into data structures. Useful for validation/modification.

**CSP-rs**
- **URL:** <https://github.com/l-2-j/CSP-rs>
- Minimal, zero-dependency crate for CSP string construction.

### 14.2 Go Libraries

**go.bryk.io/pkg/net/csp**
- **URL:** <https://pkg.go.dev/go.bryk.io/pkg/net/csp>
- CSP builder with nonce generation per request.

### 14.3 CSP Best Practices (OWASP)

- **Reference:** <https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html>

**Recommended starter policy:**
```
Content-Security-Policy:
  default-src 'none';
  script-src 'self' 'nonce-{random}';
  style-src 'self' 'nonce-{random}';
  img-src 'self';
  font-src 'self';
  connect-src 'self';
  frame-ancestors 'none';
  base-uri 'self';
  form-action 'self';
  upgrade-insecure-requests;
```

**Key directives:**
- `default-src 'none'` — deny-by-default.
- Nonce-based script/style loading instead of `'unsafe-inline'`.
- `frame-ancestors 'none'` — replaces X-Frame-Options.
- `base-uri 'self'` — prevents `<base>` tag injection.
- `form-action 'self'` — prevents form submission to foreign origins.
- `upgrade-insecure-requests` — auto-upgrades HTTP resources to HTTPS.

**Lessons learned:**
- `'unsafe-inline'` and `'unsafe-eval'` negate most XSS protection from CSP. Avoid them.
- Nonce-based CSP requires generating a cryptographically random nonce per response. This is the modern best practice.
- `report-uri` / `report-to` directives are invaluable for discovering violations before enforcing a strict policy.
- Start with `Content-Security-Policy-Report-Only` to collect violations without breaking the site.

---

## 15. OWASP Recommendations for Web Servers

### 15.1 Key References

- **OWASP Secure Headers Project:** <https://owasp.org/www-project-secure-headers/>
- **HTTP Headers Cheat Sheet:** <https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html>
- **REST Security Cheat Sheet:** <https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html>
- **CSRF Prevention:** <https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html>
- **CSP Cheat Sheet:** <https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html>

### 15.2 OWASP Top 10 (2025 Edition)

1. **Broken Access Control** — enforce server-side, deny by default
2. **Cryptographic Failures** — encrypt data in transit and at rest, use strong algorithms
3. **Injection** — parameterized queries, input validation, output encoding
4. **Insecure Design** — threat modeling, secure design patterns
5. **Security Misconfiguration** — remove defaults, disable unnecessary features, set security headers
6. **Vulnerable Components** — track dependencies, update promptly
7. **Authentication Failures** — MFA, rate limiting, secure password storage
8. **Software/Data Integrity Failures** — verify updates, use SRI, sign artifacts
9. **Logging/Monitoring Failures** — log security events, alert on anomalies
10. **SSRF** — validate/sanitize all URLs, use allowlists

### 15.3 Web Server Hardening Checklist

**Transport:**
- [ ] TLS 1.2+ only (prefer 1.3)
- [ ] HSTS with `includeSubDomains` and `preload`
- [ ] OCSP stapling enabled
- [ ] Certificate transparency monitoring

**Headers:**
- [ ] All headers from [Section 5.4](#54-recommended-security-headers) table
- [ ] Remove `Server`, `X-Powered-By`
- [ ] CSP with nonce-based script loading

**Input:**
- [ ] Request size limits
- [ ] Rate limiting (see [Section 6](#6-rate-limiting-algorithms))
- [ ] Request timeout enforcement
- [ ] Path traversal prevention
- [ ] Host header validation

**Authentication:**
- [ ] Timing-safe credential comparison
- [ ] Account lockout / rate limiting on failed auth
- [ ] Secure session management (HttpOnly, Secure, SameSite cookies)
- [ ] Password hashing with Argon2id or bcrypt

**Error Handling:**
- [ ] Generic error messages to clients
- [ ] Detailed errors only in server logs
- [ ] No stack traces in production responses

**Logging:**
- [ ] Log all authentication events
- [ ] Log all access control failures
- [ ] Log all input validation failures
- [ ] Structured logging with request correlation IDs
- [ ] Do NOT log secrets, passwords, tokens, or PII

---

## Appendix: Summary of Production-Ready Libraries by Language

### Rust
| Concern | Library | URL |
|---------|---------|-----|
| TLS | rustls | <https://github.com/rustls/rustls> |
| Crypto primitives | ring | <https://github.com/briansmith/ring> |
| JWT | jsonwebtoken | <https://github.com/Keats/jsonwebtoken> |
| CORS | tower-http CorsLayer | <https://docs.rs/tower-http/latest/tower_http/cors/> |
| Security headers | helmet-core / axum-helmet | <https://docs.rs/helmet-core> |
| Rate limiting | governor + tower_governor | <https://github.com/boinkor-net/governor> |
| ACME | instant-acme / rustls-acme | <https://github.com/InstantDomain/instant-acme> |
| Cert hot-reload | tls-hot-reload | <https://github.com/sebadob/tls-hot-reload> |
| Timing-safe compare | subtle | <https://github.com/dalek-cryptography/subtle> |
| HMAC | ring::hmac / hmac crate | <https://docs.rs/ring/latest/ring/hmac/> |
| Secret zeroization | zeroize | <https://docs.rs/zeroize> |
| Secret storage | secret-vault-rs | <https://github.com/abdolence/secret-vault-rs> |
| SCRAM | scram | <https://docs.rs/scram> |
| CSP | csp | <https://docs.rs/csp> |

### Go
| Concern | Library | URL |
|---------|---------|-----|
| TLS | crypto/tls (stdlib) | <https://pkg.go.dev/crypto/tls> |
| JWT | golang-jwt | <https://github.com/golang-jwt/jwt> |
| CORS | rs/cors | <https://github.com/rs/cors> |
| Security headers | goddtriffin/helmet | <https://github.com/goddtriffin/helmet> |
| Rate limiting | uber-go/ratelimit, tollbooth | <https://github.com/uber-go/ratelimit> |
| ACME | certmagic, lego | <https://github.com/caddyserver/certmagic> |
| Cert hot-reload | certman, ghostunnel/certloader | <https://github.com/dyson/certman> |
| Timing-safe compare | crypto/subtle | <https://pkg.go.dev/crypto/subtle> |
| HMAC | crypto/hmac | <https://pkg.go.dev/crypto/hmac> |
| SCRAM | xdg/scram | <https://pkg.go.dev/github.com/xdg/scram> |

### C
| Concern | Library | URL |
|---------|---------|-----|
| TLS | OpenSSL / s2n-tls / BoringSSL | <https://www.openssl.org/> |
| Timing-safe compare | CRYPTO_memcmp / sodium_memcmp | libsodium |
| SASL/SCRAM | GNU SASL (gsasl) | <https://www.gnu.org/software/gsasl/> |

### Zig
| Concern | Library | URL |
|---------|---------|-----|
| TLS | tls.zig / boring_tls / std crypto/tls | <https://github.com/ianic/tls.zig> |
| TLS (via C) | openssl-zig | <https://github.com/kassane/openssl-zig> |

---

## Appendix: Key Takeaways

1. **Memory safety eliminates the most dangerous vulnerability class.** Rustls has zero memory corruption CVEs; OpenSSL has had dozens including Heartbleed. For new projects, memory-safe TLS is not optional.

2. **Formal verification is practical.** AWS proves s2n-tls correct continuously in CI. This is the standard to aspire to for critical security code.

3. **Opinionated defaults beat flexible defaults.** BoringSSL, rustls, and well-designed JWT libraries make insecure configurations impossible or difficult. Secure-by-default > configurable.

4. **The JWT `alg` header is the most exploited field in web security.** Every JWT implementation must enforce server-side algorithm selection. This is non-negotiable.

5. **Rate limiting is necessary but insufficient.** IP-based rate limiting is trivially circumvented. Layer with authentication-based limits and behavioral analysis.

6. **Secret lifecycle management is harder than secret storage.** Automate rotation, use short-lived credentials, zeroize memory, and audit access.

7. **ACME automation is solved.** certmagic (Go) and instant-acme (Rust) are production-ready. Manual certificate management is unnecessary risk.

8. **CSP with nonces is the modern XSS defense.** `unsafe-inline` negates CSP. Start with report-only mode, deploy strict nonce-based policies.

9. **Timing attacks are real and measurable.** Always use constant-time comparison for any security-sensitive comparison. The Rust `subtle` crate's `Choice` type is the best API design for this.

10. **Defense in depth is not optional.** Security headers, CSP, CORS, CSRF tokens, rate limiting, and TLS are all layers. No single layer is sufficient.


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a950b3eae24d1d111.jsonl`
