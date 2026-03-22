# Python C Extension & FFI Implementation Reference

Exhaustive survey of state-of-the-art approaches to bridging Python with systems languages.
Last updated: 2026-03-21.

---

## Table of Contents

1. [PyO3 (Rust to Python)](#pyo3-rust-to-python)
2. [Maturin (Build/Publish for PyO3)](#maturin)
3. [pydantic-core (Rust Validation Bridge)](#pydantic-core)
4. [nanobind (C++ to Python)](#nanobind)
5. [Cython (Python to C)](#cython)
6. [CFFI (C FFI for Python)](#cffi)
7. [HPy (Universal Python C API)](#hpy)
8. [CPython Limited/Stable API (abi3)](#cpython-limited-stable-api-abi3)
9. [Ziggy Pydust (Zig to Python)](#ziggy-pydust)
10. [py.zig (Lightweight Zig Bindings)](#pyzig)
11. [setuptools-zig / st_zig](#setuptools-zig)
12. [scikit-build-core (CMake Build Backend)](#scikit-build-core)
13. [Production Case Studies](#production-case-studies)
14. [Cross-Cutting Concerns](#cross-cutting-concerns)
    - [GIL Management Strategies](#gil-management-strategies)
    - [Python 3.13+ Free-Threaded Mode](#free-threaded-mode)
    - [Async Bridging](#async-bridging)
    - [Memory Management Across FFI](#memory-management)
    - [Error Propagation](#error-propagation)
    - [Buffer Protocol & Zero-Copy](#buffer-protocol)
    - [Type Stub Generation](#type-stub-generation)
15. [Academic Research](#academic-research)
16. [Comparative Summary](#comparative-summary)

---

## PyO3 (Rust to Python)

- **URL**: https://github.com/PyO3/pyo3
- **Language**: Rust
- **Latest version**: 0.28.2 (March 2026)
- **Stars**: 15.5k
- **Minimum Rust**: 1.83
- **Supported runtimes**: CPython 3.7+, PyPy 7.3 (Python 3.11+), GraalPy 25.0+ (Python 3.12+)

### Key Design Decisions

**GIL as a type-level token.** The `Python<'py>` marker type proves at compile time that the GIL is held. All APIs requiring the GIL take this token as an argument. This is the single most important design insight in the Rust-Python ecosystem: encoding GIL ownership in the type system eliminates an entire class of runtime errors.

**Bound API (0.21+, solidified in 0.23).** Smart pointers like `Bound<'py, T>` replaced the older `&PyAny` "GIL-ref" approach. The bound API separates the Python lifetime `'py` from the input data lifetime `'a`, enabling borrowing from input data without extending interpreter attachment. The deprecated `gil-refs` feature was fully removed in 0.23.

**GIL release.** `py.allow_threads(|| { ... })` temporarily releases the GIL for pure-Rust computation, re-acquiring on scope exit. Critical for not blocking Python threads during heavy Rust work.

**Free-threaded support (0.23+).** Initial support for CPython 3.13t. The `#[pyclass]` macro now requires types implement `Sync` because free-threaded builds allow multiple Python threads to operate simultaneously on underlying Rust data.

**Error handling.** Rust `Result<T, PyErr>` maps directly to Python exceptions. `PyErr::new::<ExceptionType, _>(msg)` creates typed exceptions. Libraries like `eyre` integrate via feature flags (`pyo3/eyre`). Panics are caught at the FFI boundary and converted to `PanicException`.

**Type conversions.** `FromPyObject` and `IntoPyObject` traits handle bidirectional conversion. In 0.23, `FromPyObject` gained a second lifetime `'a` for the input, taking `Borrowed<'a, 'py, PyAny>` instead of `&Bound<'py, PyAny>`.

### Trade-offs

- Compile times are non-trivial (Rust + proc macros + linking)
- GIL token threading through async code is complex
- No direct execution of Rust futures on Python's event loop (requires bridge)
- Strong type safety comes at the cost of verbosity for simple wrappers

### Production Exposure

Used by: pydantic-core, polars, cryptography, orjson, ruff, uv, blake3-py, tiktoken (OpenAI), tokenizers (Hugging Face), and hundreds more.

---

## Maturin

- **URL**: https://github.com/PyO3/maturin / https://www.maturin.rs
- **Language**: Rust
- **Latest version**: 1.12.6 (March 2026)
- **Bindings supported**: PyO3, cffi, uniffi, pure Rust binaries

### Key Design Decisions

**Minimal configuration.** A `pyproject.toml` with `[build-system] requires = ["maturin"]` and a `Cargo.toml` is all you need. Maturin merges metadata from both files, with `pyproject.toml` taking precedence.

**PEP 621 compliance.** Python package metadata lives in `pyproject.toml` in the standard `[project]` table.

**Development mode.** `maturin develop` builds and installs directly into the active virtualenv, enabling rapid iteration without wheel packaging.

**Cross-compilation.** Supports building manylinux wheels via Docker or Zig as a cross-linker. Accepts `python3.13t` target for free-threaded cross-compilation.

**abi3 support.** Automatic detection when PyO3's `abi3` feature is enabled. Sets wheel tags accordingly. Important limitation: **free-threading and abi3 are currently incompatible** (PEP 803 addresses this for Python 3.15+).

**Publishing.** Recommends `uv publish` over `twine` for uploading to PyPI.

### Trade-offs

- Tightly coupled to PyO3/Rust ecosystem (by design)
- manylinux compliance requires Docker or Zig for cross-compilation
- No incremental builds across `maturin develop` invocations (full Cargo rebuild)

### Production Exposure

De facto standard for all PyO3-based packages. Used by polars, pydantic-core, cryptography, orjson, ruff, uv, and the entire modern Rust-Python ecosystem.

---

## pydantic-core

- **URL**: https://github.com/pydantic/pydantic-core
- **Language**: Rust (PyO3)
- **Purpose**: Core validation/serialization engine for Pydantic v2+

### Architecture

**Schema as communication protocol.** The bridge between Python and Rust is a "core schema" — a structured Python dictionary with a `type` discriminator field. The `GenerateSchema` class in Python produces these dicts; Rust's `SchemaValidator` compiles them into an optimized validator tree. Example: `{'type': 'bool', 'strict': True}`.

**Three-layer design:**
1. Python API layer — user-facing schema definition functions returning `CoreSchema` TypedDicts
2. Rust core — `SchemaValidator` struct (entry point from Python), `CombinedValidator` enum dispatching to specific implementations
3. Input abstraction — the `Input` trait abstracts over Python objects, JSON, and strings, so validators work uniformly regardless of source

**Compilation model.** Schemas are compiled once into a validator tree, then reused for all validations. This amortizes the cost of schema interpretation.

**Serialization.** `SchemaSerializer` with `to_python()` and `to_json()` methods. JSON serialization goes directly from Rust to bytes, bypassing Python's json module.

### Performance

- **17x faster** than Pydantic V1 overall
- **5-20x** improvement on individual validation operations
- JSON parsing goes directly into validation (no intermediate Python dicts)

### Key Lessons

- Custom core schema types are deliberately forbidden — only pydantic-core's built-in types are allowed. This constraint enables Rust to optimize the validator tree without dynamic dispatch overhead.
- The `Annotated` type + `__get_pydantic_core_schema__` provides extensibility without breaking the schema constraint.
- Error handling uses a structured `ValidationError` with line numbers, input values, and error chains — all constructed in Rust and surfaced as a Python exception.

---

## nanobind

- **URL**: https://github.com/wjakob/nanobind
- **Language**: C++17
- **Latest version**: 2.12.0 (February 2026)
- **Successor to**: pybind11

### Key Design Decisions

**Narrower scope than pybind11.** "The codebase has to adapt to the binding tool and not the other way around." pybind11 must handle all of C++ to bind legacy codebases; nanobind targets modern C++17+ and is simpler and faster as a result.

**Co-located object storage.** Per-instance overhead reduced from 56 bytes (pybind11) to 24 bytes — a 2.3x reduction. C++ binding information is co-located with Python objects to reduce pointer chasing.

**PEP 590 vectorcall.** Function dispatch uses vectorcall, eliminating heap allocation in the dispatch path.

**Precompiled support library.** `_libnanobind_` is compiled once and shared across all binding files, avoiding redundant template instantiation.

**Stable ABI targeting.** Supports Python 3.12+ stable ABI, enabling single-wheel-per-platform distribution.

**Free-threaded Python support.** Localized locking rather than pybind11's central `internals` data structure, enabling superior multi-core scaling.

### Benchmarks (vs pybind11)

| Metric | Improvement |
|--------|-------------|
| Compilation time | 2.7-4.4x faster |
| Binary size (optimized) | 3-5x smaller |
| Simple function calls | ~3x faster |
| Class passing | ~10x faster |
| Per-instance memory | 2.3x less |

### Unique Features (absent from pybind11)

- Zero-copy array exchange via DLPack and buffer protocol (NumPy, PyTorch, TensorFlow, JAX)
- Automatic `.pyi` stub generation for IDE autocomplete and static type checking
- Deferred docstring rendering
- Leak detection at interpreter shutdown
- Low-level API for fine-grained instance/type creation

### Trade-offs

- Requires C++17 minimum (pybind11 supports C++11)
- Deliberately removes support for some C++ edge cases
- Smaller community than pybind11 (though growing rapidly)

### Production Exposure

Used by: Mitsuba 3 renderer, Dr.Jit (differentiable JIT compiler), and growing adoption in scientific computing.

---

## Cython

- **URL**: https://cython.org / https://github.com/cython/cython
- **Language**: Python superset compiled to C
- **Latest version**: 3.x series (3.3.0a0 in development)

### Key Design Decisions

**Superset of Python.** Valid Python is valid Cython (with ~20-50% speedup from compilation alone). Adding type annotations via `cdef`, `cpdef`, or standard Python type hints enables C-level performance.

**Pure Python mode (Cython 3.0+).** Write standard `.py` files with type annotations recognized by Cython. The vast majority of Cython functions are now exposed in pure Python mode. This means existing linting and analysis tools work on Cython code — a major DX improvement.

**NumPy ufunc support (Cython 3.0+).** Simple numeric functions can be compiled directly into NumPy ufuncs for element-wise array operations.

**Limited API support.** Cython can target CPython's Limited API / Stable ABI for forward-compatible wheels.

### Performance Characteristics

- Pure Python compilation: 20-50% speedup
- With type annotations: 10-100x speedup on tight loops
- Competitive with hand-written C for numeric code
- Key insight: "don't touch Cython until profiling shows a tight loop dominating runtime"

### Trade-offs

- `.pyx` files are a dialect, not standard Python (pure Python mode mitigates this)
- Debugging compiled code is harder than pure Python
- Build complexity (needs C compiler, generates intermediate C files)
- Generated C code is enormous and unreadable
- Not competitive with Rust/C++ for complex data structure manipulation

### Production Exposure

One of the most widely deployed extension mechanisms. Used by: NumPy (historically), SciPy, scikit-learn, lxml, gevent, uvloop, and thousands of scientific computing packages.

---

## CFFI

- **URL**: https://github.com/python-cffi/cffi
- **Language**: Python/C
- **Latest version**: 2.0.0 (September 2025, supports Python 3.13/3.14)

### Key Design Decisions

**Two modes:**
- **ABI mode** — load precompiled shared libraries at runtime, no compiler needed. Simpler but limited to calling existing functions.
- **API mode** — compile C code with a C compiler, generating a Python extension. More flexible, better performance (avoids `libffi` overhead).

**Declarative C definitions.** You write C declarations in Python strings, and CFFI parses them. No wrapper code generation, no SWIG-style interface files.

**PyPy native support.** CFFI was designed by the PyPy team and runs natively on PyPy without cpyext overhead.

### Performance

- API mode: near-native call overhead
- ABI mode: `libffi` overhead per call (~100ns)
- Key optimization: minimize per-call crossings, pass arrays/buffers in bulk
- Real-world: 3-10x speedups wrapping simdjson, zstd via CFFI

### Trade-offs

- ABI mode has higher per-call overhead than direct C extensions
- No automatic type safety beyond what C declarations provide
- Less ergonomic than PyO3 or nanobind for complex type hierarchies
- No automatic stub generation

### Production Exposure

Used by: cryptography (historically, now Rust), bcrypt, PyNaCl, many system-level Python packages. PyPy's recommended FFI mechanism.

---

## HPy

- **URL**: https://hpyproject.org / https://github.com/hpyproject/hpy
- **Language**: C
- **Latest version**: 0.9

### Key Design Decisions

**Implementation-agnostic API.** Extensions built for the HPy Universal ABI load unmodified on CPython, PyPy, GraalPy. This is the defining feature — no recompilation needed per implementation.

**Opaque handles instead of `PyObject*`.** HPy uses `HPy` handles rather than raw pointers. This decouples extensions from CPython's reference-counting internals and enables tracing GC implementations to work efficiently.

**Debug mode.** Built-in debugging detects handle leaks, use-after-close, and other common errors at development time.

**Incremental migration.** Legacy compatibility APIs allow calling CPython C API functions from HPy code, enabling gradual porting.

### Performance

- CPython: ~10% overhead for Universal ABI (vs native C API)
- PyPy: ujson-hpy runs **3x faster** than original ujson
- GraalPy: close-to-CPython performance with HPy ports
- NumPy HPy port: 30k+ lines ported, tests and benchmarks running

### Adoption Status

- **NumPy**: 2+ years of porting work, running tests/benchmarks with HPy
- **kiwi-solver**: fully ported to universal mode
- **ultrajson-hpy**: first real-world HPy port
- **Matplotlib**: partial port (blocked on dependency chain)

### Trade-offs

- Still pre-1.0 (API surface growing but not yet complete)
- Smaller ecosystem than C API or PyO3
- 10% overhead on CPython vs native C API
- Migration requires non-trivial effort for large codebases
- Less tooling and documentation than mature alternatives

---

## CPython Limited/Stable API (abi3)

- **URL**: https://docs.python.org/3/c-api/stable.html
- **Language**: C

### Design

The Limited API is a subset of CPython's C API that guarantees forward binary compatibility. Extensions compiled against abi3 for Python 3.X work on 3.X, 3.X+1, 3.X+2, etc. without recompilation.

### Trade-offs

**Performance cost.** Safe accessor functions replace fast macros. `PyList_GetItem()` is available but `PyList_GET_ITEM()` (the unsafe macro) is not. The performance difference is measurable in tight loops.

**Packaging benefit.** A single wheel per platform instead of per-Python-version. The cryptography project ships 48 wheels; without abi3, this would roughly double.

**Validation gap.** No enforcement that a wheel tagged as abi3 actually uses only Limited API. `abi3audit` exists as a third-party validator but is not integrated into pip/PyPI.

**CPython-only.** The stable ABI is specific to CPython. Not compatible with PyPy or other implementations (that's what HPy is for).

**Free-threading incompatible.** The current abi3 does not support free-threaded builds. PEP 803 proposes `abi3t` for Python 3.15+.

### Future: PEP 803 (abi3t) and PEP 809 (abi2026)

**PEP 803** introduces `abi3t` — a stable ABI variant for free-threaded Python that makes `PyObject` opaque. Extensions must use `PyModExport` (PEP 793) instead of static `PyModuleDef`. Target: Python 3.15. Status: Draft.

**PEP 809** proposes `abi2026` as the next-generation stable ABI, resolving known incompatibilities. Planned retirement after at least 10 years.

---

## Ziggy Pydust

- **URL**: https://github.com/spiraldb/ziggy-pydust
- **Language**: Zig
- **Latest Zig support**: 0.14 (with ~3-6 month lag on new Zig releases)

### Key Design Decisions

**Comptime type wrapping.** At comptime, Pydust wraps function definitions so native Zig types can be accepted/returned and automatically converted to/from Python objects. This leverages Zig's comptime to eliminate the boilerplate that plagues C extensions.

**CPython Stable API wrappers.** Wraps almost all of the CPython Stable API, enabling forward-compatible wheels.

**Buffer protocol support.** Zero-copy leverage of NumPy compute over native Zig slices.

**Poetry integration.** Integrates with Poetry for building wheels and sdists.

**Pytest plugin.** Executes Zig tests alongside Python tests in a unified test runner.

### Trade-offs

- Zig language instability means periodic breaking changes
- 3-6 month lag on new Zig versions
- Smaller community than PyO3 or nanobind
- Zig ecosystem is still maturing (package management, IDE support)

### Production Exposure

Developed by SpiralDB (now VortexDB) for their columnar data format. The most mature Zig-Python framework.

---

## py.zig

- **URL**: https://github.com/codelv/py.zig
- **Language**: Zig
- **Status**: Alpha (breaking changes ongoing)

### Design Philosophy

Minimalist alternative to Ziggy Pydust. Defines extern structs with a single `impl` field matching the underlying CPython type, allowing safe `@ptrCast` to raw C API pointers when needed. This dual-access pattern gives ergonomic wrappers with an escape hatch to the raw C API.

Designed for use with `setuptools-zig` — clone/copy py.zig into your project, add an Extension entry in setup.py, and `@import("py.zig")`.

### Trade-offs

- Very early stage, API unstable
- Much less feature coverage than Ziggy Pydust
- No stable ABI support
- No buffer protocol support (yet)
- Advantage: much simpler codebase, easier to understand and modify

---

## setuptools-zig

- **URL**: https://github.com/frmdstryr/setuptools-zig (setuptools-zig) / https://github.com/K0lb3/st_zig (st_zig)
- **Language**: Python/Zig

### setuptools-zig

A setuptools extension for building CPython extensions written in Zig and/or C using the Zig compiler. Supports Python 3.9-3.14, tested with Zig 0.11-0.15. Zig's ability to mix C and Zig means you can write the CPython interface in C while doing heavy lifting in Zig.

### st_zig

Alternative approach: uses Zig as a C/C++ compiler (leveraging the `ziglang` PyPI package). Users don't need to install any build tools beyond pip — `ziglang` provides the compiler. Eliminates platform-specific compiler flag management.

---

## scikit-build-core

- **URL**: https://github.com/scikit-build/scikit-build-core
- **Language**: Python/CMake

Ground-up rewrite of scikit-build. PEP 517 compliant build backend that bridges Python packaging with CMake. Supports C, C++, Fortran, Cython, CUDA.

The compiled backend landscape:
- **maturin** — Cargo/Rust (dominant for Rust)
- **scikit-build-core** — CMake (dominant for C/C++/Fortran)
- **meson-python** — Meson (growing in scientific Python)

scikit-build-core provides native pyproject.toml integration, WIP setuptools transition path, and WIP Hatchling plugin.

---

## Production Case Studies

### Polars (DataFrame library)

- **Architecture**: Core in Rust, Python bindings via PyO3 in `py-polars` crate
- **Memory**: Built on Arrow columnar format for zero-copy and SIMD vectorization
- **Lazy evaluation**: Query optimizer applies predicate pushdown, column pruning, operation fusion
- **Runtime selection**: Ships 3 extension modules (`polars-runtime-32`, `polars-runtime-64`, `polars-runtime-compat`), Python code detects CPU features at import and loads the most optimized
- **Custom allocators**: JeMalloc/Mimalloc for significant allocation performance gains
- **Performance**: 3-10x faster than Pandas on large ETL workloads (10M+ rows)
- **UDF support**: Users can write Rust UDFs via PyO3 that operate on Polars' native types

### cryptography (pyca)

- **Architecture**: Rust for all parsing (ASN.1, X.509) + OpenSSL for cryptographic algorithms
- **Migration path**: Started with CFFI, incrementally migrated to Rust over ~5 years
- **Performance wins**: X.509 parsing 10x faster than OpenSSL 3; public key parsing made path validation 60% faster
- **Security**: Migration avoided several OpenSSL CVEs by not executing vulnerable C code paths
- **Trade-off**: Rust dependency eliminates some platform support (not all architectures have Rust compilers)
- **Wheel burden**: Ships 48 wheels per release; abi3 is critical for keeping this manageable

### orjson (JSON library)

- **Architecture**: Pure Rust via PyO3, no C dependencies
- **Performance**: `dumps()` ~10x faster than `json`, `loads()` ~2x faster
- **Correctness**: Stricter than stdlib json (proper UTF-8 validation, no duplicate keys)
- **Lesson**: Treat compiled extensions like uvloop/cryptography — pin versions, test in CI, platform-sensitive deployment

### ruff (Linter/Formatter) & uv (Package Manager)

- **Architecture**: Rust CLI tools with Python integration
- **Performance**: ruff 10-100x faster than Python-based linters; uv orders of magnitude faster than pip
- **Lesson**: Not all Rust-Python integration is via extension modules. CLI tools written in Rust that operate on Python codebases are equally impactful.

---

## Cross-Cutting Concerns

### GIL Management Strategies

**1. The GIL Token Pattern (PyO3)**
Encode GIL ownership in the type system. `Python<'py>` proves the GIL is held at compile time. All GIL-requiring APIs take this token.

**2. GIL Release for Computation**
`py.allow_threads()` (PyO3), `Py_BEGIN_ALLOW_THREADS` (C API). Release GIL during pure-native computation, re-acquire on return. Essential for not blocking Python threads.

**3. Per-Interpreter GIL (PEP 684, Python 3.12+)**
Each subinterpreter can have its own GIL via `Py_NewInterpreterFromConfig()`. Extensions using global state must either add locking or mark themselves as incompatible. Python raises `ImportError` if a per-interpreter-GIL subinterpreter imports an incompatible module.

**4. Free-Threaded Mode (Python 3.13+)**
GIL disabled entirely. See next section.

**5. Critical Sections (Python 3.13+)**
`Py_BEGIN_CRITICAL_SECTION(obj)` / `Py_END_CRITICAL_SECTION()` provides per-object locking. No-ops in GIL-enabled builds, active in free-threaded builds. Maximum 2 objects locked simultaneously. Automatic deadlock avoidance.

### Free-Threaded Mode

Python 3.13 introduced experimental free-threaded builds (3.13t). Python 3.14 significantly improved single-threaded performance overhead from ~40% to ~5-10%.

**Requirements for C extensions:**

1. **Declare GIL support** via `Py_mod_gil` slot (`Py_MOD_GIL_NOT_USED`) or the GIL is automatically re-enabled on import.

2. **Replace borrowed references** with strong reference APIs:
   - `PyList_GetItem()` -> `PyList_GetItemRef()`
   - `PyDict_GetItem()` -> `PyDict_GetItemRef()`
   - `PyWeakref_GetObject()` -> `PyWeakref_GetRef()`

3. **Use critical sections** around `PyDict_Next()` and other iterators.

4. **Memory allocation discipline**: only Python objects via `PyObject_Malloc()`, buffers via `PyMem_Malloc()`.

5. **Protect internal state**: add locks or use `thread_local` for caches and globals previously protected by GIL.

6. **Separate wheels**: free-threaded builds require separate wheels (tagged with `t` suffix).

7. **abi3 incompatible**: Limited API / Stable ABI not supported in free-threaded builds (until PEP 803 / abi3t in Python 3.15+).

**PyO3 implications**: `#[pyclass]` types must implement `Sync`. The `Python<'py>` token model adapts naturally — it still represents "permission to interact with the interpreter" even without a GIL.

### Async Bridging

**The fundamental problem**: Rust futures and Python coroutines are different abstractions with different event loop requirements. There is no way to run Rust futures directly on Python's event loop, and Python coroutines cannot be directly spawned on a Rust event loop.

**PyO3's solution (pyo3-async-runtimes)**:

- `into_future()` — converts Python coroutine into a Rust future
- `future_into_py()` — wraps a Rust future as a Python awaitable
- Architecture: surrender main thread to Python, run Rust event loops (tokio/async-std) in background threads
- `TaskLocals` stores current event loop and Python context, restored when crossing boundaries
- Supports task cancellation and contextvars preservation (0.15+)

**Alternative: PyO3/tokio event loop**
A drop-in replacement for asyncio's event loop, written in Rust with tokio. Performance close to uvloop. Supports TCP, Unix sockets, DNS, pipes, subprocess, signals. Missing: UDP.

**Key architectural insight**: The two-event-loop approach (Python asyncio + Rust tokio in background) is pragmatic but adds latency at crossings. A unified event loop would be ideal but requires solving fundamental differences in coroutine models.

### Memory Management

**CPython's model**: reference counting (primary) + generational garbage collector (cycle detection). Extensions must manually `Py_INCREF`/`Py_DECREF`.

**PyO3's approach**: `Py<T>` owns a reference (decrefs on drop). `Bound<'py, T>` borrows with GIL lifetime. The borrow checker prevents use-after-free at compile time. This is arguably the strongest safety story in the entire FFI landscape.

**HPy's approach**: Opaque handles (`HPy`) instead of raw pointers. Decouples from reference counting, enabling tracing GC implementations (GraalPy, future CPython).

**CyStck (research)**: Stack-based handles that copy 1-40% fewer bytes across the C/Python boundary compared to CPython API and HPy. Academic prototype, not production-ready.

**Practical guidance**:
- Minimize object creation at the boundary — pass buffers, not individual values
- Use `allow_threads` to release GIL during allocation-heavy Rust code
- Be aware that Python objects must be allocated with `PyObject_Malloc()`, not system `malloc()`
- In free-threaded mode, the object allocator is the only thread-safe allocator for Python objects

### Error Propagation

**C API pattern**: Set exception state via `PyErr_SetString()`, return NULL/error code. Callers must check and propagate.

**PyO3 pattern**: Return `PyResult<T>` (alias for `Result<T, PyErr>`). Rust errors convert to Python exceptions via `From<E> for PyErr`. Panics are caught at the boundary and become `PanicException`. This is the cleanest error propagation story: Rust's `?` operator naturally propagates through the call stack and surfaces as a Python exception at the boundary.

**nanobind pattern**: C++ exceptions are caught and converted to Python exceptions. `nb::python_error` represents a Python exception in C++.

**Best practices**:
- Never let Rust panics cross FFI boundaries (PyO3 handles this automatically)
- Never let C++ exceptions cross `extern "C"` boundaries
- Map domain errors to specific Python exception types, not generic `RuntimeError`
- Include context (values, types) in error messages for debuggability

### Buffer Protocol

The buffer protocol enables zero-copy data sharing between Python and native code. Objects expose their internal memory layout (pointer, shape, strides, format) via `Py_buffer`.

**Key implementations**:
- `bytes`, `bytearray`, `memoryview` — stdlib
- `numpy.ndarray` — the canonical multi-dimensional buffer
- PyTorch tensors, TensorFlow tensors — via DLPack and buffer protocol

**In extensions**:
- PyO3: `PyBuffer<T>` for reading, `#[pyclass]` can implement `__buffer__` protocol
- nanobind: zero-copy via DLPack (preferred) and buffer protocol, supporting NumPy, PyTorch, TF, JAX
- Ziggy Pydust: zero-copy NumPy compute over native Zig slices
- Cython: typed memoryviews (`cdef int[:] view = array`) for direct buffer access

**Performance insight**: using buffer protocol with memoryviews can bring Python code close to C performance for bulk data operations, even without writing any C. The key is avoiding per-element Python object creation.

### Type Stub Generation

**The problem**: Native extensions appear as opaque modules to type checkers and IDEs. `.pyi` stub files provide type information.

**Approaches**:

1. **mypy stubgen** — `stubgen -p mymodule`. Uses runtime introspection for C modules. Auto-generated stubs default most types to `Any`. Can parse `.rst` docs for better C extension signatures.

2. **PyO3 native support** — `#[pyo3(signature = (arg: "list[int]") -> "list[int]")]` embeds type annotations in Rust code. The `pyo3-stub-gen` crate generates `.pyi` files from these annotations semi-automatically. `mypy stubtest` validates stubs match runtime behavior.

3. **nanobind** — automatic `.pyi` generation is built-in. Stubs work with MyPy, Pyright, PyType.

4. **Cython** — generates `.pxd` files (Cython's equivalent) and can produce `.pyi` stubs.

5. **MonkeyType** — runtime type observation approach: run code (via tests), collect observed types, generate stubs.

---

## Academic Research

### "Rust vs. C for Python Libraries: Evaluating Rust-Compatible Bindings Toolchains" (2025)

- **Authors**: Amaral, Ferreira, Goldman (University of São Paulo)
- **ArXiv**: [2507.00264](https://arxiv.org/abs/2507.00264)
- **Submitted to**: SBAC-PAD 2025
- **Key findings**: PyO3 achieves performance competitive with NumPy while offering superior DX. Minimizing per-call data conversions through specialized constructors is key to high performance. PyO3 exhibits lower per-call overhead than NumPy in certain tasks.

### "Towards Reliable Memory Management for Python Native Extensions" (ICOOOLPS 2023)

- **Venue**: ECOOP/ISSTA 2023
- **Key contribution**: CyStck — a new FFI using stack-based handles that copies 1-40% fewer bytes across the boundary vs CPython API and HPy.

### "The Hidden Performance Overhead of Python C Extensions" (pythonspeed.com)

- **Key insight**: Even well-written C extensions have measurable overhead from the CPython API itself. The cost of argument parsing, object creation, and reference counting at the boundary can dominate for small, frequently-called functions.

---

## Comparative Summary

| Framework | Language | Maturity | Performance | Safety | Free-threaded | abi3 | Stub Gen |
|-----------|----------|----------|-------------|--------|---------------|------|----------|
| **PyO3** | Rust | Production | Excellent | Compile-time | Yes (0.23+) | Yes | Via pyo3-stub-gen |
| **maturin** | Rust (build) | Production | N/A | N/A | Yes | Yes | N/A |
| **nanobind** | C++17 | Production | Excellent | Runtime | Yes | Yes (3.12+) | Built-in |
| **Cython** | Python/C | Production | Good-Excellent | Limited | Partial | Yes | Partial |
| **CFFI** | C | Production | Good | Limited | Unknown | No | No |
| **HPy** | C | Pre-1.0 | Good (CPython), Excellent (alt) | Runtime debug | Unknown | N/A (own ABI) | No |
| **Ziggy Pydust** | Zig | Early production | Good | Comptime | Unknown | Yes (stable API) | No |
| **py.zig** | Zig | Alpha | Unknown | Limited | No | No | No |

### When to Use What

- **Rust extension with complex types**: PyO3 + maturin. The type system safety and ecosystem maturity are unmatched.
- **C++ library wrapping**: nanobind (modern) or pybind11 (legacy). nanobind if you can require C++17.
- **Accelerating Python hot loops**: Cython. Lowest barrier to entry, works with existing Python code.
- **Calling existing C libraries**: CFFI (API mode). No wrapper compilation needed for ABI mode.
- **Cross-implementation compatibility**: HPy. Only option for PyPy/GraalPy at native speed.
- **Zig extensions**: Ziggy Pydust. Only mature option.
- **C/C++ with CMake**: scikit-build-core. The standard for CMake-based Python packages.
- **Maximum deployment simplicity**: abi3 wheels. One wheel per platform, works across Python versions.

### The Emerging Stack (2025-2026)

The modern high-performance Python package looks like:
1. Core logic in Rust
2. PyO3 for bindings with `Bound<'py, T>` API
3. maturin for build/publish
4. abi3 wheels where possible (not free-threaded)
5. pyo3-stub-gen for type stubs
6. Separate free-threaded wheels for 3.13t+
7. pytest for integration testing, Rust tests for unit testing

This pattern is proven by pydantic-core, polars, cryptography, orjson, ruff, and uv — collectively serving millions of Python developers daily.


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-adf5b9c1fde9b9857.jsonl`
