//! Fused decode+validate engine: parse JSON and validate constraints in a single
//! Zig pass (msgspec pattern). SchemaCompiler inspects Python type annotations at
//! import time and builds a Zig validation tree. Validation errors returned as
//! JSON without entering Python.
//!
//! Design: Never separate decode/validate. Constraint types are declarative via
//! Annotated types. Error accumulation: collect all errors, not just first
//! (configurable). Recursive schemas with cycle detection via memoization.
//!
//! Sources:
//!   - Fused decode+validate from msgspec — single biggest perf win
//!     (src/http/validate/REFERENCES.md)
//!   - Compiled validation 10-100x faster than interpreted (Blaze, Ajv)
//!   - SchemaCompiler three-layer architecture from pydantic-core
//!     (src/http/validate/REFERENCES.md)

const std = @import("std");

/// Validation error for a single field.
pub const ValidationError = struct {
    /// Dot-path to the field (e.g. "address.zip", "tags[2]").
    field: []const u8,
    /// Human-readable error message.
    message: []const u8,
    /// Machine-readable error code (e.g. "min_length", "pattern").
    code: []const u8,
    /// The invalid value (truncated for large values).
    input: ?[]const u8,
};

/// Collected validation result: either success with parsed data, or errors.
pub const ValidationResult = union(enum) {
    /// Validation passed. Parsed data available as raw bytes.
    ok: []const u8,
    /// Validation failed. All accumulated errors.
    errors: []const ValidationError,
};

/// Constraint types matching Python Annotated constraints.
pub const Constraint = union(enum) {
    gt: f64,
    ge: f64,
    lt: f64,
    le: f64,
    min_len: usize,
    max_len: usize,
    pattern: []const u8,
    email: void,
    one_of: []const []const u8,
    unique_items: void,
    /// Multiple of (for numeric types).
    multiple_of: f64,
};

/// Schema node types — tagged union matching Python type system.
pub const SchemaNode = union(enum) {
    /// `object` — a model with named fields.
    object: ObjectSchema,
    /// `array` — list[T], set[T].
    array: ArraySchema,
    /// `string` — str with optional constraints.
    string: StringSchema,
    /// `number` — int or float with optional constraints.
    number: NumberSchema,
    /// `boolean` — bool.
    boolean: void,
    /// `null_type` — None.
    null_type: void,
    /// `ref` — reference to another schema (for recursive types).
    ref: RefSchema,
    /// `union_type` — T | U, Optional[T].
    union_type: UnionSchema,
    /// `optional` — shorthand for T | None.
    optional: OptionalSchema,
    /// `enum_type` — Python enum.
    enum_type: EnumSchema,
};

pub const ObjectSchema = struct {
    fields: []const FieldSchema,
    /// Schema name (Python class name) for error messages.
    name: []const u8,
    /// Whether additional fields are allowed.
    allow_extra: bool,
};

pub const FieldSchema = struct {
    name: []const u8,
    schema: *const SchemaNode,
    required: bool,
    default: ?[]const u8,
    constraints: []const Constraint,
};

pub const ArraySchema = struct {
    items: *const SchemaNode,
    constraints: []const Constraint,
};

pub const StringSchema = struct {
    constraints: []const Constraint,
};

pub const NumberSchema = struct {
    is_integer: bool,
    constraints: []const Constraint,
};

pub const RefSchema = struct {
    /// Reference key into the definitions table (for recursive schemas).
    ref_key: []const u8,
};

pub const UnionSchema = struct {
    variants: []const *const SchemaNode,
};

pub const OptionalSchema = struct {
    inner: *const SchemaNode,
};

pub const EnumSchema = struct {
    values: []const []const u8,
};

/// Schema compiler: inspects Python type annotations at import time,
/// builds the Zig validation tree. Handles recursive schemas via a
/// definitions table with cycle detection (memoization).
/// Source: pydantic-core three-layer architecture — Python types -> schema IR -> compiled
/// validators (src/http/validate/REFERENCES.md).
pub const SchemaCompiler = struct {
    /// Definitions table for recursive schema resolution.
    definitions: [128]struct {
        key: []const u8,
        schema: *const SchemaNode,
    },
    def_count: usize,
    /// Memoization set for cycle detection during compilation.
    seen: [64][]const u8,
    seen_count: usize,

    pub fn init() SchemaCompiler {
        return undefined;
    }

    /// Compile a Python type annotation (via FFI) into a SchemaNode tree.
    pub fn compileFromAnnotations(self: *SchemaCompiler, annotations: *anyopaque) !*const SchemaNode {
        _ = .{ self, annotations };
        return undefined;
    }

    /// Register a named schema definition (for recursive references).
    pub fn addDefinition(self: *SchemaCompiler, key: []const u8, schema: *const SchemaNode) void {
        _ = .{ self, key, schema };
    }

    /// Resolve a ref schema to its definition.
    pub fn resolveRef(self: *const SchemaCompiler, ref_key: []const u8) ?*const SchemaNode {
        _ = .{ self, ref_key };
        return undefined;
    }
};

/// Validation configuration.
pub const ValidateConfig = struct {
    /// Whether to accumulate all errors or stop at first.
    accumulate_errors: bool = true,
    /// Maximum number of errors to accumulate before stopping.
    max_errors: usize = 100,
    /// Whether to coerce string values to target types (for query params).
    coerce: bool = false,
};

/// Fused decode+validate: parses JSON and validates constraints in a single pass.
/// Never decodes then validates separately.
/// Source: msgspec's single-pass decode+validate pattern (src/http/validate/REFERENCES.md).
pub const FusedDecodeValidator = struct {
    schema: *const SchemaNode,
    compiler: *const SchemaCompiler,
    config: ValidateConfig,

    pub fn init(schema: *const SchemaNode, compiler: *const SchemaCompiler, config: ValidateConfig) FusedDecodeValidator {
        _ = .{ schema, compiler, config };
        return undefined;
    }

    /// Parse and validate JSON bytes in a single pass. Returns parsed data
    /// or accumulated validation errors.
    pub fn validateJson(self: *const FusedDecodeValidator, json_bytes: []const u8) ValidationResult {
        _ = .{ self, json_bytes };
        return undefined;
    }

    /// Validate a single field value against its schema node.
    pub fn validateField(self: *const FusedDecodeValidator, field: []const u8, value: []const u8, node: *const SchemaNode) ?ValidationError {
        _ = .{ self, field, value, node };
        return undefined;
    }

    /// Validate a constraint against a numeric value.
    pub fn checkNumericConstraint(constraint: Constraint, value: f64) ?[]const u8 {
        _ = .{ constraint, value };
        return undefined;
    }

    /// Validate a constraint against a string value.
    pub fn checkStringConstraint(constraint: Constraint, value: []const u8) ?[]const u8 {
        _ = .{ constraint, value };
        return undefined;
    }
};

test "compile simple schema" {}

test "fused decode and validate" {}

test "nested model validation" {}

test "constraint validation" {}

test "error accumulation" {}

test "recursive schema cycle detection" {}

test "union type validation" {}

test "optional field validation" {}

test "enum validation" {}
