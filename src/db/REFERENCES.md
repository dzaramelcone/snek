# PostgreSQL Driver & Connection Pooling: State of the Art Reference

Exhaustive research into Postgres wire protocol implementations, drivers, connection
poolers, and associated systems across high-performance languages. Compiled March 2026.

---

## Table of Contents

1. [PostgreSQL Wire Protocol v3](#1-postgresql-wire-protocol-v3)
2. [Driver Implementations](#2-driver-implementations)
   - [pgx (Go)](#21-pgx-go)
   - [asyncpg (Python/Cython)](#22-asyncpg-pythoncython)
   - [tokio-postgres (Rust)](#23-tokio-postgres-rust)
   - [pg.zig (Zig)](#24-pgzig-zig)
   - [pgz (Zig)](#25-pgz-zig)
   - [Odin](#26-odin)
   - [psycopg3 (Python)](#27-psycopg3-python)
3. [Wire Protocol Libraries (Server-Side)](#3-wire-protocol-libraries-server-side)
   - [pgwire (Rust)](#31-pgwire-rust)
   - [pgproto3 (Go)](#32-pgproto3-go)
   - [psql-wire (Go)](#33-psql-wire-go)
4. [Connection Poolers & Proxies](#4-connection-poolers--proxies)
   - [PgBouncer](#41-pgbouncer)
   - [PgCat (Rust)](#42-pgcat-rust)
   - [Supavisor (Elixir)](#43-supavisor-elixir)
5. [Connection Pool Libraries](#5-connection-pool-libraries)
   - [deadpool-postgres (Rust)](#51-deadpool-postgres-rust)
   - [pgxpool (Go)](#52-pgxpool-go)
   - [HikariCP (Java) — Design Reference](#53-hikaricp-java--design-reference)
6. [libpq: Lessons Learned & What to Avoid](#6-libpq-lessons-learned--what-to-avoid)
7. [SCRAM-SHA-256 Authentication](#7-scram-sha-256-authentication)
8. [Prepared Statement Caching](#8-prepared-statement-caching)
9. [Pipeline Mode (Protocol Pipelining)](#9-pipeline-mode-protocol-pipelining)
10. [Binary vs Text Format](#10-binary-vs-text-format)
11. [Type OID Mapping Strategies](#11-type-oid-mapping-strategies)
12. [Zero-Copy Result Parsing](#12-zero-copy-result-parsing)
13. [Connection Health Checking](#13-connection-health-checking)
14. [Pool Sizing Algorithms & Queue Theory](#14-pool-sizing-algorithms--queue-theory)
15. [DBAPI 2.0 (PEP 249) Compliance](#15-dbapi-20-pep-249-compliance)
16. [PostgreSQL Wire Compatibility Ecosystem](#16-postgresql-wire-compatibility-ecosystem)
17. [Research Papers & Deep References](#17-research-papers--deep-references)

---

## 1. PostgreSQL Wire Protocol v3

**Official Docs**: https://www.postgresql.org/docs/current/protocol.html

### Protocol Structure

The protocol is binary, big-endian. Messages consist of:
- 1-byte type identifier (frontend messages omit this for StartupMessage)
- 4-byte length (includes itself, excludes type byte)
- Payload bytes

### Message Flow Phases

1. **Startup**: SSL negotiation -> StartupMessage (protocol version 196608 = 3.0) -> Authentication -> ParameterStatus* -> BackendKeyData -> ReadyForQuery
2. **Simple Query**: Query('Q') -> RowDescription('T') -> DataRow('D')* -> CommandComplete('C') -> ReadyForQuery('Z')
3. **Extended Query**: Parse('P') -> Bind('B') -> Describe('D') -> Execute('E') -> Sync('S') -> ParseComplete('1') -> BindComplete('2') -> RowDescription('T') -> DataRow('D')* -> CommandComplete('C') -> ReadyForQuery('Z')
4. **Copy**: CopyInResponse/CopyOutResponse -> CopyData* -> CopyDone/CopyFail
5. **Cancellation**: Separate TCP connection with CancelRequest (process ID + secret key)

### Key Message Types

| Byte | Name | Direction | Purpose |
|------|------|-----------|---------|
| `R`  | Authentication | B->F | Auth challenge/OK |
| `K`  | BackendKeyData | B->F | PID + secret for cancel |
| `Z`  | ReadyForQuery | B->F | Transaction status (I/T/E) |
| `Q`  | Query | F->B | Simple query text |
| `P`  | Parse | F->B | Prepare statement |
| `B`  | Bind | F->B | Bind parameters to portal |
| `E`  | Execute | F->B | Execute portal |
| `S`  | Sync | F->B | Sync point |
| `H`  | Flush | F->B | Request immediate responses |
| `T`  | RowDescription | B->F | Column metadata + type OIDs |
| `D`  | DataRow | B->F | Row values |
| `C`  | CommandComplete | B->F | "SELECT 42" / "INSERT 0 1" |
| `X`  | Terminate | F->B | Graceful close |

### Implementation from Scratch — Key Resources

- **Java 21 tutorial**: https://gavinray97.github.io/blog/postgres-wire-protocol-jdk-21
  - Demonstrates full message parsing using sealed interfaces, records, pattern matching
  - Shows MemorySegment API for zero-copy buffer handling
  - Covers SSL negotiation, auth flow, query execution
- **Python gist**: https://gist.github.com/fantix/c2ddb24b636fb132093a958b08b43665
  - Minimal wire protocol implementation showing exact byte sequences
- **PostgreSQL wiki — Driver Development**: https://wiki.postgresql.org/wiki/Driver_development
  - Official guidance: "Stick to the libpq API closely," support explicit resource cleanup, defer type conversions to higher layers

---

## 2. Driver Implementations

### 2.1 pgx (Go)

- **URL**: https://github.com/jackc/pgx
- **Language**: Pure Go
- **License**: MIT
- **Status**: Best-in-class Go PostgreSQL driver. Actively maintained. Targets Go 1.25+, PostgreSQL 14+.

#### Architecture (Layered)

```
pgx.Conn          — high-level driver, ~70 type conversions, LISTEN/NOTIFY, COPY
  pgconn           — low-level connection, roughly equivalent to libpq
    pgproto3       — standalone wire protocol v3 encoding/decoding
  pgtype           — type mapping system (PostgreSQL <-> Go)
  pgxpool          — connection pool with after-connect hooks
  stdlib           — database/sql adapter
  tracelog          — tracing/logging
  pglogrepl        — logical replication client
  pgmock           — wire protocol mock server for testing
```

#### Key Design Decisions

- **Binary format by default** for all supported types — avoids text parsing overhead
- **Automatic prepared statement caching** — transparent to caller, massive perf win for repeated queries
- **Separate native and database/sql interfaces** — native interface avoids database/sql overhead (5-37% faster)
- **pgproto3 as standalone package** — enables building proxies, load balancers, replication clients
- **Single-round-trip query mode** for simple queries

#### Benchmark Data

| Operation | pgx native (ns/op) | pgx stdlib (ns/op) | lib/pq (ns/op) |
|-----------|--------------------|--------------------|-----------------|
| Select 1 row, 8 cols | 31,148 | 39,617 | 47,033 |
| Bulk COPY (10M rows) | 214,869 rows/s | — | 95,665 rows/s (lib/pq) |

- pgx outperforms lib/pq by 2x+ on COPY workloads
- Automatic statement caching provides ~3x QPS improvement for repeated queries
- Binary format parsing of arrays and complex types significantly faster than text

#### Production Exposure

Widely used across the Go ecosystem. lib/pq maintainers recommend switching to pgx. Used by CockroachDB test infrastructure.

#### Lessons

- database/sql interface adds measurable overhead (allocations, reflection)
- Binary format is a clear win for numeric/timestamp/array types
- Pool after-connect hooks enable per-connection setup (SET statements, prepared statements)

**Reference talk**: "PGX Top to Bottom" — Golang Estonia presentation on architecture

---

### 2.2 asyncpg (Python/Cython)

- **URL**: https://github.com/MagicStack/asyncpg
- **Language**: Python (67.8%), Cython (21.8%), C++ (6.7%), C (3.6%)
- **License**: Apache 2.0
- **Status**: 8,000+ stars, 97,000+ dependents. Production-grade.

#### Architecture

- **Native PostgreSQL binary protocol** implementation — no libpq dependency
- Parsing and Record construction in Cython/C for maximum throughput
- Tight buffer management with optimized data decoding pipeline
- asyncio-native (no thread pool fallbacks)

#### Key Design Decisions

- **Not DB-API 2.0 compliant** — deliberately exposes PostgreSQL features directly rather than hiding behind generic facade
- **Binary I/O protocol exclusively** — avoids text serialization overhead, enables generic container type handling
- **Prepared statement caching** — caches entire data I/O pipeline per prepared statement
- **Zero external dependencies** — pure pip install with binary wheels

#### Benchmark Data

- **5x faster than psycopg3** on average (June 2023 benchmarks)
- **3x faster than psycopg2** (optimized C) on average
- **1M+ rows/second** from PostgreSQL to Python (single-threaded, with uvloop)

Benchmark scenarios:
- Wide rows (~350 cols from pg_type): asyncpg dominates due to binary decoding
- 1,000 integer rows: significant advantage from avoiding text parsing
- Binary blobs (100 rows x 1KB): reduced serialization overhead
- Array decoding (100 rows x 100 ints): binary format orders of magnitude faster

#### Production Exposure

Used by EdgeDB/Gel, Sentry (100x API optimization), and thousands of production deployments.

#### Lessons

- Implementing protocol natively in Cython yields massive performance gains over C library wrapping
- Binary protocol eliminates entire classes of parsing overhead
- Caching the full I/O pipeline (not just the prepared statement handle) is the key optimization

**Reference**: https://www.geldata.com/blog/m-rows-s-from-postgres-to-python

---

### 2.3 tokio-postgres (Rust)

- **URL**: https://github.com/sfackler/rust-postgres
- **Language**: Rust
- **License**: MIT/Apache-2.0
- **Status**: Mature, widely used in Rust ecosystem.

#### Architecture

**Split Client/Connection model**:
- `Client` — user-facing API, sends requests
- `Connection` — background task handling actual I/O on the Tokio runtime
- Requests are pipelined: multiple queries sent before responses arrive
- Futures are lazy — request not sent until polled

#### Key Design Decisions

- **Implicit pipelining** — when futures are polled concurrently, all requests are sent immediately, reducing round-trip latency
- **Separate sync/async crates** — `postgres` (sync) wraps `tokio-postgres` (async)
- **COPY protocol** for high-performance bulk operations
- **Execution order = poll order**, not creation order

#### Benchmark Data

- ~10,284-17,130 requests/second on i9-9900K with PostgreSQL 15.1 (single connection benchmarks)
- Pipelining provides significant latency reduction for batched operations

#### Production Exposure

Core dependency for many Rust web frameworks and ORMs. Used by Supabase infrastructure.

#### Lessons

- Split Client/Connection enables clean async model but requires the Connection to be spawned as a separate task
- Pipelining is a natural fit for async Rust — futures compose well with the protocol's pipeline model

---

### 2.4 pg.zig (Zig)

- **URL**: https://github.com/karlseguin/pg.zig
- **Language**: Zig
- **License**: MIT
- **Status**: 510 stars, actively maintained. Most mature Zig PostgreSQL driver.

#### Architecture

- **Pool-based** — `pg.Pool` maintains configurable number of connections with background reconnection threads
- **Strict type safety** — cannot use `i32` to read `smallint`; must match exactly
- **Result draining requirement** — results must be fully iterated or explicitly drained

#### Key Design Decisions

- **Pool recommended over raw Conn** — pool handles reconnection, state validation
- **Column names optional** — disabled by default to avoid allocation overhead; can enable per-query or via build flag
- **Buffer configuration** — write_buffer (2048 default), read_buffer (4096 default), result_state_size (32 cols default)
- **Eager vs lazy connection init** — `connect_on_init_count` for eager subset, background reconnector for remainder
- **No multi-dimensional arrays**

#### Type System

| Zig Type | PostgreSQL Type |
|----------|----------------|
| `i16` | smallint |
| `i32` | int |
| `i64` | bigint, timestamp |
| `f32` | float4 |
| `f64` | float8, numeric |
| `bool` | boolean |
| `[]const u8` | text, bytea (raw fallback) |
| `pg.Numeric` | numeric (precise) |
| `pg.Cidr` | cidr |

#### Production Exposure

Used in production Zig web services. Author (Karl Seguin) is a well-known systems programmer.

#### Lessons

- Separating drain from deinit avoids error-handling-in-defer problem
- Memory validity tied to iteration lifetime — non-primitive values invalidated on next()
- Query timeouts acknowledged as unreliable (documented limitation)

---

### 2.5 pgz (Zig)

- **URL**: https://github.com/star-tek-mb/pgz
- **Language**: Pure Zig
- **Status**: Pre-alpha. Not production ready.

#### Features

- DSN-based connection strings
- Query execution with struct mapping
- Prepared statements
- Nullable field support via Zig optionals

#### Limitations

- No connection pooling
- Incomplete feature set
- Memory allocation patterns need optimization

---

### 2.6 Odin

- **URL**: https://github.com/laytan/odin-postgresql
- **Language**: Odin (bindings to libpq)
- **Status**: Complete libpq v17 bindings. MIT license.

No native wire protocol implementation exists for Odin — only libpq FFI bindings. This means Odin inherits all libpq limitations (see Section 6).

---

### 2.7 psycopg3 (Python)

- **URL**: https://www.psycopg.org/
- **Language**: Python (wraps libpq)
- **License**: LGPL

#### Architecture

- Uses libpq under the hood (unlike asyncpg)
- Generator-based I/O layer — `pipeline_communicate()` generator orchestrates socket I/O
- Async counterparts: `AsyncConnection`, `AsyncCursor` mirror sync API
- **Rust integration** via Rustler for SQL parsing (in Supavisor context)

#### Key Features

- **Pipeline mode** (v3.1+) — 2x speedup on localhost, dramatically more on high-latency networks
- **DB-API 2.0 compliant** — unlike asyncpg
- **Binary copy protocol** — 1GB+/sec bulk data
- **Prepared statement optimization** — parse/bind/execute cycle

#### Benchmark Data

- Pipeline mode: ~900+ client messages queued before server responses arrive
- INSERT operations ~2x faster with pipeline mode on localhost
- 5x slower than asyncpg on average

---

## 3. Wire Protocol Libraries (Server-Side)

### 3.1 pgwire (Rust)

- **URL**: https://github.com/sunng87/pgwire
- **Language**: Rust (Tokio-based)
- **License**: MIT/Apache-2.0
- **Status**: Actively maintained. Used by GreptimeDB, PeerDB, SpacetimeDB, CeresDB, Fly.io's corrosion.

#### Architecture — Three Abstraction Layers

1. **Raw message layer** — direct protocol message access
2. **Handler trait layer** — `SimpleQueryHandler`, `ExtendedQueryHandler`
3. **High-level API** — ResultSet builder/encoder

#### Protocol Coverage

- Protocol v3.0 and v3.2 (PostgreSQL 18)
- SSL/TLS negotiation (including PG17 direct SSL)
- Authentication: cleartext, MD5, SCRAM-SHA-256, SCRAM-SHA-256-PLUS, SASL OAUTH
- Extended query: Parse, Bind, Execute, Describe, Sync
- Copy In/Out/Both
- Query cancellation
- Notifications

#### Key Design Insight

> "Postgres Wire Protocol has no semantics about SQL, so literally you can use any query language, data formats or even natural language to interact with the backend."

This makes it ideal for building non-SQL systems that speak the PostgreSQL protocol.

#### Projects Using pgwire

- **GreptimeDB** — cloud-native time-series database
- **PeerDB** — Postgres-first ETL (acquired by ClickHouse)
- **SpacetimeDB** — multiplayer game database
- **CeresDB** — distributed time-series (AntGroup)
- **corrosion** — Fly.io gossip-based service discovery
- **dozer** — real-time data platform

---

### 3.2 pgproto3 (Go)

- **URL**: https://github.com/jackc/pgx (subpackage)
- **Language**: Go
- Part of pgx toolkit. Standalone encoding/decoding of PostgreSQL v3 wire protocol.
- Used to build pgmock (test mock server), proxies, load balancers.

---

### 3.3 psql-wire (Go)

- **URL**: https://github.com/jeroenrinzema/psql-wire
- **Language**: Go
- PostgreSQL server wire protocol implementation — build your own PG-compatible server.
- Also forked by StackQL.

---

## 4. Connection Poolers & Proxies

### 4.1 PgBouncer

- **URL**: https://www.pgbouncer.org/
- **Language**: C (libevent)
- **Status**: Industry standard. Single-threaded.

#### Architecture

- Single process, single thread, event-driven (libevent)
- Emulates PostgreSQL server on the frontend
- Creates separate pool per (database, user) pair

#### Pooling Modes

| Mode | Connection Return | Limitations |
|------|-------------------|-------------|
| **Session** | On client disconnect | Least efficient but most compatible |
| **Transaction** | On transaction end | No prepared statements, SET, advisory locks, temp tables |
| **Statement** | After each statement | No multi-statement transactions |

#### Key Limitations

- **Single-threaded** — cannot use multiple cores
- **No prepared statements** in transaction mode — this is the biggest pain point
- **No load balancing** — requires HAProxy or similar in front
- **No query routing** — all queries go to same backend
- **Delayed connection release** — closing client doesn't immediately free server connection
- **No sharding support**

#### Production Exposure

Ubiquitous. Used by Heroku, AWS, virtually every PostgreSQL deployment at scale.

#### Lessons

- Transaction pooling is the sweet spot for most workloads but prepared statement incompatibility is a dealbreaker for many drivers
- Single-threaded simplicity is both a strength (no concurrency bugs) and a weakness (scaling limit)
- The (database, user) pool key is too coarse for multi-tenant systems

---

### 4.2 PgCat (Rust)

- **URL**: https://github.com/postgresml/pgcat
- **Language**: Rust (Tokio)
- **License**: MIT
- **Status**: Production-proven at Instacart, PostgresML, OneSignal. 584+ commits.

#### Architecture

- Multi-threaded via Tokio async runtime (default 4 workers)
- Full PostgreSQL wire protocol implementation
- SQL parsing via `sqlparser` crate for query routing
- TOML-based configuration with live reload (except host/port)

#### Key Features

- **Query routing**: SELECTs to replicas, writes to primary (automatic)
- **Load balancing**: Random (preferred) or least-connections
- **Replica failover**: Auto-ban degraded replicas for 60s, health checks via `;` queries
- **Connection salvaging**: Sends ROLLBACK instead of closing connections on misbehaving clients
- **Sharding**: PARTITION BY HASH support (experimental)
- **Query mirroring**: Route to multiple DBs for testing
- **PgBouncer-compatible admin**: RELOAD, SHOW POOLS, etc.
- **Prometheus metrics** at `/metrics`

#### Instacart Production Data

- **Scale**: ~105,000 QPS peak across multiple ECS tasks (~5,200 QPS per task)
- **Latency overhead vs PgBouncer**: p50 +10us, p90 +100us, p99 +1ms
- **Duration**: 5+ months production (as of March 2023)
- **Clients**: Ruby, Python, Go applications

#### Migration Lessons from Instacart

1. Round-robin load balancing causes traffic concentration during replica failures — switched to random
2. Contributed multiple pools per instance and graceful shutdown features
3. Validated correctness via simultaneous PgBouncer/PgCat comparison with balanced traffic
4. Connection salvaging via ROLLBACK reduces connection thrashing significantly vs PgBouncer's approach of dropping connections

#### Known Limitations

- Prepared statements and SET commands unavailable in transaction mode
- Advisory locks require transaction-scoped variants
- Automatic sharding is experimental
- Auth: MD5 and SCRAM-SHA-256 for server connections, MD5 only for client auth

**Reference**: https://www.instacart.com/company/how-its-made/adopting-pgcat-a-nextgen-postgres-proxy/

---

### 4.3 Supavisor (Elixir)

- **URL**: https://github.com/supabase/supavisor
- **Language**: Elixir (with Rust via Rustler for SQL parsing)
- **License**: Apache 2.0
- **Status**: Production at Supabase. Co-developed with Jose Valim / Dashbit.

#### Architecture

- **Cloud-native clustering** — pool process IDs distributed to all cluster nodes via in-memory KV store
- **Single-node-per-database** — only one node holds direct connections to each DB instance
- **Dynamic tenant pools** — pools created on first client connection, tenant config in PostgreSQL
- **SQL parsing in Rust** — pg_query.rs via Rustler, addressing Elixir's computational weakness
- **OTP patterns** — fault-tolerant supervision trees for connection management

#### Key Features

- **Named prepared statements** — broadcast PREPARE across all pooled connections
- **Query cancellation** — full PostgreSQL cancel protocol through pooler
- **Load balancing** — random distribution across read replicas
- **Auto primary detection** — probes replicas to find primary for writes

#### Scale

- Single 64-core instance: ~500,000 connections
- Benchmarked to 1,000,000 connections with query caching
- Minimal latency overhead

#### Design Trade-offs

- Elixir excels at concurrent connection handling but is weak at computational tasks (hence Rust for parsing)
- Cluster-wide pool distribution adds complexity but enables horizontal scaling
- Read-after-write consistency requires wrapping in transactions
- Writes "a few milliseconds longer" due to automatic primary detection

---

## 5. Connection Pool Libraries

### 5.1 deadpool-postgres (Rust)

- **URL**: https://crates.io/crates/deadpool-postgres
- **Language**: Rust
- Wraps tokio-postgres with connection pooling and statement caching.

#### Architecture

- **Identical startup/runtime behavior** — pool creation never fails; validation at runtime only
- **Statement cache** — wraps `tokio_postgres::Client` and `Transaction`
- **Recycling methods**:
  - `Fast` (default since 0.8): relies on `Client::is_closed()` only — no test query
  - `Verified`: performs test query before returning connection — slower but more reliable

#### Design Insight

The Fast recycling method is a bet that `is_closed()` is sufficient for most failure modes. This avoids the latency of a validation query on every checkout but risks returning a connection that's technically open but in a bad state (e.g., stuck in a transaction).

---

### 5.2 pgxpool (Go)

Part of pgx. Provides:
- After-connect hooks for per-connection setup
- Health check on checkout
- Configurable min/max connections
- Idle connection cleanup

---

### 5.3 HikariCP (Java) — Design Reference

- **URL**: https://github.com/brettwooldridge/HikariCP
- Not a PostgreSQL driver, but the gold standard for pool design.

#### Pool Sizing Formula

```
connections = (core_count * 2) + effective_spindle_count
```

- `core_count` = physical cores (not HT threads)
- `effective_spindle_count` = 0 if data cached, ~1 for SSD, approaches actual spindles as cache miss rate increases
- Example: 4-core + SSD = (4 * 2) + 1 = **9 connections**
- This modest pool handles ~3,000 concurrent users at ~6,000 TPS

#### Pool-Locking Prevention Formula

```
pool_size = Tn * (Cm - 1) + 1
```
Where Tn = max threads, Cm = max simultaneous connections per thread.

#### Core Axiom

> "You want a small pool, saturated with threads waiting for connections."

SSDs paradoxically suggest *fewer* connections — less blocking means less opportunity for thread parallelism. The optimization target is keeping all connections continuously busy, not having connections available.

---

## 6. libpq: Lessons Learned & What to Avoid

**Source**: PostgreSQL's official C client library.

### Why Rewrite Instead of Wrapping libpq

1. **Blocking I/O in non-blocking mode**: Establishing a connection does blocking I/O (file reads, DNS) and is 100% blocking with TLS. It is "essentially impossible to efficiently use libpq in a non-blocking mode of operation."

2. **Build complexity**: libpq has changed substantially over the years. Conditional compilation, version-specific code paths, and testing burden grow rapidly.

3. **No async**: Diesel (Rust ORM) opened an issue specifically about removing libpq to enable async.

4. **The protocol is simple**: PostgreSQL wire protocol is openly documented and not very complex. Direct implementation yields better results than FFI wrapping.

5. **Memory model mismatch**: libpq's C memory model doesn't map cleanly to garbage-collected or ownership-based languages.

### What to Learn from libpq

- **Complete feature coverage** — libpq supports every PostgreSQL feature; drivers that skip features create gaps
- **Connection parameter handling** — libpq's connection string parsing is thorough and well-tested
- **SSL/TLS negotiation** — libpq's approach to SSL is battle-tested
- **SCRAM implementation** — `src/backend/libpq/auth-scram.c` is the reference implementation

### PostgreSQL Wiki Guidance for Driver Authors

- Expose all libpq functionality but don't require libpq
- Support explicit `PQfinish()` equivalent — don't rely on GC for connection cleanup
- Attach `client_encoding` to result objects at retrieval time (encoding can change mid-session)
- Defer type conversions to higher layers (ORMs) — return raw representations
- Use non-blocking internally, block via host language's preferred mechanism
- Don't aim for database-agnosticism
- Don't attempt to anticipate "what most users want"

---

## 7. SCRAM-SHA-256 Authentication

**RFCs**: RFC 5802 (SCRAM), RFC 7677 (SCRAM-SHA-256)
**PostgreSQL source**: `src/backend/libpq/auth-scram.c`
**Reference POC**: https://gist.github.com/jkatz/7444eda78a6fff18ab5d74c024e3761d

### Protocol Flow

```
Client                                  Server
  |                                       |
  |--- StartupMessage ------------------->|
  |<-- AuthenticationSASL (mechanisms) ---|  (SCRAM-SHA-256)
  |--- SASLInitialResponse ------------->|  (client-first-message: n,,n=user,r=<client-nonce>)
  |<-- AuthenticationSASLContinue -------|  (server-first-message: r=<combined-nonce>,s=<salt>,i=<iterations>)
  |--- SASLResponse -------------------->|  (client-final-message: c=biws,r=<combined-nonce>,p=<client-proof>)
  |<-- AuthenticationSASLFinal ----------|  (server-final-message: v=<server-signature>)
  |<-- AuthenticationOk -----------------|
```

### Cryptographic Operations

```
SaltedPassword  := Hi(Normalize(password), salt, iterations)   // PBKDF2
ClientKey       := HMAC(SaltedPassword, "Client Key")
StoredKey       := H(ClientKey)                                  // SHA-256
AuthMessage     := client-first-bare + "," + server-first + "," + client-final-without-proof
ClientSignature := HMAC(StoredKey, AuthMessage)
ClientProof     := ClientKey XOR ClientSignature
ServerKey       := HMAC(SaltedPassword, "Server Key")
ServerSignature := HMAC(ServerKey, AuthMessage)
```

### Stored Password Format

```
SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>
```

### Implementation Notes

- `Hi()` is PBKDF2 with HMAC-SHA-256
- `Normalize()` is SASLprep (RFC 4013) — Unicode normalization
- Channel binding (`SCRAM-SHA-256-PLUS`) adds TLS channel binding data to `c=` field
- Client nonce: cryptographically random, at least 18 bytes recommended
- Server extends client nonce (combined nonce = client nonce + server nonce)
- Default iterations: 4096 (configurable via `scram_iterations` in PG 16+)

### Security Properties

- Password never transmitted (even encrypted)
- Server proves it knows the password too (mutual authentication)
- Resistant to replay attacks (nonces)
- Resistant to dictionary attacks (PBKDF2 iterations)
- Channel binding prevents MITM when used with TLS

---

## 8. Prepared Statement Caching

### Strategies Across Drivers

#### pgx (Go) — Automatic Caching
- Automatically prepares and caches every query
- Cache keyed by SQL text
- Incompatible with PgBouncer transaction mode (PgBouncer doesn't track per-connection prepared statements)
- Can be disabled for PgBouncer compatibility

#### asyncpg (Python) — Full Pipeline Caching
- Caches the entire I/O pipeline per prepared statement (not just the server-side handle)
- Both explicit and implicit preparation cached
- This is the key performance differentiator — avoids re-creating decoders on each execution

#### PostgreSQL JDBC — Delayed Preparation
- `prepareThreshold` = 5 (default): first 4 executions use simple protocol
- 5th execution creates server-side prepared statement
- Server then takes 5 more custom plans before considering generic plan
- `preparedStatementCacheQueries` = 256 (default cache size)
- `preparedStatementCacheSizeMiB` = 5 MB (default cache memory)

#### Named vs Unnamed Prepared Statements
- **Named**: Persists for session lifetime (unless DEALLOCATE'd). Saves parse + plan cost on reuse.
- **Unnamed**: Single-use. Replaces previous unnamed statement. Safe for poolers.
- **Supavisor approach**: Broadcasts PREPARE across all pooled connections — enables named prepared statements through a pooler

### Prepared Statement Caching + Poolers

The fundamental tension: prepared statements are per-connection state, but poolers multiplex connections.

Solutions:
1. Use unnamed statements only (lose caching benefit)
2. Re-prepare on connection checkout (adds latency)
3. Track which statements are prepared on which connections (complex)
4. Broadcast PREPARE to all connections (Supavisor approach, wastes memory)
5. Use simple query protocol (lose type safety, binary format)

---

## 9. Pipeline Mode (Protocol Pipelining)

**Docs**: https://www.postgresql.org/docs/current/libpq-pipeline-mode.html
**PostgreSQL version**: Client-side feature since libpq 14, works with any v3 server

### How It Works

Pipeline mode sends multiple extended query sequences before sending a Sync message. The Sync acts as a synchronization/error-recovery point and implicit transaction boundary.

```
Normal:   Parse -> Bind -> Execute -> Sync -> [wait] -> Parse -> ...
Pipeline: Parse -> Bind -> Execute -> Parse -> Bind -> Execute -> ... -> Sync -> [read all results]
```

### Key Protocol Functions

| Function | Purpose |
|----------|---------|
| `PQenterPipelineMode` | Switch to pipeline mode (connection must be idle) |
| `PQexitPipelineMode` | Exit (all results must be consumed) |
| `PQpipelineSync` | Send Sync + flush (error recovery point) |
| `PQsendFlushRequest` | Request server flush without sync point |
| `PQsendPipelineSync` | Send Sync without flushing (manual flush needed) |

### Performance Impact

| Scenario | Speedup |
|----------|---------|
| Same host, small batch | 1.5x |
| Same host, large batch | 5x |
| Local network | up to 42x |
| Slow network (high latency) | up to 71x |
| 100 statements at 100ms RTT | ~100x (from 10s to 0.1s) |

### Error Handling

When an error occurs in a pipeline:
1. Pipeline enters ABORTED state
2. Subsequent commands return `PGRES_PIPELINE_ABORTED`
3. Processing resumes after next Sync point
4. Committed transactions before the error remain committed

**Critical rule**: Never assume work is committed when COMMIT is *sent* — only when the result confirms it.

### Restrictions

- No simple query protocol (`PQsendQuery`)
- No `COPY` operations
- No multi-statement strings
- Synchronous functions (`PQexec` etc.) disallowed
- Non-blocking mode recommended to avoid deadlocks

### Implementation Pattern

Maintain two queues:
1. Dispatched-but-unprocessed work
2. Work remaining to dispatch

Use select/poll on the socket:
- When writable: dispatch more queries
- When readable: consume results, match to queue entries
- Read frequently — don't wait until pipeline end

### psycopg3 Pipeline Implementation

- Generator-based: `pipeline_communicate()` yields `Wait.RW`
- Commands queue via `pgconn.send_query_params()`
- Results bind back to originating cursors
- ~900+ messages queued before server responses
- Nested pipelines via `PQpipelineSync` for transaction isolation
- ~2x speedup on localhost, dramatically more on high-latency

---

## 10. Binary vs Text Format

### Per-Type Performance

| Data Type | Binary Advantage | Notes |
|-----------|-----------------|-------|
| **bytea** | 2.9-3.5x faster | Text escaping expands size ~3.6x |
| **timestamptz** | 48% faster | At 100 rows |
| **integers** | Significant | No parsing overhead |
| **arrays** | Orders of magnitude | Text requires recursive parsing |
| **numeric** | Moderate | Binary avoids decimal string parsing |
| **text/varchar** | **16% SLOWER** in binary | Binary adds OID + length overhead for strings |
| **composite** | Significant | Binary includes OIDs per field |

### Design Implications

- **Default to binary** for numeric, timestamp, array, bytea types
- **Use text** for pure text/varchar columns (simpler, slightly faster)
- **Per-column format selection** is possible in the Bind message — can mix formats
- asyncpg and pgx both default to binary and achieve large performance gains
- Most drivers that use text format do so because it's simpler to implement, not because it's faster

### Protocol Details

In the Bind message, you can specify:
- 0 format codes: all text
- 1 format code: applies to all columns
- N format codes: per-column specification

Format code 0 = text, format code 1 = binary.

---

## 11. Type OID Mapping Strategies

### OID Ranges

| Range | Purpose |
|-------|---------|
| 1-9999 | Reserved for system catalog (manual assignment) |
| 8000-9999 | Reserved for development |
| 10000-11999 | Auto-generated by genbki.pl |
| 12000-16383 | Bootstrap process objects |
| 16384+ | User-defined types (auto-assigned) |

### Common Built-in OIDs

| OID | Type |
|-----|------|
| 16 | bool |
| 20 | int8 |
| 21 | int2 |
| 23 | int4 |
| 25 | text |
| 700 | float4 |
| 701 | float8 |
| 1043 | varchar |
| 1082 | date |
| 1114 | timestamp |
| 1184 | timestamptz |
| 1700 | numeric |
| 2950 | uuid |
| 3802 | jsonb |

### Strategies

1. **Hardcoded table** (asyncpg, pgx): Compile-in known OIDs for built-in types. Fast lookup, covers 95%+ of cases.

2. **Runtime catalog query** (asyncpg): On connect, query `pg_type` for custom types, enums, composites, domains. Cache per-connection.

3. **Lazy discovery**: Query `pg_type` only when encountering unknown OID in RowDescription. Cache result.

4. **OID alias types**: Use `regtype` for human-readable names: `SELECT 'int4'::regtype::oid`

5. **pgx approach**: ~70 built-in type mappings, extensible via `pgtype` package. Community extensions for PostGIS, UUID libraries, etc.

6. **asyncpg approach**: Introspects server on connect, builds codec pipeline per type, caches entire decode chain.

### Array Type Mapping

Array types have their own OIDs (e.g., `int4[]` = OID 1007). The `pg_type` catalog column `typelem` links array types to their element types. Binary format includes element type OID in the array header.

### Composite/Record Types

Binary format for records: `[num_fields: i32] [oid: i32, len: i32, data: bytes]*`

Each field includes its OID, enabling recursive type resolution.

---

## 12. Zero-Copy Result Parsing

### The Opportunity

PostgreSQL DataRow messages contain field values preceded by 4-byte lengths. In binary format, integers are already in network byte order (big-endian). This enables:

1. **Direct pointer into receive buffer** for variable-length types (text, bytea)
2. **In-place byte-swap** for numeric types
3. **No intermediate string allocation** — avoid text format's parse-allocate-copy cycle

### Implementation Approaches

#### asyncpg (Cython/C)
- Parse and Record construction happen in Cython/C
- Buffer management hand-optimized
- Records reference memory in the receive buffer where possible
- This is why asyncpg achieves 1M rows/s

#### pgx (Go)
- Uses Go's `binary.BigEndian` for direct reads from buffer
- Binary format enables reading integers without string allocation
- Scan directly into user-provided pointers

#### pg.zig
- `[]const u8` values from rows are valid only until next `next()`/`deinit()`/`drain()` call
- This is a zero-copy pattern: returned slices point into the read buffer
- Caller must copy if they need to retain the data

#### Java 21 approach
- `MemorySegment.getUtf8String()` eliminates boilerplate for null-terminated strings
- Foreign Function API enables zero-copy access to native buffers

### General Pattern

```
Receive buffer:  [msg_type][length][col_count][col1_len][col1_data][col2_len][col2_data]...
                                               ^                   ^
                                               |                   |
                                         Slice into buffer    Slice into buffer
                                         (no copy)            (no copy)
```

The key constraint: slices are invalidated when the buffer is reused for the next message.

---

## 13. Connection Health Checking

### Strategies (Ordered by Reliability)

1. **Test query** (`SELECT 1` or `;`): Most reliable but adds latency on every checkout
2. **`Client::is_closed()` check**: Fast but misses broken-but-not-closed connections
3. **TCP keepalive**: Detects dead connections after configurable delay
4. **`client_connection_check_interval`** (PG 14+, Linux only): Periodic socket polling during query execution

### TCP Keepalive Configuration

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `tcp_keepalives_idle` | Time before first keepalive probe | OS default (~2 hours) |
| `tcp_keepalives_interval` | Time between retransmissions | OS default |
| `tcp_keepalives_count` | Failed probes before declaring dead | OS default |
| `keepalives` | Enable/disable keepalive | On |

### Connection Recycling Patterns

#### deadpool-postgres (Rust)
- **Fast** (default): `is_closed()` only — no test query
- **Verified**: Test query before returning — slower but catches more failures

#### PgBouncer
- `server_check_query = 'SELECT 1'` — run on server connection before use
- `server_check_delay` — minimum time between checks

#### PgCat
- Health checks via `;` (empty query) — minimal overhead
- Auto-ban degraded replicas for configurable period
- Connection salvaging via ROLLBACK instead of dropping

#### pgpool-II
- Periodic health check connections to all backends
- Configurable health check period, timeout, retries

### Best Practices

- Set TCP keepalive idle to 60-300s (not the OS default of 2 hours)
- Use Verified recycling for latency-insensitive workloads
- Use Fast recycling + TCP keepalive for latency-sensitive workloads
- PG 14+ `client_connection_check_interval` is the best server-side detection (Linux only)

---

## 14. Pool Sizing Algorithms & Queue Theory

### HikariCP Formula (PostgreSQL-Derived)

```
connections = (core_count * 2) + effective_spindle_count
```

- Physical cores only (no HT)
- SSD effective spindle ≈ 1 (minimal seek blocking)
- Example: 4-core + SSD = 9 connections
- Handles ~3,000 concurrent users at ~6,000 TPS

### Little's Law

```
L = λ * W
```

- L = average number of items in system (connections in use)
- λ = arrival rate (queries per second)
- W = average service time (query duration)

**Implication**: If your average query takes 5ms and you need 1,000 QPS, you need L = 1000 * 0.005 = 5 connections.

### Universal Scalability Law

Maximum throughput is achieved at a *limited* number of connections. Beyond that point, adding connections *decreases* throughput due to:
- Context switching overhead
- Lock contention
- Cache invalidation
- Memory pressure

### FlexyPool Dynamic Sizing

- Start with minimal pool (e.g., 1 connection)
- Set timeout threshold (e.g., 25ms)
- Pool auto-expands when acquisition exceeds threshold
- Monitor peak connections under load → use as static config

**Case study**: 64 concurrent operations, HikariCP default (10 connections) → 149ms. FlexyPool discovered only 4 connections needed → 128ms execution.

### Pool-Locking Prevention

```
pool_size = Tn * (Cm - 1) + 1
```

- Tn = max threads
- Cm = max simultaneous connections per thread
- Prevents deadlock where all threads hold one connection and wait for another

### Practical Guidance

1. Start small (core_count * 2 + 1)
2. Load test with production-like queries
3. Monitor connection wait time, not pool utilization
4. A saturated pool with queued requests is the *goal*, not a problem
5. SSDs mean fewer connections, not more — less blocking = less parallelism opportunity
6. Static pools outperform dynamic pools (Oracle Real-World Performance group recommendation)

---

## 15. DBAPI 2.0 (PEP 249) Compliance

**Specification**: https://peps.python.org/pep-0249/

### Required Module-Level

| Item | Type | Purpose |
|------|------|---------|
| `connect()` | Constructor | Returns Connection object |
| `apilevel` | String | "1.0" or "2.0" |
| `threadsafety` | Integer (0-3) | Thread sharing level |
| `paramstyle` | String | Parameter marker format |

#### Parameter Styles

| Style | Example |
|-------|---------|
| `qmark` | `WHERE name=?` |
| `numeric` | `WHERE name=:1` |
| `named` | `WHERE name=:name` |
| `format` | `WHERE name=%s` |
| `pyformat` | `WHERE name=%(name)s` |

#### Thread Safety Levels

| Level | Meaning |
|-------|---------|
| 0 | No sharing at all |
| 1 | Module sharing OK, not connections |
| 2 | Module + connections OK, not cursors |
| 3 | Everything shareable |

### Error Hierarchy

```
Exception
├── Warning
└── Error
    ├── InterfaceError
    └── DatabaseError
        ├── DataError
        ├── OperationalError
        ├── IntegrityError
        ├── InternalError
        ├── ProgrammingError
        └── NotSupportedError
```

### Connection Object

Required methods: `close()`, `commit()`, `cursor()`
Optional: `rollback()`

### Cursor Object

Required attributes: `description`, `rowcount`, `arraysize`
Required methods: `execute()`, `executemany()`, `fetchone()`, `fetchmany()`, `fetchall()`, `close()`, `setinputsizes()`, `setoutputsize()`
Optional: `callproc()`, `nextset()`

### Type Constructors

`Date`, `Time`, `Timestamp`, `DateFromTicks`, `TimeFromTicks`, `TimestampFromTicks`, `Binary`

### Type Objects (for description comparison)

`STRING`, `BINARY`, `NUMBER`, `DATETIME`, `ROWID`

### Optional Extensions

- `cursor.rownumber` — current position
- `cursor.connection` — parent connection reference
- `cursor.scroll()` — position cursor in result set
- `cursor.__iter__()` — make cursor iterable
- `cursor.lastrowid` — last modified row ID
- `connection.autocommit` — query/set autocommit
- Two-phase commit: `xid()`, `tpc_begin()`, `tpc_prepare()`, `tpc_commit()`, `tpc_rollback()`, `tpc_recover()`

### Compliance Notes for Implementation

- `description` must return 7-item sequences: `(name, type_code, display_size, internal_size, precision, scale, null_ok)`
- `rowcount` = -1 if undetermined
- `executemany()` must not use `.fetchone()` or similar
- SQL NULL → Python `None`
- `arraysize` default = 1

---

## 16. PostgreSQL Wire Compatibility Ecosystem

Systems implementing PG wire protocol for client compatibility:

| System | Language | Wire Compat | SQL Compat | Notes |
|--------|----------|-------------|------------|-------|
| CockroachDB | Go | Full | High (YACC from PG) | Distributed via Raft |
| YugabyteDB | C/C++ | Full | High (PG parser lib) | Sharding on PK only |
| TimescaleDB | C | Full (extension) | Full (is PG) | Time-series extension |
| QuestDB | Java | Partial | Custom | Time-series |
| CrateDB | Java | Partial | Custom (ANTLR) | No full ACID |
| Materialize | Rust | Full | Custom | Streaming |
| RavenDB | C# | Partial | Low | Document DB |
| Aurora | — | Full | High | AWS managed PG |
| Cloud Spanner | — | Partial | Custom | Google managed |
| GreptimeDB | Rust (pgwire) | Full | Custom | Time-series |
| PeerDB | Rust (pgwire) | Full | Custom | ETL |
| SpacetimeDB | Rust (pgwire) | Full | Custom | Game DB |

**Key lesson**: Wire protocol compatibility does not imply SQL compatibility. Systems using PostgreSQL's own parser (CockroachDB, YugabyteDB) achieve highest compatibility. Custom parsers diverge on edge cases.

---

## 17. Research Papers & Deep References

### Protocol & Wire Format

- PostgreSQL Protocol Documentation: https://www.postgresql.org/docs/current/protocol.html
- PostgreSQL Message Formats: https://www.postgresql.org/docs/current/protocol-message-formats.html
- Wire Protocol Gist (Python): https://gist.github.com/fantix/c2ddb24b636fb132093a958b08b43665
- "The World of PostgreSQL Wire Compatibility": https://datastation.multiprocess.io/blog/2022-02-08-the-world-of-postgresql-wire-compatibility.html

### Driver Development

- PostgreSQL Wiki — Driver Development: https://wiki.postgresql.org/wiki/Driver_development
- pgx README: https://github.com/jackc/pgx/blob/master/README.md
- "PGX Top to Bottom" presentation (Golang Estonia)
- go_db_bench: https://github.com/jackc/go_db_bench
- Go database/sql overhead analysis: https://notes.eatonphil.com/2023-10-05-go-database-sql-overhead-on-insert-heavy-workloads.html

### Performance & Optimization

- "1M rows/s from Postgres to Python": https://www.geldata.com/blog/m-rows-s-from-postgres-to-python
- asyncpg benchmarks: https://github.com/MagicStack/asyncpg
- Rust postgres benchmarks: https://github.com/bikeshedder/rust-postgres-benchmark
- Binary data performance in PostgreSQL: https://www.cybertec-postgresql.com/en/binary-data-performance-in-postgresql/

### Connection Pooling

- HikariCP Pool Sizing: https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing
- FlexyPool: https://vladmihalcea.com/optimal-connection-pool-size/
- PgBouncer config: https://www.pgbouncer.org/config.html

### Pipeline Mode

- PostgreSQL Pipeline Mode Docs: https://www.postgresql.org/docs/current/libpq-pipeline-mode.html
- Pipeline mode in psycopg: https://blog.dalibo.com/2022/09/19/psycopg-pipeline-mode.html
- Pipeline performance analysis: https://www.cybertec-postgresql.com/en/pipeline-mode-better-performance-on-slow-network/
- Psycopg pipeline article: https://www.psycopg.org/articles/2024/05/08/psycopg3-pipeline-mode/

### Authentication

- PGCon 2017 SCRAM presentation: https://www.pgcon.org/2017/schedule/attachments/466_PGCon2017-SCRAM.pdf
- SCRAM-SHA-256 POC (Python): https://gist.github.com/jkatz/7444eda78a6fff18ab5d74c024e3761d
- PostgreSQL auth-scram.c source: https://doxygen.postgresql.org/auth-scram_8c_source.html
- RFC 5802 (SCRAM): https://tools.ietf.org/html/rfc5802
- RFC 7677 (SCRAM-SHA-256): https://tools.ietf.org/html/rfc7677

### Production Deployments & Post-Mortems

- Instacart PgCat adoption: https://www.instacart.com/company/how-its-made/adopting-pgcat-a-nextgen-postgres-proxy/
- Supavisor 1.0 announcement: https://supabase.com/blog/supavisor-postgres-connection-pooler
- PgCat vs PgBouncer comparison: https://pganalyze.com/blog/5mins-postgres-pgcat-vs-pgbouncer
- Sentry 100x optimization (asyncpg): https://blog.sentry.io/2022/02/25/how-we-optimized-python-api-server-code-100x/

### Type System

- pg_type catalog: https://www.postgresql.org/docs/current/catalog-pg-type.html
- pg_type.dat (initial data): https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_type.dat
- pg_type.h: https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_type.h

### Specifications

- PEP 249 (DBAPI 2.0): https://peps.python.org/pep-0249/

### Queue Theory & Scaling

- "Applying Queueing Theory to Dynamic Connection Pool Sizing": https://blog.jooq.org/applying-queueing-theory-to-dynamic-connection-pool-sizing-with-flexypool/
- Universal Scalability Law: https://vladmihalcea.com/the-simple-scalability-equation/
- "Building a Connection Pool from Scratch": https://medium.com/nerd-for-tech/building-a-connection-pool-from-scratch-internals-design-and-real-world-insights-e4f72fd7d9af

### Zig Ecosystem

- pg.zig: https://github.com/karlseguin/pg.zig
- pgz: https://github.com/star-tek-mb/pgz
- "Zig: Build PostgreSQL Driver from Scratch" (educational): https://algorisys.substack.com/p/zig-build-postgresql-driver-from
- pgzx (PostgreSQL extensions in Zig): https://github.com/xataio/pgzx


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-af9361e92cca8403f.jsonl`
