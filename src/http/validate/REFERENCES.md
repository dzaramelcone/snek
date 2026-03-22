# Schema & Type Validation Engines: State of the Art

Exhaustive survey of high-performance validation systems across compiled and dynamic languages.
Last updated: 2026-03-21.

---

## Table of Contents

1. [Python Ecosystem](#1-python-ecosystem)
   - [pydantic-core (Rust/Python)](#11-pydantic-core)
   - [msgspec (C/Python)](#12-msgspec)
   - [cattrs (Python)](#13-cattrs)
   - [beartype (Python)](#14-beartype)
   - [typeguard (Python)](#15-typeguard)
2. [Rust Ecosystem](#2-rust-ecosystem)
   - [jsonschema-rs](#21-jsonschema-rs)
   - [valico](#22-valico)
   - [simd-json (Rust port)](#23-simd-json-rust)
3. [C/C++ Ecosystem](#3-cc-ecosystem)
   - [simdjson](#31-simdjson)
   - [RapidJSON Schema](#32-rapidjson-schema)
   - [valijson](#33-valijson)
   - [yyjson](#34-yyjson)
4. [Go Ecosystem](#4-go-ecosystem)
   - [google/jsonschema-go](#41-googlejsonschema-go)
   - [kaptinlin/jsonschema](#42-kaptinlinjsonschema)
   - [santhosh-tekuri/jsonschema](#43-santhosh-tekurijsonschema)
5. [Zig & Odin](#5-zig--odin)
6. [JavaScript/TypeScript (reference)](#6-javascripttypescript)
   - [Ajv](#61-ajv)
7. [Research Papers & Compiled Validation](#7-research--compiled-validation)
   - [Blaze](#71-blaze-compiled-json-schema-validation)
8. [Cross-Cutting Concerns](#8-cross-cutting-concerns)
   - [Compiled vs. Interpreted Validation](#81-compiled-vs-interpreted-validation)
   - [SIMD-Accelerated Validation](#82-simd-accelerated-validation)
   - [Type Coercion Strategies](#83-type-coercion-strategies)
   - [Validation Error Accumulation](#84-validation-error-accumulation)
   - [Recursive/Nested Type Handling](#85-recursivenested-type-handling)
   - [Zero-Allocation Validation](#86-zero-allocation-validation)
   - [Constraint Propagation](#87-constraint-propagation)

---

## 1. Python Ecosystem

### 1.1 pydantic-core

- **URL**: https://github.com/pydantic/pydantic-core
- **Language**: Rust (via PyO3), exposed as Python C extension
- **Production exposure**: Massive. Pydantic is the most-downloaded Python validation library. Used by FastAPI, LangChain, hundreds of thousands of projects.

#### Architecture

pydantic-core compiles Python schema definitions (`CoreSchema` TypedDicts) into a tree of Rust validators through a multi-stage pipeline:

1. `SchemaValidator.__new__()` receives a `CoreSchema` TypedDict with a `'type'` discriminator
2. `build_validator_base()` delegates via the `validator_match!` macro
3. Routes to specific `BuildValidator` trait implementations based on schema type
4. `DefinitionsBuilder` handles recursive references and forward declarations
5. Constructs nested `CombinedValidator` instances forming the validator tree

**CombinedValidator enum**: 60+ variants using `enum_dispatch` crate for zero-cost polymorphism. No vtable indirection — Rust compiler inlines variant-specific logic. Categories:
- Primitives: Int, ConstrainedInt, Float, Str, Bool, Bytes, Decimal
- Collections: List, Tuple, Set, FrozenSet, Dict
- Structured: TypedDict, Model, ModelFields, Dataclass
- Logic: Union, TaggedUnion, Nullable, Chain, WithDefault
- Functions: FunctionBefore, FunctionAfter, FunctionPlain, FunctionWrap
- Temporal: Date, Time, Datetime, Timedelta

**Input trait**: Abstracts over Python objects, JSON (via jiter), and string mappings. Three implementations:
- `Bound` (Python objects via PyO3) — supports strict/lax modes
- `JsonValue` (jiter) — always strict, no type ambiguity in JSON
- `StringMapping` — URL query parameters, strict string only

**ValidationMatch<T>**: Wraps validated values with an Exactness indicator:
- `Exact`: input is precisely the expected type
- `Strict`: input is a compatible subtype
- `Lax`: input required coercion (e.g., `"123"` → `int`)

Union validators use exactness for disambiguation: prefer exact > strict > lax.

#### Performance Model

- 5-50x faster than pydantic v1 (pure Python)
- ~17x faster on typical mixed-field models
- `enum_dispatch` eliminates virtual call overhead
- `smallvec` (stack-allocated vectors) avoids heap allocation for small collections
- `ahash` (non-cryptographic) for fast hashmap lookups
- Profile-Guided Optimization (PGO) in release builds

#### jiter JSON Parser

- Custom JSON parser replacing serde_json, tuned for Python object creation
- ~15% faster ASCII string parsing via fast path
- String cache: fully associative, 16,384 entries, strings < 64 bytes cached
- Supports `inf`/`NaN` deserialization (unlike serde_json)
- Lazy iteration mode available

#### Error Accumulation

- `ValError` enum containing `ValLineError` instances
- 80+ `ErrorType` variants across categories (type errors, parsing errors, constraint errors, model errors)
- Complex validators (Union, TypedDict) accumulate multiple line errors before deciding failure
- Each `ValLineError` carries: error_type, location path, input_value
- Errors collected across all fields — NOT fail-fast by default
- Converted to Python `ValidationError` with `.errors()`, `.json()`, `.error_count()`

#### Recursive Type Handling

- `DefinitionsBuilder` uses two-phase approach:
  1. Register definitions with placeholder IDs during compilation
  2. Resolve recursive references post-compilation via definitions map
- `ValidationState` tracks visited definitions at runtime to prevent infinite loops
- `RecursionState` for stack overflow prevention

#### Type Coercion

- Dual paths: `strict_*()` and `lax_*()` methods on Input trait
- Fallback chains: string validators can coerce from int/bool; numeric validators accept string representations
- Three coercion levels tracked via Exactness
- Configurable strict mode disables all lax coercion

#### Key Dependencies

| Crate | Purpose |
|-------|---------|
| `pyo3` | Python/Rust bindings |
| `enum_dispatch` v0.3.13 | Zero-cost enum dispatch |
| `smallvec` v1.15.1 | Stack-allocated small vectors |
| `ahash` v0.8.12 | Fast non-crypto hashing |
| `jiter` | Custom JSON parser |

#### Lessons Learned

- Writing a custom JSON parser (jiter) over serde_json yielded measurable gains — shows how critical the parsing layer is
- `enum_dispatch` is a significant win over `dyn Trait` for hot-path polymorphism
- Exactness tracking is elegant for union disambiguation without backtracking
- PGO provides meaningful additional speedup on top of already-optimized Rust

---

### 1.2 msgspec

- **URL**: https://github.com/jcrist/msgspec
- **Language**: C extension for CPython
- **Production exposure**: 50M+ PyPI downloads. Used in production data pipelines.

#### Architecture

msgspec performs **validation during decoding** — a single pass that creates correctly-typed output objects without intermediate representations. This is the key insight: validation is fused into deserialization.

Core type: `msgspec.Struct` — a custom C-level type that replaces dataclasses/attrs/pydantic models.

#### Performance Claims (benchmarked on ~2020 x86 Linux, CPython 3.11)

**JSON decode+validate vs. alternatives:**
- msgspec: 1.0x baseline
- mashumaro: ~6x slower
- cattrs: ~10x slower
- pydantic v2: ~12x slower
- pydantic v1: ~85x slower

**Raw JSON encode/decode (no schema):**
- msgspec beats orjson on decode (0.000367s vs 0.000463s for test payload)
- "msgspec decodes AND validates JSON faster than orjson can decode it alone"

**Memory (peak RSS, JSON validation benchmark):**
| Library | Memory | Ratio |
|---------|--------|-------|
| msgspec | 0.64 MiB | 1.0x |
| cattrs | 3.25 MiB | 5.1x |
| mashumaro | 7.12 MiB | 11.1x |
| pydantic v1 | 10.03 MiB | 15.7x |
| pydantic v2 | 16.26 MiB | 25.4x |

**Large file (77 MiB conda-forge repodata.json):**
| Library | Memory (MiB) | Time (ms) |
|---------|-------------|-----------|
| msgspec structs | 67.6 | 176.8 |
| msgspec (no schema) | 218.3 | 630.5 |
| orjson | 406.3 | 691.7 |
| simdjson | 603.2 | 1053.0 |

**Struct operations:**
- Creation: ~4x faster than dataclasses/attrs, ~17x faster than pydantic
- Equality: 4-30x faster
- Import: 12.51 us vs 673.47 us (pydantic)

**GC interaction:**
| Type | GC Time (ms) | Memory (MiB) |
|------|-------------|-------------|
| Standard class | 80.46 | 211.66 |
| Standard class + __slots__ | 80.06 | 120.11 |
| msgspec Struct | 13.96 | 120.11 |
| msgspec Struct (gc=False) | 1.07 | 104.85 |

With `gc=False`: 75x faster GC passes than standard classes.

**Library size**: 0.46 MiB vs pydantic's 6.71 MiB (14.66x smaller)

#### Key Design Decisions

- **Fused decode+validate**: No intermediate dict/object; output types created correctly the first time
- **Zero-copy where possible**: References to input buffer preferred over copies
- **GC-aware structs**: Optional `gc=False` flag for structs that don't contain reference cycles, dramatically reducing GC pressure
- **C extension**: Not Rust, not pure Python — hand-written C for maximum CPython integration
- **No mutation**: Structs are designed for immutable-ish usage patterns
- **Supports JSON, MessagePack, YAML, TOML** with same type system

#### Trade-offs

- Less flexible than pydantic (no custom validators, limited hooks)
- No "lax" coercion mode — strict by design
- Smaller ecosystem/community
- C extension means harder to contribute than pure Python

#### Benchmark Caveat (from msgspec docs)

> "Benchmarks are hard...instruction cache staying hot...branches highly predictable. That's not representative of real world access patterns."

---

### 1.3 cattrs

- **URL**: https://github.com/python-attrs/cattrs
- **Language**: Pure Python
- **Production exposure**: Stable, used in legacy and functional codebases. Part of the attrs ecosystem.

#### Architecture

cattrs separates un/structuring rules from models (one-to-many relationship). Key modules:

- `cattrs.gen`: Dynamically creates optimized conversion functions for specific types via code generation (not generic reflection)
- `cattrs.dispatch`: Sophisticated mechanism for registering custom conversion rules
- `cattrs.strategies`: Pre-built solutions for union handling, subclass inclusion
- `cattrs.errors`: Detailed error reporting with aggregation of multiple validation failures

#### Key Design Decisions

- **Separation of concerns**: Models own no serialization logic; converters are external
- **Code generation**: `gen` module generates specialized converter functions rather than interpreting types at runtime
- **Composable**: Hook factories allow per-type customization
- **Error accumulation**: `cattrs.errors` collects and aggregates multiple validation failures

#### Performance

- Tracks performance using codspeed
- Enum handling optimized via hook factories
- ~10x slower than msgspec on JSON decode+validate benchmarks
- Much faster than pydantic v1, comparable to pydantic v2 in some scenarios

#### Trade-offs

- Pure Python — inherently slower than C/Rust alternatives
- More complex mental model (converters separate from models)
- Excellent for functional/immutable patterns
- Great when you don't own the model classes

---

### 1.4 beartype

- **URL**: https://github.com/beartype/beartype
- **Language**: Pure Python
- **Production exposure**: Widely used for runtime type checking. Recommended in 2025/2026 for production runtime validation.

#### Architecture: O(1) Runtime Type Checking

beartype is a **third-generation** runtime type checker. Its core innovation: transforming type checking from per-call interpretation into pre-computed verification.

**Two-phase approach:**

1. **Decoration time** (slow, one-time): `@beartype` dynamically generates a wrapper function containing optimized pure-Python type-checking code. This is where most work happens.
2. **Call time** (fast, every call): The generated wrapper executes pre-computed checks in O(1) constant time with negligible constant factors.

**Key insight**: Rather than exhaustively checking every element of a `List[List[List[int]]]` (which typeguard does — O(n) per call), beartype randomly samples a constant number of elements per call. Over many calls, probabilistic coverage approaches 100%.

#### Performance Model

- O(1) non-amortized worst-case time complexity
- Checking a list of 1,000,000 2-tuples of NumPy arrays: ~36.7 us
- Zero runtime dependencies
- Pure Python — no C extension overhead, but also no C extension speed

#### vs. typeguard

| Aspect | beartype | typeguard |
|--------|----------|-----------|
| Time complexity | O(1) constant | O(n) variable |
| Work phase | Decoration time | Call time |
| Nested checking | Probabilistic sampling | Exhaustive |
| Deep nesting cost | Constant | Exponential |

typeguard checking `List[List[List[int]]]` with 1000^3 elements: checks every integer every call. beartype: checks a fixed sample regardless of size.

#### Trade-offs

- Probabilistic — can miss type errors on individual calls (but catches them over time)
- Not a serialization/deserialization library
- Not a schema validator — specifically a function argument/return type checker
- Pure Python limits absolute speed ceiling
- PEP-compliant across many PEPs (484, 585, 586, 589, 591, 593, etc.)

---

### 1.5 typeguard

- **URL**: https://github.com/agronholm/typeguard
- **Language**: Pure Python
- **Production exposure**: Widely used, especially before beartype gained traction.

#### Architecture

typeguard performs **exhaustive** runtime type checking at call time. For every decorated function call, it validates all parameters and return values against their type hints, traversing nested structures completely.

#### Performance

- O(n) time complexity where n = total elements in nested structures
- Significantly slower than beartype for deeply nested types
- `List[object]` takes roughly the same time as `Union[int, str]` which takes ~2x as long as `str`

#### Trade-offs

- Exhaustive checking = guaranteed correctness on every call
- But O(n) cost makes it impractical for hot paths with large data
- Simpler mental model than beartype's probabilistic approach

---

## 2. Rust Ecosystem

### 2.1 jsonschema-rs

- **URL**: https://github.com/Stranger6667/jsonschema
- **Language**: Rust
- **Production exposure**: Used by Tauri (config validation), Apollo Router (config validation), qsv (CSV record validation). 759 stars, actively maintained, v0.45.0 (March 2026).

#### Architecture

Compiles JSON Schema into a validation tree for maximum validation speed. Offers multiple validation interfaces:

- `is_valid()`: Boolean fast path — no error allocation, much faster than `validate()`
- `validate()`: Returns on first error
- `iter_errors()`: Exhaustive error collection with instance path information
- `evaluate()`: Structured output (JSON Schema Output v1 format) with flag, list, and hierarchical modes

**Supported drafts**: 2020-12, 2019-09, Draft 7, 6, 4.

#### Performance

- 75-645x faster than valico and jsonschema_valid for complex schemas
- 2-52x faster than boon for typical workloads
- **>5000x faster than boon for recursive schemas** — suggests sophisticated memoization/caching for circular references
- Reusing compiled validators dramatically outperforms one-off validation

#### Key Design Decisions

- Separate `is_valid()` fast path avoids error object allocation entirely
- Compiled validator reuse amortizes schema compilation cost
- Custom keyword and format validator support
- Blocking and non-blocking remote reference fetching
- Python and Ruby language bindings available
- WebAssembly support

#### Trade-offs

- Schema compilation is relatively slow (acceptable since schemas change rarely)
- Full JSON Schema spec compliance is complex and ongoing
- aws-lc-rs TLS dependency for remote refs adds binary size

---

### 2.2 valico

- **URL**: https://github.com/s-panferov/valico
- **Language**: Rust
- **Production exposure**: Lower adoption than jsonschema-rs. Significantly slower (75-645x vs jsonschema-rs).

#### Architecture

Two components:
1. **DSL**: Validators and coercers inspired by Grape (Ruby)
2. **JSON Schema**: IETF Draft v4 implementation

**Coercion design**: Mutates borrowed JSON values in-place. Coercion runs BEFORE schema validation — pipeline is: coerce → validate.

Builder pattern for defining validations with unlimited nesting depth.

#### Key Design Decisions

- In-place mutation for coercion (avoids allocation but requires `&mut`)
- Coerce-then-validate pipeline order
- Combined validation + coercion in single library

#### Trade-offs

- Much slower than jsonschema-rs
- In-place mutation is a footgun
- Only Draft v4 support
- Less actively maintained

---

### 2.3 simd-json (Rust)

- **URL**: https://crates.io/crates/simd-json
- **Language**: Rust (port of simdjson)
- **Note**: `simd-json-schema` (https://github.com/simd-lite/simd-json-schema) is **archived** (Oct 2022), only 3 commits, essentially abandoned. Not production-viable.

The Rust SIMD JSON parser itself is mature, but schema validation on top of it is not a solved problem in the Rust ecosystem.

---

## 3. C/C++ Ecosystem

### 3.1 simdjson

- **URL**: https://simdjson.org / https://github.com/simdjson/simdjson
- **Language**: C++ (with ports to Go, Java, Rust, Python, etc.)
- **Production exposure**: ClickHouse, Meta Velox, Node.js runtime, Apache Doris, Milvus, StarRocks, Shopify, Intel, Google Pax, WatermelonDB.

#### Architecture: Two-Stage SIMD Parsing

**Stage 1** (SIMD-accelerated):
- Scans 64 bytes at a time using SIMD operations
- Identifies all JSON structural characters (braces, brackets, colons, commas)
- Validates UTF-8 encoding simultaneously
- Produces a compressed structural index

**Stage 2**:
- Walks the structural index with a forward-only cursor
- Materializes values on demand

#### On-Demand API (2024 paper)

Published: "On-Demand JSON: A Better Way to Parse Documents?" — Keiser & Lemire, Software: Practice and Experience 54(6), 2024.

- Appears like DOM API to programmer but parses lazily
- Only materializes values that are actually accessed
- Uses `std::string_view` for zero-copy string access
- Validates selectively: only values accessed are validated

**Performance (Intel Xeon Gold 6338):**
- 70% faster than DOM-based simdjson
- 2.5x faster than yyjson
- ~8x faster than RapidJSON
- Uses 60% of instructions of DOM simdjson, 50% of yyjson

**Memory**: Only allocates structural index (4 bytes per structural character). No tree construction.

#### Performance Headlines

- Parsing at gigabytes per second on commodity CPUs
- Minifying JSON: 6 GB/s
- Validating UTF-8: 13 GB/s
- NDJND: 3.5 GB/s

#### Limitation

simdjson is a **parser**, not a schema validator. It validates JSON syntax and UTF-8, not schema constraints. Schema validation must be layered on top.

#### Research Papers

1. "Parsing Gigabytes of JSON per Second" — Langdale & Lemire, VLDB Journal 28(6), 2019
2. "Validating UTF-8 In Less Than One Instruction Per Byte" — Keiser & Lemire, Software: Practice & Experience 51(5), 2021
3. "On-Demand JSON: A Better Way to Parse Documents?" — Keiser & Lemire, Software: Practice & Experience 54(6), 2024

---

### 3.2 RapidJSON Schema

- **URL**: https://rapidjson.org/md_doc_schema.html
- **Language**: C++
- **Production exposure**: Very widely used C++ JSON library.

#### Architecture: SAX-Based Streaming Validation

Unlike most validators that require full DOM parsing, RapidJSON validates **during parsing** via SAX events. Memory usage depends on schema complexity, not document size.

Components:
- `SchemaDocument`: Compiled schema representation (reusable across validators)
- `SchemaValidator`: Event handler implementing validation logic
- `SchemaValidatingReader`: Routes SAX events between reader, validator, and document

**Streaming validation**: If the validator encounters an invalid value, parsing terminates immediately (fail-fast on the SAX stream).

#### Performance

- 262/263 JSON Schema Test Suite (Draft v4) tests passing
- 155% relative speed (30,682 tests/second)
- 1.5x faster than ajv (fastest JS validator)
- 1,400x faster than slowest tested validator

#### Error Reporting

Structured JSON error objects:
- Member names = violated keywords
- Values contain `instanceRef` (JSON Pointer to invalid data) and `schemaRef` (URI to violated subschema)
- Keyword-specific violations include expected/actual values

#### Recursive Schema Handling

- `$ref` keyword with JSON Pointer references
- Local (`#`-prefixed) and remote (URI) pointers
- User-provided `IRemoteSchemaDocumentProvider` for custom URI resolution

#### Key Design Decisions

- SAX-based = constant memory regardless of document size
- One `SchemaDocument` serves multiple `SchemaValidator` instances
- Validators reusable via `reset()`
- Internal NFA-based regex engine (avoids external dependency)
- `std::regex` available as alternative via compile flag

#### Trade-offs

- Only Draft v4 support
- Single test failure on scope/ref edge case
- `format` keyword intentionally ignored
- SAX model is less intuitive than DOM-based validation

---

### 3.3 valijson

- **URL**: https://github.com/tristanpenman/valijson
- **Language**: C++ (header-only)
- **Production exposure**: Moderate. Packaged in Debian.

#### Architecture

Template-based design decoupled from any specific JSON parser. `SchemaParser` and `Validator` are template classes accepting any supported parser adapter.

#### Key Design Decisions

- **Parser-agnostic**: Works with RapidJSON, nlohmann/json, Boost.JSON, jsoncpp, etc.
- **Strong vs weak typing**: Default is strong (no coercion). `"23"` will NOT parse as number.
- **RAII memory management**: Automatic cleanup of schema/validation state
- **Header-only**: Zero build complexity, but slower compilation

#### Supported Versions

- v1.0.x: C++14
- v1.1.x: C++17
- v1.2.x: C++20 (upcoming)

#### Trade-offs

- Header-only = slow compile times for large projects
- Parser-agnostic = potential performance overhead from adapter layer
- Less optimized than RapidJSON's integrated schema validation
- Goal: "competitive with hand-written schema validator"

---

### 3.4 yyjson

- **URL**: https://github.com/ibireme/yyjson
- **Language**: ANSI C (C89)
- **Production exposure**: High. "The fastest JSON library in C."

yyjson is a **parser/serializer only** — no schema validation. Relevant as a parsing backend for validation systems.

- Reads/writes gigabytes per second
- ANSI C89 for maximum portability
- Immutable and mutable document APIs
- Zero external dependencies

---

## 4. Go Ecosystem

### 4.1 google/jsonschema-go

- **URL**: https://github.com/google/jsonschema-go
- **Language**: Go
- **Production exposure**: Critical dependency for Google's AI SDKs. Released January 2026.

#### Architecture

- Zero external dependencies (stdlib only)
- Supports Draft 2020-12 and Draft 7
- Three core functions: schema creation, JSON validation, schema inference from Go structs
- `schemagen` CLI tool for generating precompiled schemas

#### Key Design Decisions

- No dependencies outside stdlib — minimal attack surface, easy vendoring
- Precompiled schemas via code generation tool
- Designed to strengthen Go ecosystem for AI applications (structured output validation)
- MIT licensed

---

### 4.2 kaptinlin/jsonschema

- **URL**: https://github.com/kaptinlin/jsonschema
- **Language**: Go
- **Production exposure**: Growing adoption.

#### Architecture

- JSON Schema Draft 2020-12 validator
- Direct struct validation with zero-copy (no JSON marshaling)
- Smart unmarshaling with defaults
- Separated validation workflow
- `schemagen` command-line tool for compiled schema generation
- Internationalized error messaging

---

### 4.3 santhosh-tekuri/jsonschema

- **URL**: https://github.com/santhosh-tekuri/jsonschema
- **Language**: Go
- **Production exposure**: High. Most widely used Go JSON Schema validator.

#### Performance (Go JSON Schema Validator Benchmarks)

**Complex schemas (AJV suite):**
| Library | Time/Op (geo mean) | Memory | Allocs/Op |
|---------|-------------------|--------|-----------|
| santhosh-tekuri | 15.3 us | 5.00 kB | 73.2 |
| qri-io | 10.4 us | 5.16 kB | 77.7 |
| xeipuuv | 27.5 us | 9.15 kB | 182.6 |

**Simple schemas (Draft 7 suite):**
| Library | Time/Op (geo mean) | Memory | Allocs/Op |
|---------|-------------------|--------|-----------|
| santhosh-tekuri | 2.66 us | 1.94 kB | 15.1 |
| qri-io | 4.03 us | 3.06 kB | 35.6 |
| xeipuuv | 4.92 us | 2.90 kB | 40.2 |

**Correctness (Draft 7):**
- santhosh-tekuri: 1 failed test
- xeipuuv: 0 failed tests
- qri-io: 51 failed tests

santhosh-tekuri is ~2x faster than xeipuuv for complex schemas with much lower allocation counts.

---

## 5. Zig & Odin

### Zig

Zig has no dedicated schema validation library ecosystem yet, but its **comptime** feature enables unique approaches:

- **Comptime type validation**: Types are first-class values at compile time. The `zig-duck` library (https://github.com/NewbLuck/zig-duck) provides duck typing / comptime type validation.
- **JSON parsing**: `std.json` in stdlib supports comptime struct field resolution. JSON fields are mapped to Zig struct fields at compile time.
- **Zero-allocation parsing**: `std.json.Scanner` supports `.allocate_if_needed` mode — only allocates when string values span buffer boundaries.
- **Comptime ORM pattern**: matklad's 2025 blog post demonstrates comptime schema definition for an in-memory relational database — same pattern applicable to validation.

**Key insight from matklad (2025)**: "Zig doesn't have declaration-site type checking of comptime code" — comptime is powerful but trades static guarantees for flexibility.

**Limitation**: Zig comptime cannot do everything — no runtime code generation, no JIT. Validation schemas must be known at compile time or use runtime interpretation.

### Odin

Odin has no JSON schema validation libraries. Its type system is simpler than Zig's (no comptime equivalent). C-like speed with fast compilation. Not relevant for this survey beyond noting the gap.

---

## 6. JavaScript/TypeScript

### 6.1 Ajv

- **URL**: https://github.com/ajv-validator/ajv / https://ajv.js.org
- **Language**: JavaScript
- **Production exposure**: Massive. Most widely used JSON Schema validator across all languages.

#### Architecture: Code Generation

Ajv compiles JSON Schemas into JavaScript validation functions optimized for V8. Starting from v7, uses a dedicated `CodeGen` module (replacing doT templates).

**Generated code characteristics:**
- No loops or function calls in generated validators
- Each schema keyword compiles to inline `if` statements
- ~100x faster than interpreting validators
- 50% faster than second-fastest JS validator
- "Almost 3 times faster than the nearest alternative" in some tests

**Code generation pipeline:**
1. Schema parsed and normalized
2. CodeGen module generates JavaScript AST nodes
3. `_` template creates `_Code` instances (safe from injection)
4. `str` template generates string expressions
5. Optimization passes applied (1-3 passes configurable)

**Optimization passes:**
- Pass 1: Remove empty/unreachable branches, unused variables, inline single-use constants
- Result: ~10.5% code size reduction, ~16.7% tree node reduction
- Pass 2: <0.1% additional improvement (diminishing returns)

**Standalone mode**: Generates validation functions at build time → zero startup cost at runtime.

#### Key Design Decisions

- Code generation over interpretation = ~100x speedup
- Safe code generation via TypeScript type system prevents injection
- Standalone mode eliminates runtime compilation
- Supports Draft 4/6/7/2019-09/2020-12 and JSON Type Definition (RFC 8927)

#### Trade-offs

- Compilation is slow — must reuse compiled validators
- Generated code is hard to debug
- Security considerations with `eval`-based generation (mitigated in v7+)
- 200+ test failures in JSON Schema Test Suite (correctness issues)

---

## 7. Research & Compiled Validation

### 7.1 Blaze: Compiled JSON Schema Validation

- **URL**: https://arxiv.org/html/2503.02770v1 (February 2025)
- **Language**: C++20 (~11,000 lines)
- **Production exposure**: Research prototype. Not yet widely deployed.

#### Core Thesis

Schemas change infrequently (average 65 days between commits in GitHub corpus of 31,000+ schemas) while validation happens constantly. Trading compilation time for validation speed is overwhelmingly worthwhile.

#### Architecture: Three-Layer System

**Layer 1 — Schema Validation Language (DSL):**
An intermediate instruction set with:
- Basic instructions: TypeAny, EqualsAny, StringSize, Less/Greater/Equal, Regex, Divisible
- Loop instructions: LoopKeys, LoopProperties, LoopPropertiesExcept, LoopPropertiesRegex, LoopItems, LoopItemsFrom
- Logical operators: LogicalAnd/Or/Xor/Not with short-circuit evaluation
- Control flow: ControlLabel + ControlJump for instruction reuse and schema references

**Layer 2 — Compilation Strategy:**
Three-tier keyword hierarchy:
1. **Independent keywords**: Evaluated in any order (type constraints, properties, contains, etc.)
2. **First-level dependent**: Statically resolvable (additionalProperties, items resolved by examining adjacent keywords)
3. **Second-level dependent**: unevaluatedProperties/unevaluatedItems — compiler statically identifies which properties will be evaluated, generating instructions only for genuinely unevaluated cases. Avoids runtime annotation overhead.

**Layer 3 — Execution Engine:**
Loop-based interpreter executing instructions against JSON documents using JSON Pointer notation. Instructions include preconditions (e.g., numeric constraints only apply to numbers).

#### Critical Optimizations

**1. Semi-Perfect Hashing (~25% speedup):**
- 95% of schema keys are <=13 characters (from GitHub corpus analysis)
- 256-bit hash output (four 64-bit integers)
- Strings <=31 bytes: stored directly as integers, comparison becomes integer comparison
- Longer strings: hash from length + first/last characters
- Collision rate <0.9% (vs 0% for MurmurHash) but constant-time lookup wins overall

**2. Instruction Unrolling (~3% average, up to 40% on specific schemas):**
- Individual instructions generated instead of loops when <=5 properties OR >=25% required
- Non-recursive references used <=5 times are inlined (cache efficiency)

**3. Regex Optimization (~12% overall speedup):**
- `.*` → removed entirely
- `.+` → length check
- `^x-` → string prefix check
- `^.{3,5}$` → length validation
- Uses Boost.Regex with precompilation

**4. Instruction Reordering:**
- Properties with smaller subschemas validated first
- Enables faster failure in oneOf/anyOf applicators

**5. Memory Pool Preallocation:**
- Preallocated small pools for vectors and hash maps
- Reused across validations without reallocation

#### Performance Results

- **10x faster** than next fastest validator on average
- **20-40% faster minimum** than all competing implementations
- **100% correctness** on JSON Schema Test Suite (2020-12 dialect)
- ~9.4x faster than ajv on warm runs
- ~10.9x faster than boon on cold runs

Tested against 11 implementations across 38 schemas. 12 of 20 validators pass full test suite; Blaze among perfect scorers.

#### Reference Handling

- **Static refs**: First encounter generates ControlLabel; subsequent uses issue ControlJump. Inlining for non-recursive refs <=5 occurrences.
- **Dynamic refs**: Extremely rare (10 of 31,000+ schemas). Single-context dynamic refs converted to static at compilation.

#### Dataset Analysis (31,000+ GitHub schemas)

- Dynamic references: extremely rare
- 95%+ of keys <=13 characters
- Most objects have small property counts
- Average schema change interval: 65 days
- 98%+ of keys <32 characters

#### Future Work (proposed by authors)

- JIT compilation to native code
- Data-dependent optimization using example keywords
- Finite automata compilation for regex patterns
- Profiling-based instruction ordering
- Parallel execution
- Detailed error messages preserving schema semantics

---

## 8. Cross-Cutting Concerns

### 8.1 Compiled vs. Interpreted Validation

| Approach | Examples | Startup | Validation Speed | Flexibility |
|----------|----------|---------|-----------------|-------------|
| **Interpreted** | Most Python validators, Go validators | Fast | Slow (re-evaluates schema per document) | Easy to modify schemas at runtime |
| **Compiled (runtime)** | pydantic-core, jsonschema-rs, ajv | Slow (one-time) | Fast (pre-computed validator tree) | Schema changes require recompilation |
| **Compiled (build-time)** | Ajv standalone, Blaze, schemagen tools | Zero at runtime | Fastest | Schema must be known at build time |
| **Comptime** | Zig comptime JSON | Zero at runtime | Native speed | Schema must be compile-time constant |

**Key finding from Blaze paper**: Compiled validation achieves 10x over interpreted, and there's still headroom (JIT, data-dependent optimization).

**Ajv finding**: Code generation yields ~100x over interpretation, with generated functions containing no loops or function calls — pure inline `if` chains.

### 8.2 SIMD-Accelerated Validation

SIMD is currently used for **parsing** (simdjson) and **UTF-8 validation**, not for schema constraint checking.

**What SIMD does well:**
- Structural character identification (braces, brackets, colons, commas) — 64 bytes at a time
- UTF-8 validation — 13 GB/s
- String escaping/unescaping
- Number parsing

**What SIMD does NOT currently do:**
- Schema constraint evaluation (min/max, pattern matching, type checking)
- These are inherently branchy, data-dependent operations unsuitable for SIMD

**Opportunity**: SIMD could accelerate batch validation of homogeneous arrays (e.g., checking all elements of a large array satisfy a numeric range). No production implementation exists.

**simd-json-schema** (Rust): Attempted to combine SIMD parsing with schema validation. Archived 2022, only 3 commits. Dead project.

### 8.3 Type Coercion Strategies

| System | Coercion Model |
|--------|---------------|
| pydantic-core | Three-level: Exact > Strict > Lax. Configurable strict mode. Union disambiguation uses exactness preference. |
| msgspec | Strict only. No coercion. What you decode is what you get. |
| cattrs | Configurable. Strong/weak typing per converter. |
| beartype | N/A (type checker, not deserializer) |
| valico | Coerce-then-validate pipeline. Mutates input in-place. |
| valijson | Strong typing by default. No coercion. |
| RapidJSON | No coercion. Schema validation is assertion-only. |
| Ajv | Configurable coercion (coerceTypes option). String→number, string→boolean. |

**Lessons**:
- pydantic-core's exactness tracking is the most sophisticated approach — enables union disambiguation without backtracking
- msgspec's strict-only approach yields simplicity and speed
- Coerce-then-validate (valico) is simple but mutation is a footgun

### 8.4 Validation Error Accumulation

| System | Strategy | Details |
|--------|----------|---------|
| pydantic-core | **Collect-all** | Accumulates ValLineError instances across all fields. 80+ error types. Returns comprehensive ValidationError. |
| msgspec | **Fail-fast** | Raises ValidationError on first failure with path info (e.g., `$.groups[0]`). |
| jsonschema-rs | **Both** | `is_valid()` = fail-fast boolean. `validate()` = first error. `iter_errors()` = collect-all. |
| cattrs | **Collect-all** | `cattrs.errors` aggregates multiple failures. |
| RapidJSON | **Fail-fast (SAX)** | Terminates parsing on first violation in streaming mode. But error objects contain structured multi-violation data. |
| Ajv | **Configurable** | `allErrors` option: false = fail-fast, true = collect-all. |
| Blaze | **Fail-fast** | Focuses on validation speed; error reporting is future work. |
| valijson | **Collect-all** | Collects constraint violations across schema. |

**Functional programming pattern**: The `Validated` type (Scalaz, Cats) accumulates errors in a semigroup. Conceptually: `Validated[NonEmptyList[Error], A]` vs `Either[Error, A]` (fail-fast).

**Hybrid pattern**: Allow pipeline to continue isolating bad records, but halt if overall quality drops below threshold (e.g., <80% pass rate).

### 8.5 Recursive/Nested Type Handling

| System | Approach |
|--------|----------|
| pydantic-core | `DefinitionsBuilder` two-phase: register placeholders during compilation, resolve post-compilation. `RecursionState` prevents infinite loops at runtime. |
| jsonschema-rs | >5000x faster than competitors on recursive schemas — sophisticated memoization/caching for circular references. |
| Blaze | `ControlLabel` + `ControlJump` instructions. Non-recursive refs inlined <=5 times. Static conversion of dynamic refs when possible. |
| RapidJSON | `$ref` with JSON Pointer. User-provided resolver for remote refs. |
| Ajv | Compiles recursive schemas into functions that call themselves. |
| simdjson | N/A (parser only, no schema awareness). |

**Key insight from jsonschema-rs benchmarks**: Recursive schema handling is where naive implementations fall apart (>5000x slower). The difference between memoized and non-memoized recursive validation is orders of magnitude.

### 8.6 Zero-Allocation Validation

**Strategies observed:**

1. **Stack allocation for small collections**: pydantic-core's `smallvec` — avoids heap for typical field counts
2. **Memory pool preallocation**: Blaze preallocates vectors/hashmaps, reuses across validations
3. **Zero-copy string access**: simdjson On-Demand's `std::string_view`, msgspec's buffer references
4. **Boolean-only fast path**: jsonschema-rs `is_valid()` avoids all error object allocation
5. **Arena allocation**: Go arena proposal (Google reports 15% CPU/memory savings in large apps). google/jsonschema-go precompiles schemas, likely arena-friendly.
6. **Fused decode+validate**: msgspec creates output objects correctly the first time — no intermediate dict allocation
7. **GC-aware types**: msgspec Struct `gc=False` — 75x faster GC passes
8. **Instruction reuse**: Blaze's ControlLabel/ControlJump avoids duplicating validation logic

**Most impactful**: Fused decode+validate (msgspec) and boolean-only fast path (jsonschema-rs) — these eliminate entire categories of allocation.

### 8.7 Constraint Propagation

Constraint propagation in the validation context means resolving dependencies between schema keywords at compile time rather than runtime.

**Blaze's three-tier hierarchy** is the most sophisticated example:
1. Independent keywords (no dependencies)
2. First-level dependent (resolvable by examining adjacent keywords statically)
3. Second-level dependent (unevaluatedProperties/Items — requires analyzing full schema structure)

By resolving these at compilation, Blaze avoids maintaining runtime annotation sets, which is how most interpreting validators handle `unevaluatedProperties`.

**pydantic-core** performs analogous work during `BuildValidator` — field validators are compiled with knowledge of their parent TypedDict/Model structure, enabling optimizations like pre-computed field sets.

**Rust type system as constraint propagation**: Luca Palmieri's "Zero to Production" demonstrates using Rust's type system to encode domain invariants (e.g., `SubscriberEmail` newtype that can only be constructed via validation). Constraints are propagated through the type system at compile time — no runtime validation needed after construction.

---

## Summary of Key Lessons

1. **Fused decode+validate is the biggest single win** (msgspec). Eliminating the intermediate representation removes an entire allocation and traversal pass.

2. **Compiled validation beats interpretation by 10-100x** (Blaze, Ajv). The gap is so large that even naive compilation outperforms sophisticated interpretation.

3. **Schema compilation cost is almost always acceptable** because schemas change orders of magnitude less frequently than they validate (65 days average vs. millions of validations).

4. **Recursive schemas are the performance cliff**. Naive implementations are >5000x slower. Memoization and static reference resolution are essential.

5. **Boolean-only fast paths matter**. jsonschema-rs's `is_valid()` vs `validate()` shows that avoiding error construction is a significant optimization when you only need pass/fail.

6. **SIMD accelerates parsing, not validation**. Schema constraint checking is branchy and data-dependent — not SIMD-friendly. The win is in the parsing layer underneath.

7. **Zero-cost polymorphism (enum_dispatch) beats vtables** for hot-path validator dispatch. pydantic-core's measured gains from this are significant.

8. **Exactness tracking solves union disambiguation** elegantly. pydantic-core's Exact/Strict/Lax system avoids backtracking in union validation.

9. **Semi-perfect hashing for short keys** (Blaze) gives ~25% speedup. Most real-world JSON keys are <13 characters — exploit this.

10. **GC integration matters in managed languages**. msgspec's `gc=False` yielding 75x GC improvement shows that validation library design must consider garbage collector interaction.

---

## References (Papers)

- Langdale, G. & Lemire, D. (2019). "Parsing Gigabytes of JSON per Second." VLDB Journal 28(6). https://arxiv.org/abs/1902.08318
- Keiser, J. & Lemire, D. (2021). "Validating UTF-8 In Less Than One Instruction Per Byte." Software: Practice & Experience 51(5).
- Keiser, J. & Lemire, D. (2024). "On-Demand JSON: A Better Way to Parse Documents?" Software: Practice & Experience 54(6). https://arxiv.org/html/2312.17149v3
- Blaze authors (2025). "Blaze: Compiling JSON Schema for 10x Faster Validation." https://arxiv.org/html/2503.02770v1

## References (URLs)

- pydantic-core: https://github.com/pydantic/pydantic-core
- pydantic-core architecture: https://deepwiki.com/pydantic/pydantic-core
- jiter: https://github.com/pydantic/jiter
- msgspec: https://github.com/jcrist/msgspec
- msgspec benchmarks: https://jcristharif.com/msgspec/benchmarks.html
- cattrs: https://github.com/python-attrs/cattrs
- beartype: https://github.com/beartype/beartype
- jsonschema-rs: https://github.com/Stranger6667/jsonschema
- valico: https://github.com/s-panferov/valico
- simdjson: https://simdjson.org/
- simdjson publications: https://simdjson.org/publications/
- RapidJSON Schema: https://rapidjson.org/md_doc_schema.html
- valijson: https://github.com/tristanpenman/valijson
- yyjson: https://github.com/ibireme/yyjson
- google/jsonschema-go: https://github.com/google/jsonschema-go
- kaptinlin/jsonschema: https://github.com/kaptinlin/jsonschema
- santhosh-tekuri/jsonschema: https://github.com/santhosh-tekuri/jsonschema
- Go validators benchmark: https://dev.to/vearutop/benchmarking-correctness-and-performance-of-go-json-schema-validators-3247
- Ajv: https://github.com/ajv-validator/ajv
- Ajv codegen: https://ajv.js.org/codegen.html
- zig-duck: https://github.com/NewbLuck/zig-duck
- Zig comptime ORM: https://matklad.github.io/2025/03/19/comptime-zig-orm.html
- Domain modeling with types (Rust): https://lpalmieri.com/posts/2020-12-11-zero-to-production-6-domain-modelling/
- Validated pattern: https://softwarepatternslexicon.com/functional/effect-handling-patterns/error-handling/validated/


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-a377d0f89a4bd69e5.jsonl`
