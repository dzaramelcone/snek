"""snek.codegen — generate typed models and db methods from .sql files.

Reads CREATE TABLE schemas and annotated queries (sqlc-style),
emits Python model classes and typed Db method stubs.

Query parameter syntax: {name} → rewritten to $N positional params.
Query annotations: -- name: FuncName :one/:many/:exec/:execrows
"""


import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# PG type → Python type string
PG_TYPE_MAP: dict[str, str] = {
    "text": "str",
    "varchar": "str",
    "character varying": "str",
    "char": "str",
    "character": "str",
    "bpchar": "str",
    "citext": "str",
    "name": "str",
    "int2": "int",
    "int4": "int",
    "int8": "int",
    "smallint": "int",
    "integer": "int",
    "bigint": "int",
    "serial": "int",
    "bigserial": "int",
    "smallserial": "int",
    "float4": "float",
    "float8": "float",
    "real": "float",
    "double precision": "float",
    "numeric": "float",
    "decimal": "float",
    "money": "float",
    "int": "int",
    "float": "float",
    "boolean": "bool",
    "bool": "bool",
    "timestamp": "datetime",
    "timestamptz": "datetime",
    "timestamp with time zone": "datetime",
    "timestamp without time zone": "datetime",
    "date": "date",
    "time": "time",
    "timetz": "time",
    "time with time zone": "time",
    "time without time zone": "time",
    "interval": "timedelta",
    "uuid": "str",
    "json": "Any",
    "jsonb": "Any",
    "bytea": "bytes",
    "inet": "str",
    "cidr": "str",
    "macaddr": "str",
    "macaddr8": "str",
    "ltree": "str",
}

# PG type → JSON serialization strategy (for Zig side)
PG_ESCAPE_MAP: dict[str, str] = {
    "text": "escape",
    "varchar": "escape",
    "character varying": "escape",
    "char": "escape",
    "character": "escape",
    "bpchar": "escape",
    "citext": "escape",
    "name": "escape",
    "json": "raw",
    "jsonb": "raw",
    "bytea": "base64",
}
# Everything not listed defaults to "raw" (safe memcpy)


@dataclass
class Column:
    name: str
    pg_type: str
    python_type: str
    is_array: bool = False
    is_nullable: bool = True
    has_default: bool = False
    escape_strategy: str = "raw"


@dataclass
class Table:
    name: str
    columns: list[Column] = field(default_factory=list)


@dataclass
class QueryParam:
    name: str
    position: int  # $N position


@dataclass
class SelectItem:
    """One element in a SELECT clause."""
    alias: str  # table alias (e.g., "idea", "u") or "" for bare expressions
    column: str  # column name, "*" for expansion, or "" for expressions
    expression: str  # full expression text (for computed columns)
    as_name: str | None = None  # AS alias if present


@dataclass
class JoinInfo:
    """A table reference in FROM/JOIN clauses."""
    table: str  # actual table name
    alias: str  # alias used in query
    is_left: bool = False  # LEFT JOIN → nullable


@dataclass
class Query:
    name: str  # PascalCase from annotation
    func_name: str  # snake_case for Python method
    kind: str  # one, many, exec, execrows
    sql: str  # original SQL with {name} params
    wire_sql: str  # SQL with $N params for PG wire
    params: list[QueryParam] = field(default_factory=list)
    returns_table: str | None = None  # table name if simple SELECT * FROM table
    returns_columns: list[Column] = field(default_factory=list)
    select_items: list[SelectItem] = field(default_factory=list)
    joins: list[JoinInfo] = field(default_factory=list)


# ---------------------------------------------------------------------------
# SQL parsing
# ---------------------------------------------------------------------------

def parse_schemas(paths: list[Path]) -> dict[str, Table]:
    """Parse CREATE TABLE statements from schema files."""
    tables: dict[str, Table] = {}
    for path in sorted(paths):
        text = path.read_text()
        for match in re.finditer(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\((.*?)\);",
            text,
            re.DOTALL | re.IGNORECASE,
        ):
            table_name = match.group(1)
            body = match.group(2)
            columns = _parse_columns(body)
            if table_name in tables:
                tables[table_name].columns = columns
            else:
                tables[table_name] = Table(name=table_name, columns=columns)
    return tables


def _split_columns(body: str) -> list[str]:
    """Split column definitions on commas, respecting parentheses."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    for ch in body:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(ch)
    if current:
        parts.append("".join(current))
    return parts


def _parse_columns(body: str) -> list[Column]:
    """Parse column definitions from a CREATE TABLE body."""
    columns: list[Column] = []
    for line in _split_columns(body):
        line = line.strip()
        if not line:
            continue
        # Skip constraints
        upper = line.upper().lstrip()
        if any(upper.startswith(k) for k in (
            "PRIMARY KEY", "UNIQUE", "CHECK", "CONSTRAINT",
            "FOREIGN KEY", "EXCLUDE", "INDEX",
        )):
            continue

        parts = line.split()
        if len(parts) < 2:
            continue

        col_name = parts[0].strip('"')
        raw_type, is_array = _extract_type(parts[1:])
        pg_type = raw_type.lower()
        python_type = PG_TYPE_MAP.get(pg_type, "str")
        if is_array:
            python_type = f"list[{python_type}]"

        is_nullable = "NOT NULL" not in line.upper() and "PRIMARY KEY" not in line.upper()
        has_default = "DEFAULT" in line.upper() or "PRIMARY KEY" in line.upper()
        escape_strategy = PG_ESCAPE_MAP.get(pg_type, "raw")

        columns.append(Column(
            name=col_name,
            pg_type=pg_type,
            python_type=python_type,
            is_array=is_array,
            is_nullable=is_nullable,
            has_default=has_default,
            escape_strategy=escape_strategy,
        ))
    return columns


def _extract_type(parts: list[str]) -> tuple[str, bool]:
    """Extract PG type name and array flag from token list."""
    # Handle multi-word types: "double precision", "timestamp with time zone", etc.
    type_tokens: list[str] = []
    is_array = False
    for p in parts:
        upper = p.upper()
        if upper in ("NOT", "NULL", "DEFAULT", "PRIMARY", "KEY",
                     "UNIQUE", "CHECK", "REFERENCES", "GENERATED"):
            break
        if p.endswith("[]"):
            type_tokens.append(p[:-2])
            is_array = True
        elif upper == "ARRAY":
            is_array = True
        else:
            type_tokens.append(p)

    raw_type = " ".join(type_tokens).strip("\"'")
    # Strip precision: numeric(10,2) → numeric
    raw_type = re.sub(r"\(.*?\)", "", raw_type).strip()
    return raw_type, is_array


def _clean_query_body(raw: str) -> str:
    """Extract the SQL statement from a raw query body, stripping trailing comments."""
    # Find the last semicolon — everything after it is trailing comments/whitespace
    lines: list[str] = []
    found_semi = False
    for line in raw.split("\n"):
        stripped = line.strip()
        if found_semi:
            break
        if stripped.endswith(";"):
            lines.append(line)
            found_semi = True
        elif ";" in stripped:
            # Semicolon mid-line (e.g., DO $$ ... $$;)
            lines.append(line)
            found_semi = True
        else:
            lines.append(line)
    result = "\n".join(lines).strip()
    if result.endswith(";"):
        result = result[:-1].strip()
    return result


def parse_queries(path: Path, tables: dict[str, Table]) -> list[Query]:
    """Parse annotated queries from a query .sql file."""
    text = path.read_text()
    queries: list[Query] = []

    # Split on query annotations
    pattern = re.compile(
        r"--\s*name:\s*(\w+)\s+:(one|many|exec|execrows)\s*\n(.*?)(?=(?:--\s*name:|\Z))",
        re.DOTALL,
    )

    for match in pattern.finditer(text):
        name = match.group(1)
        kind = match.group(2)
        sql = _clean_query_body(match.group(3))

        func_name = _to_snake_case(name)
        params, wire_sql = _rewrite_params(sql)

        # Determine return columns
        returns_table = None
        returns_columns: list[Column] = []

        select_items: list[SelectItem] = []
        joins: list[JoinInfo] = []

        if kind in ("one", "many"):
            returns_table, returns_columns, select_items, joins = _infer_return_columns(sql, tables)

        queries.append(Query(
            name=name,
            func_name=func_name,
            kind=kind,
            sql=sql,
            wire_sql=wire_sql,
            params=params,
            returns_table=returns_table,
            returns_columns=returns_columns,
            select_items=select_items,
            joins=joins,
        ))

    return queries


def _rewrite_params(sql: str) -> tuple[list[QueryParam], str]:
    """Rewrite {name} params to $N positional params."""
    seen: dict[str, int] = {}
    params: list[QueryParam] = []

    def replacer(m: re.Match) -> str:
        name = m.group(1)
        if name in seen:
            return f"${seen[name]}"
        pos = len(params) + 1
        seen[name] = pos
        params.append(QueryParam(name=name, position=pos))
        return f"${pos}"

    # Skip string literals and $$ blocks
    wire_sql = _replace_outside_strings(sql, r"\{(\w+)\}", replacer)
    return params, wire_sql


def _replace_outside_strings(sql: str, pattern: str, replacer) -> str:
    """Apply regex replacement only outside of string literals and $$ blocks."""
    result: list[str] = []
    i = 0
    compiled = re.compile(pattern)

    while i < len(sql):
        # $$ dollar-quoted block
        if sql[i:i+2] == "$$":
            end = sql.find("$$", i + 2)
            if end == -1:
                result.append(sql[i:])
                break
            result.append(sql[i:end+2])
            i = end + 2
            continue

        # Single-quoted string
        if sql[i] == "'":
            j = i + 1
            while j < len(sql):
                if sql[j] == "'" and (j + 1 >= len(sql) or sql[j+1] != "'"):
                    break
                if sql[j] == "'" and j + 1 < len(sql) and sql[j+1] == "'":
                    j += 2
                    continue
                j += 1
            result.append(sql[i:j+1])
            i = j + 1
            continue

        # Try to match {param} at this position
        m = compiled.match(sql, i)
        if m:
            result.append(replacer(m))
            i = m.end()
            continue

        result.append(sql[i])
        i += 1

    return "".join(result)


def _parse_select_items(select_clause: str) -> list[SelectItem]:
    """Parse a SELECT clause into individual items."""
    items: list[SelectItem] = []
    # Split on commas, respecting parentheses
    parts = _split_respecting_parens(select_clause, ",")

    for part in parts:
        part = part.strip()
        if not part:
            continue

        # Check for AS alias
        as_name = None
        as_match = re.search(r"\bAS\s+(\w+)\s*$", part, re.IGNORECASE)
        if as_match:
            as_name = as_match.group(1)
            part = part[:as_match.start()].strip()

        # alias.* pattern
        star_match = re.match(r"^(\w+)\.\*$", part)
        if star_match:
            items.append(SelectItem(
                alias=star_match.group(1), column="*",
                expression=part, as_name=as_name,
            ))
            continue

        # alias.column pattern
        dot_match = re.match(r"^(\w+)\.(\w+)$", part)
        if dot_match:
            items.append(SelectItem(
                alias=dot_match.group(1), column=dot_match.group(2),
                expression=part, as_name=as_name,
            ))
            continue

        # Bare * (no alias)
        if part == "*":
            items.append(SelectItem(alias="", column="*", expression="*", as_name=as_name))
            continue

        # Bare column name (no alias)
        col_match = re.match(r"^(\w+)$", part)
        if col_match:
            items.append(SelectItem(
                alias="", column=col_match.group(1),
                expression=part, as_name=as_name,
            ))
            continue

        # Expression (aggregate, cast, subquery, etc.)
        items.append(SelectItem(
            alias="", column="",
            expression=part, as_name=as_name,
        ))

    return items


def _split_respecting_parens(text: str, sep: str) -> list[str]:
    """Split text on separator, respecting parentheses and quotes."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    in_quote = False

    for ch in text:
        if ch == "'" and not in_quote:
            in_quote = True
        elif ch == "'" and in_quote:
            in_quote = False
        elif not in_quote:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == sep and depth == 0:
                parts.append("".join(current))
                current = []
                continue
        current.append(ch)
    if current:
        parts.append("".join(current))
    return parts


def _parse_joins(sql: str) -> list[JoinInfo]:
    """Parse FROM and JOIN clauses to extract table aliases."""
    joins: list[JoinInfo] = []

    # Find the top-level FROM (not inside subqueries)
    from_pos = _find_keyword_at_depth(sql, "FROM", 0)
    if from_pos is None:
        return joins

    remaining = sql[from_pos + 4:].strip()

    # Find the end of the FROM/JOIN clause at depth 0
    end_keywords = ["WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "RETURNING"]
    end_pos = len(remaining)
    for kw in end_keywords:
        pos = _find_keyword_at_depth(remaining, kw, 0)
        if pos is not None and pos < end_pos:
            end_pos = pos
    # Also check ON CONFLICT
    oc_pos = _find_keyword_at_depth(remaining, "ON", 0)
    if oc_pos is not None:
        after_on = remaining[oc_pos + 2:].lstrip()
        if after_on.upper().startswith("CONFLICT"):
            if oc_pos < end_pos:
                end_pos = oc_pos

    from_clause = remaining[:end_pos].strip()

    # Split on JOIN keywords, preserving the join type
    # Pattern: table alias [LEFT|RIGHT|FULL|CROSS|INNER] JOIN table alias ON ...
    # First, extract the initial FROM table
    parts = re.split(r"\b((?:LEFT\s+|RIGHT\s+|FULL\s+|CROSS\s+|INNER\s+)?JOIN)\b", from_clause, flags=re.IGNORECASE)

    # First part is the FROM table(s)
    first = parts[0].strip()
    if first:
        for table_ref in _split_respecting_parens(first, ","):
            table_ref = table_ref.strip()
            if not table_ref:
                continue
            tm = re.match(r"(\w+)(?:\s+(?:AS\s+)?(\w+))?", table_ref, re.IGNORECASE)
            if tm:
                table = tm.group(1)
                alias = tm.group(2) or table
                joins.append(JoinInfo(table=table, alias=alias, is_left=False))

    # Process JOIN parts (pairs of join_type, join_clause)
    i = 1
    while i < len(parts) - 1:
        join_type = parts[i].strip().upper()
        join_clause = parts[i + 1].strip()
        is_left = "LEFT" in join_type

        # Remove ON clause
        on_idx = re.search(r"\bON\b", join_clause, re.IGNORECASE)
        table_part = join_clause[:on_idx.start()].strip() if on_idx else join_clause

        tm = re.match(r"(\w+)(?:\s+(?:AS\s+)?(\w+))?", table_part, re.IGNORECASE)
        if tm:
            table = tm.group(1)
            alias = tm.group(2) or table
            joins.append(JoinInfo(table=table, alias=alias, is_left=is_left))
        i += 2

    return joins


def _extract_select_clause(sql: str) -> str | None:
    """Extract the SELECT column list (between SELECT and FROM)."""
    # Handle WITH/CTE: find the final SELECT
    # For "WITH ... SELECT cols FROM ...", find the last SELECT
    upper = sql.upper()

    # Find RETURNING clause for INSERT/UPDATE/DELETE
    ret_match = re.search(r"\bRETURNING\s+(.+?)$", sql, re.IGNORECASE | re.DOTALL)
    if ret_match:
        return ret_match.group(1).strip()

    # Find the main SELECT (skip CTEs)
    # Strategy: find all SELECT positions, take the one before the main FROM
    select_positions = [m.start() for m in re.finditer(r"\bSELECT\b", upper)]
    if not select_positions:
        return None

    # For CTEs, the last SELECT is typically the main query
    # But nested subqueries complicate this. Use a simpler heuristic:
    # Find the SELECT that's NOT inside parentheses
    for pos in reversed(select_positions):
        # Count open parens before this position
        prefix = sql[:pos]
        depth = prefix.count("(") - prefix.count(")")
        if depth == 0:
            # This SELECT is at top level
            remaining = sql[pos + 6:].strip()  # skip "SELECT"
            # Find FROM at the same paren depth
            from_pos = _find_keyword_at_depth(remaining, "FROM", 0)
            if from_pos is not None:
                return remaining[:from_pos].strip()
            return remaining.strip()

    return None


def _find_keyword_at_depth(sql: str, keyword: str, target_depth: int) -> int | None:
    """Find the position of a keyword at a specific parenthesis depth."""
    depth = 0
    upper = sql.upper()
    kw_len = len(keyword)
    for i in range(len(sql)):
        if sql[i] == "(":
            depth += 1
        elif sql[i] == ")":
            depth -= 1
        elif depth == target_depth and upper[i:i+kw_len] == keyword:
            # Check word boundary
            if i > 0 and upper[i-1].isalnum():
                continue
            if i + kw_len < len(sql) and upper[i+kw_len].isalnum():
                continue
            return i
    return None


def _infer_return_columns(
    sql: str, tables: dict[str, Table]
) -> tuple[str | None, list[Column], list[SelectItem], list[JoinInfo]]:
    """Infer return columns from SELECT or RETURNING clause.

    Returns: (table_name_if_simple, columns, select_items, joins)
    """
    upper = sql.upper()

    # RETURNING * → get table from INSERT/UPDATE/DELETE
    if re.search(r"\bRETURNING\s+\*\s*$", sql, re.IGNORECASE):
        m = re.search(r"(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(\w+)", sql, re.IGNORECASE)
        if m:
            table_name = m.group(1)
            if table_name in tables:
                return table_name, list(tables[table_name].columns), [], []

    # Parse the SELECT clause and FROM/JOIN
    select_clause = _extract_select_clause(sql)
    if not select_clause:
        return None, [], [], []

    select_items = _parse_select_items(select_clause)
    joins = _parse_joins(sql)

    # Simple case: SELECT * FROM single_table (no joins)
    if (len(select_items) == 1 and select_items[0].column == "*"
            and select_items[0].alias == "" and len(joins) <= 1):
        if joins:
            table_name = joins[0].table
            if table_name in tables:
                return table_name, list(tables[table_name].columns), select_items, joins
        # Try regex fallback for CTEs
        m = re.search(r"\bSELECT\s+\*\s+FROM\s+(\w+)", sql, re.IGNORECASE)
        if m:
            table_name = m.group(1)
            if table_name in tables:
                return table_name, list(tables[table_name].columns), select_items, joins

    # Complex case: JOINs, partial selects, computed columns
    # Build columns from select items
    columns: list[Column] = []
    alias_to_table: dict[str, str] = {j.alias: j.table for j in joins}

    for item in select_items:
        if item.alias and item.column == "*":
            # alias.* → expand to all columns from that table
            table_name = alias_to_table.get(item.alias)
            if table_name and table_name in tables:
                for col in tables[table_name].columns:
                    columns.append(Column(
                        name=col.name, pg_type=col.pg_type,
                        python_type=col.python_type, is_array=col.is_array,
                        is_nullable=col.is_nullable, has_default=col.has_default,
                        escape_strategy=col.escape_strategy,
                    ))
        elif item.alias and item.column:
            # alias.column → single column from that table
            table_name = alias_to_table.get(item.alias)
            if table_name and table_name in tables:
                for col in tables[table_name].columns:
                    if col.name == item.column:
                        columns.append(Column(
                            name=col.name, pg_type=col.pg_type,
                            python_type=col.python_type, is_array=col.is_array,
                            is_nullable=col.is_nullable, has_default=col.has_default,
                            escape_strategy=col.escape_strategy,
                        ))
                        break
        elif item.as_name:
            # Expression AS name → infer type from cast if present
            py_type = _infer_expression_type(item.expression)
            columns.append(Column(
                name=item.as_name, pg_type="unknown",
                python_type=py_type, escape_strategy="raw",
            ))

    return None, columns, select_items, joins


def _infer_expression_type(expr: str) -> str:
    """Infer Python type from a SQL expression with casts."""
    upper = expr.upper()
    # Check for explicit casts: ::TYPE anywhere in expression (last one wins)
    # This handles subqueries like (SELECT COUNT(*)::INT FROM ...)
    cast_matches = list(re.finditer(r"::(\w[\w\s]*\w|\w)", expr, re.IGNORECASE))
    if cast_matches:
        pg_type = cast_matches[-1].group(1).strip().lower()
        mapped = PG_TYPE_MAP.get(pg_type)
        if mapped:
            return mapped
    # COUNT, SUM without cast
    if "COUNT" in upper:
        return "int"
    if "SUM" in upper or "AVG" in upper:
        return "float"
    return "Any"


def _to_snake_case(name: str) -> str:
    """Convert PascalCase/camelCase to snake_case."""
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.lower()


# ---------------------------------------------------------------------------
# Code emission
# ---------------------------------------------------------------------------

def emit_models(tables: dict[str, Table], queries: list[Query]) -> str:
    """Emit Python model classes."""
    lines: list[str] = [
        "# Generated by snek codegen. DO NOT EDIT.",
        "from datetime import date, datetime, time, timedelta",
        "from typing import Any",
        "",
        "from snek.models import Model",
        "",
    ]

    # Emit full table models referenced by queries
    emitted: set[str] = set()
    for q in queries:
        if q.returns_table and q.returns_table not in emitted:
            table = tables[q.returns_table]
            lines.extend(_emit_model_class(_to_class_name(table.name), table.columns))
            emitted.add(q.returns_table)

    # Emit nested row types for JOINs, partials, computed columns
    for q in queries:
        if q.returns_table or q.kind not in ("one", "many"):
            continue  # simple table return or exec — already handled
        if not q.select_items:
            continue

        row_lines = _emit_row_type(q, tables, emitted)
        lines.extend(row_lines)

    return "\n".join(lines)


def _emit_model_class(class_name: str, columns: list[Column]) -> list[str]:
    """Emit a single Model subclass."""
    lines = [
        "",
        f"class {class_name}(Model):",
    ]
    if not columns:
        lines.append("    pass")
    else:
        for col in columns:
            py_type = col.python_type
            if col.is_nullable and not col.has_default:
                py_type = f"{py_type} | None"
            lines.append(f"    {col.name}: {py_type}")
    lines.append("")
    return lines


def _emit_row_type(
    query: Query, tables: dict[str, Table], emitted: set[str]
) -> list[str]:
    """Emit nested row model for JOINs, partial selects, computed columns."""
    lines: list[str] = []
    row_class = query.name + "Row"
    alias_to_join: dict[str, JoinInfo] = {j.alias: j for j in query.joins}

    # Group select items by alias
    alias_items: dict[str, list[SelectItem]] = {}
    bare_items: list[SelectItem] = []
    for item in query.select_items:
        if item.alias:
            alias_items.setdefault(item.alias, []).append(item)
        else:
            bare_items.append(item)

    # Emit partial/nested types for each alias group
    row_fields: list[tuple[str, str]] = []  # (field_name, type_name)

    for alias, items in alias_items.items():
        join = alias_to_join.get(alias)
        table_name = join.table if join else None
        is_left = join.is_left if join else False

        if len(items) == 1 and items[0].column == "*" and table_name and table_name in tables:
            # alias.* → use full table model
            type_name = _to_class_name(table_name)
            # Ensure the full model is emitted
            if table_name not in emitted:
                table = tables[table_name]
                lines.extend(_emit_model_class(type_name, table.columns))
                emitted.add(table_name)
        else:
            # Partial select: alias.col1, alias.col2, ...
            partial_class = f"{row_class}{alias.capitalize()}"
            partial_cols: list[Column] = []
            if table_name and table_name in tables:
                table_cols = {c.name: c for c in tables[table_name].columns}
                for item in items:
                    if item.column and item.column in table_cols:
                        partial_cols.append(table_cols[item.column])
            lines.extend(_emit_model_class(partial_class, partial_cols))
            type_name = partial_class

        if is_left:
            type_name = f"{type_name} | None"
        row_fields.append((alias, type_name))

    # Add bare expression fields (computed columns)
    for item in bare_items:
        if item.as_name:
            py_type = _infer_expression_type(item.expression)
            row_fields.append((item.as_name, py_type))

    # Emit the row class
    lines.append("")
    lines.append(f"class {row_class}(Model):")
    if not row_fields:
        lines.append("    pass")
    else:
        for field_name, field_type in row_fields:
            lines.append(f"    {field_name}: {field_type}")
    lines.append("")

    return lines


def emit_queries(queries: list[Query], tables: dict[str, Table], models_module: str) -> str:
    """Emit Db class with typed query methods."""
    # Collect model imports
    model_names: set[str] = set()
    for q in queries:
        if q.returns_table and q.returns_table in tables:
            model_names.add(_to_class_name(q.returns_table))

    lines: list[str] = [
        "# Generated by snek codegen. DO NOT EDIT.",
        "from datetime import date, datetime, time, timedelta",
        "from typing import Any",
        "",
    ]
    if model_names:
        imports = ", ".join(sorted(model_names))
        lines.append(f"from {models_module} import {imports}")
        lines.append("")

    # SQL constants
    for q in queries:
        const_name = q.func_name.upper()
        lines.append(f'{const_name} = """{q.wire_sql}"""')
        lines.append("")

    # Db class
    lines.append("")
    lines.append("class Db:")

    for q in queries:
        lines.extend(_emit_query_method(q, tables))

    lines.append("")
    return "\n".join(lines)


def _emit_query_method(query: Query, tables: dict[str, Table]) -> list[str]:
    """Emit a single async method on the Db class."""
    # Build parameter signature
    params_sig = ""
    if query.params:
        param_parts = []
        for p in query.params:
            # Try to infer param type from the table column
            py_type = _infer_param_type(p.name, query, tables)
            param_parts.append(f"{p.name}: {py_type}")
        params_sig = ", *, " + ", ".join(param_parts)

    # Return type
    if query.kind == "one":
        model_name = _return_type_name(query, tables)
        ret_type = f"{model_name} | None"
    elif query.kind == "many":
        model_name = _return_type_name(query, tables)
        ret_type = f"list[{model_name}]"
    elif query.kind == "execrows":
        ret_type = "int"
    else:
        ret_type = "None"

    const_name = query.func_name.upper()

    lines = [
        "",
        f"    async def {query.func_name}(self{params_sig}) -> {ret_type}:",
    ]

    # Method body — yields the SQL + params to the pipeline
    if query.params:
        param_tuple = ", ".join(p.name for p in query.params)
        lines.append(f"        return (yield ({const_name}, ({param_tuple},)))")
    else:
        lines.append(f"        return (yield ({const_name}, ()))")

    lines.append("")
    return lines


def _return_type_name(query: Query, tables: dict[str, Table]) -> str:
    if query.returns_table:
        return _to_class_name(query.returns_table)
    if query.select_items:
        return query.name + "Row"
    return "dict"


def _infer_param_type(param_name: str, query: Query, tables: dict[str, Table]) -> str:
    """Try to match a param name to a column type."""
    # Direct name match against return table
    if query.returns_table and query.returns_table in tables:
        for col in tables[query.returns_table].columns:
            if col.name == param_name:
                return col.python_type
    # Direct name match against all tables
    for table in tables.values():
        for col in table.columns:
            if col.name == param_name:
                return col.python_type
    # Context-based: find what column the param is compared to in the SQL
    # e.g., "created_at < {before}" → before has same type as created_at
    col_type = _infer_param_type_from_context(param_name, query.sql, tables)
    if col_type:
        return col_type
    return "Any"


def _infer_param_type_from_context(param_name: str, sql: str, tables: dict[str, Table]) -> str | None:
    """Infer param type from the column it's compared to in SQL."""
    # Match patterns like: column_name OP {param_name}
    # where OP is =, !=, <, >, <=, >=, LIKE, ILIKE
    pattern = re.compile(
        r"(\w+)\s*(?:=|!=|<>|<=?|>=?|~~?\*?|(?:NOT\s+)?(?:I?LIKE))\s*\{" + re.escape(param_name) + r"\}",
        re.IGNORECASE,
    )
    m = pattern.search(sql)
    if m:
        col_name = m.group(1)
        for table in tables.values():
            for col in table.columns:
                if col.name == col_name:
                    return col.python_type
    return None


def _to_class_name(table_name: str) -> str:
    """Convert table_name to singular PascalCase class name."""
    name = "".join(w.capitalize() for w in table_name.split("_"))
    return _singularize(name)


_IRREGULAR_PLURALS: dict[str, str] = {
    "theses": "thesis",
    "analyses": "analysis",
    "bases": "basis",
    "crises": "crisis",
    "diagnoses": "diagnosis",
    "indices": "index",
    "matrices": "matrix",
    "vertices": "vertex",
    "appendices": "appendix",
    "people": "person",
    "children": "child",
    "men": "man",
    "women": "woman",
    "mice": "mouse",
    "data": "datum",
    "media": "medium",
    "criteria": "criterion",
    "phenomena": "phenomenon",
}


def _singularize(word: str) -> str:
    """English singularization with irregular plural support."""
    lower = word.lower()
    if lower in _IRREGULAR_PLURALS:
        singular = _IRREGULAR_PLURALS[lower]
        # Preserve original casing style
        if word[0].isupper():
            return singular.capitalize()
        return singular
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"
    if word.endswith("ses") and not word.endswith("sses"):
        return word[:-2]
    if word.endswith("es") and word[-3] in "shxz":
        return word[:-2]
    if word.endswith("us") or word.endswith("is"):
        return word  # status, basis, analysis (already singular)
    if word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def generate(
    schema_paths: list[Path],
    query_path: Path,
    output_dir: Path,
    models_module: str = "models",
) -> None:
    """Run the codegen pipeline."""
    tables = parse_schemas(schema_paths)
    queries = parse_queries(query_path, tables)

    output_dir.mkdir(parents=True, exist_ok=True)

    models_code = emit_models(tables, queries)
    (output_dir / "models.py").write_text(models_code)

    queries_code = emit_queries(queries, tables, models_module)
    (output_dir / "queries.py").write_text(queries_code)

    print(f"Generated {len(queries)} queries, "
          f"{sum(1 for q in queries if q.returns_table)} models "
          f"→ {output_dir}/")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python -m snek.codegen <schema_dir> <query.sql> [output_dir]")
        sys.exit(1)

    schema_dir = Path(sys.argv[1])
    query_file = Path(sys.argv[2])
    out_dir = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("gen")

    schema_files = sorted(schema_dir.glob("*.sql"))
    generate(schema_files, query_file, out_dir)
