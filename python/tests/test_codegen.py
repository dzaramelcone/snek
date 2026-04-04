"""Tests for snek.codegen — SQL parsing and code generation."""

import textwrap
from pathlib import Path
from tempfile import TemporaryDirectory

from snek.codegen import (
    Column,
    Query,
    QueryParam,
    SelectItem,
    Table,
    _infer_return_columns,
    _rewrite_params,
    _replace_outside_strings,
    _singularize,
    _to_class_name,
    _to_snake_case,
    emit_models,
    emit_queries,
    parse_queries,
    parse_schemas,
)


# ---------------------------------------------------------------------------
# Singularization
# ---------------------------------------------------------------------------

class TestSingularize:
    def test_regular_s(self):
        assert _singularize("Ideas") == "Idea"
        assert _singularize("Users") == "User"
        assert _singularize("Orders") == "Order"

    def test_ies(self):
        assert _singularize("Categories") == "Category"
        assert _singularize("Entries") == "Entry"

    def test_ses(self):
        assert _singularize("Addresses") == "Address"
        assert _singularize("Statuses") == "Status"

    def test_irregular(self):
        assert _singularize("Theses") == "Thesis"
        assert _singularize("Analyses") == "Analysis"
        assert _singularize("Children") == "Child"
        assert _singularize("People") == "Person"
        assert _singularize("Criteria") == "Criterion"
        assert _singularize("Data") == "Datum"
        assert _singularize("Media") == "Medium"

    def test_already_singular(self):
        assert _singularize("User") == "User"
        assert _singularize("Status") == "Status"

    def test_double_s(self):
        assert _singularize("Access") == "Access"
        assert _singularize("Progress") == "Progress"


class TestToSnakeCase:
    def test_pascal(self):
        assert _to_snake_case("GetIdea") == "get_idea"
        assert _to_snake_case("ListIdeas") == "list_ideas"
        assert _to_snake_case("CreateUser") == "create_user"

    def test_acronyms(self):
        assert _to_snake_case("GetHTTPResponse") == "get_http_response"
        assert _to_snake_case("ListAPIKeys") == "list_api_keys"

    def test_already_snake(self):
        assert _to_snake_case("get_idea") == "get_idea"


class TestToClassName:
    def test_simple(self):
        assert _to_class_name("ideas") == "Idea"
        assert _to_class_name("users") == "User"

    def test_multi_word(self):
        assert _to_class_name("call_sessions") == "CallSession"
        assert _to_class_name("pricing_schedule") == "PricingSchedule"

    def test_irregular(self):
        assert _to_class_name("theses") == "Thesis"
        assert _to_class_name("people") == "Person"


# ---------------------------------------------------------------------------
# Parameter rewriting
# ---------------------------------------------------------------------------

class TestRewriteParams:
    def test_simple(self):
        params, sql = _rewrite_params("SELECT * FROM t WHERE id = {id}")
        assert sql == "SELECT * FROM t WHERE id = $1"
        assert len(params) == 1
        assert params[0].name == "id"
        assert params[0].position == 1

    def test_multiple(self):
        params, sql = _rewrite_params(
            "INSERT INTO t (a, b) VALUES ({foo}, {bar})"
        )
        assert sql == "INSERT INTO t (a, b) VALUES ($1, $2)"
        assert params[0].name == "foo"
        assert params[1].name == "bar"

    def test_reuse(self):
        params, sql = _rewrite_params(
            "SELECT * FROM t WHERE a = {x} OR b = {x}"
        )
        assert sql == "SELECT * FROM t WHERE a = $1 OR b = $1"
        assert len(params) == 1

    def test_reuse_across_union(self):
        params, sql = _rewrite_params(
            "SELECT * FROM a WHERE t >= {start} "
            "UNION ALL "
            "SELECT * FROM b WHERE t >= {start} AND t < {end}"
        )
        assert sql == (
            "SELECT * FROM a WHERE t >= $1 "
            "UNION ALL "
            "SELECT * FROM b WHERE t >= $1 AND t < $2"
        )
        assert len(params) == 2
        assert params[0].name == "start"
        assert params[1].name == "end"

    def test_skip_string_literal(self):
        params, sql = _rewrite_params(
            "SELECT * FROM t WHERE name = '{not_a_param}' AND id = {id}"
        )
        assert sql == "SELECT * FROM t WHERE name = '{not_a_param}' AND id = $1"
        assert len(params) == 1
        assert params[0].name == "id"

    def test_skip_dollar_quoted(self):
        params, sql = _rewrite_params(
            "DO $$ BEGIN {not_a_param} END $$; SELECT {real}"
        )
        assert sql == "DO $$ BEGIN {not_a_param} END $$; SELECT $1"
        assert len(params) == 1
        assert params[0].name == "real"

    def test_with_pg_cast(self):
        params, sql = _rewrite_params(
            "SELECT * FROM t WHERE id = ANY({ids}::text[])"
        )
        assert sql == "SELECT * FROM t WHERE id = ANY($1::text[])"
        assert params[0].name == "ids"

    def test_escaped_single_quotes(self):
        params, sql = _rewrite_params(
            "SELECT * FROM t WHERE name = 'it''s {not_param}' AND id = {id}"
        )
        assert sql == "SELECT * FROM t WHERE name = 'it''s {not_param}' AND id = $1"
        assert len(params) == 1

    def test_no_params(self):
        params, sql = _rewrite_params("SELECT * FROM t ORDER BY id")
        assert sql == "SELECT * FROM t ORDER BY id"
        assert len(params) == 0

    def test_adjacent_to_parens(self):
        params, sql = _rewrite_params("VALUES ({a},{b},{c})")
        assert sql == "VALUES ($1,$2,$3)"
        assert len(params) == 3


# ---------------------------------------------------------------------------
# Schema parsing
# ---------------------------------------------------------------------------

class TestParseSchemas:
    def _parse(self, sql: str) -> dict[str, Table]:
        with TemporaryDirectory() as d:
            p = Path(d) / "schema.sql"
            p.write_text(sql)
            return parse_schemas([p])

    def test_basic_table(self):
        tables = self._parse("""
            CREATE TABLE users (
                id BIGSERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                bio TEXT
            );
        """)
        assert "users" in tables
        t = tables["users"]
        assert len(t.columns) == 3
        assert t.columns[0].name == "id"
        assert t.columns[0].pg_type == "bigserial"
        assert t.columns[0].python_type == "int"
        assert t.columns[0].is_nullable is False  # PRIMARY KEY
        assert t.columns[1].name == "name"
        assert t.columns[1].is_nullable is False  # NOT NULL
        assert t.columns[2].name == "bio"
        assert t.columns[2].is_nullable is True

    def test_array_type(self):
        tables = self._parse("""
            CREATE TABLE t (
                id TEXT PRIMARY KEY,
                tags TEXT[] NOT NULL DEFAULT '{}'
            );
        """)
        tags = tables["t"].columns[1]
        assert tags.is_array is True
        assert tags.python_type == "list[str]"

    def test_timestamp_types(self):
        tables = self._parse("""
            CREATE TABLE t (
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMP
            );
        """)
        assert tables["t"].columns[0].python_type == "datetime"
        assert tables["t"].columns[1].python_type == "datetime"

    def test_numeric_types(self):
        tables = self._parse("""
            CREATE TABLE t (
                a INT2,
                b INT4,
                c INT8,
                d FLOAT4,
                e FLOAT8,
                f BOOLEAN,
                g NUMERIC(10,2)
            );
        """)
        cols = tables["t"].columns
        assert cols[0].python_type == "int"
        assert cols[1].python_type == "int"
        assert cols[2].python_type == "int"
        assert cols[3].python_type == "float"
        assert cols[4].python_type == "float"
        assert cols[5].python_type == "bool"
        assert cols[6].python_type == "float"

    def test_skip_constraints(self):
        tables = self._parse("""
            CREATE TABLE t (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                UNIQUE (name),
                CONSTRAINT fk FOREIGN KEY (id) REFERENCES other(id)
            );
        """)
        assert len(tables["t"].columns) == 2

    def test_multiple_tables(self):
        tables = self._parse("""
            CREATE TABLE a (id TEXT PRIMARY KEY);
            CREATE TABLE b (id INT4 PRIMARY KEY, a_id TEXT REFERENCES a(id));
        """)
        assert "a" in tables
        assert "b" in tables
        assert len(tables["b"].columns) == 2

    def test_if_not_exists(self):
        tables = self._parse("""
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY
            );
        """)
        assert "users" in tables

    def test_escape_strategy(self):
        tables = self._parse("""
            CREATE TABLE t (
                name TEXT NOT NULL,
                data JSONB,
                created_at TIMESTAMPTZ,
                count INT4
            );
        """)
        cols = tables["t"].columns
        assert cols[0].escape_strategy == "escape"  # TEXT needs escaping
        assert cols[1].escape_strategy == "raw"  # JSONB is raw passthrough
        assert cols[2].escape_strategy == "raw"  # timestamp safe
        assert cols[3].escape_strategy == "raw"  # int safe

    def test_multiple_schema_files(self):
        with TemporaryDirectory() as d:
            (Path(d) / "0001.sql").write_text(
                "CREATE TABLE a (id TEXT PRIMARY KEY);"
            )
            (Path(d) / "0002.sql").write_text(
                "CREATE TABLE b (id TEXT PRIMARY KEY, a_id TEXT);"
            )
            tables = parse_schemas(sorted(Path(d).glob("*.sql")))
            assert "a" in tables
            assert "b" in tables


# ---------------------------------------------------------------------------
# Query parsing
# ---------------------------------------------------------------------------

class TestParseQueries:
    def _parse(self, schema_sql: str, query_sql: str) -> list[Query]:
        with TemporaryDirectory() as d:
            sp = Path(d) / "schema.sql"
            sp.write_text(schema_sql)
            qp = Path(d) / "query.sql"
            qp.write_text(query_sql)
            tables = parse_schemas([sp])
            return parse_queries(qp, tables)

    def test_select_one(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT NOT NULL);",
            "-- name: GetT :one\nSELECT * FROM t WHERE id = {id};",
        )
        assert len(queries) == 1
        q = queries[0]
        assert q.name == "GetT"
        assert q.func_name == "get_t"
        assert q.kind == "one"
        assert q.wire_sql == "SELECT * FROM t WHERE id = $1"
        assert q.returns_table == "t"
        assert len(q.returns_columns) == 2

    def test_select_many(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY);",
            "-- name: ListT :many\nSELECT * FROM t ORDER BY id;",
        )
        assert queries[0].kind == "many"

    def test_insert_returning(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT NOT NULL);",
            "-- name: CreateT :one\n"
            "INSERT INTO t (id, name) VALUES ({id}, {name}) RETURNING *;",
        )
        q = queries[0]
        assert q.kind == "one"
        assert q.returns_table == "t"
        assert len(q.params) == 2
        assert q.params[0].name == "id"
        assert q.params[1].name == "name"

    def test_update_returning(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT NOT NULL);",
            "-- name: UpdateT :one\n"
            "UPDATE t SET name = {name} WHERE id = {id} RETURNING *;",
        )
        q = queries[0]
        assert q.returns_table == "t"
        assert len(q.params) == 2

    def test_delete_exec(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY);",
            "-- name: DeleteT :exec\nDELETE FROM t WHERE id = {id};",
        )
        q = queries[0]
        assert q.kind == "exec"
        assert len(q.returns_columns) == 0

    def test_upsert(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT NOT NULL);",
            "-- name: UpsertT :one\n"
            "INSERT INTO t (id, name) VALUES ({id}, {name})\n"
            "ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name\n"
            "RETURNING *;",
        )
        q = queries[0]
        assert q.returns_table == "t"
        assert q.wire_sql.count("$1") == 1
        assert q.wire_sql.count("$2") == 1

    def test_cte(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY, parent_id TEXT);",
            "-- name: Descendants :many\n"
            "WITH RECURSIVE tree AS (\n"
            "    SELECT * FROM t WHERE parent_id = {root_id}\n"
            "    UNION ALL\n"
            "    SELECT t.* FROM t INNER JOIN tree ON t.parent_id = tree.id\n"
            ")\n"
            "SELECT * FROM tree;",
        )
        q = queries[0]
        assert q.func_name == "descendants"
        assert len(q.params) == 1
        assert q.params[0].name == "root_id"
        assert "$1" in q.wire_sql

    def test_multiple_queries(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY);",
            "-- name: GetT :one\n"
            "SELECT * FROM t WHERE id = {id};\n\n"
            "-- name: ListT :many\n"
            "SELECT * FROM t;\n\n"
            "-- name: DeleteT :exec\n"
            "DELETE FROM t WHERE id = {id};",
        )
        assert len(queries) == 3
        assert queries[0].func_name == "get_t"
        assert queries[1].func_name == "list_t"
        assert queries[2].func_name == "delete_t"

    def test_param_reuse_in_union(self):
        queries = self._parse(
            "CREATE TABLE a (id TEXT PRIMARY KEY, t TIMESTAMPTZ);\n"
            "CREATE TABLE b (id TEXT PRIMARY KEY, t TIMESTAMPTZ);",
            "-- name: Combined :many\n"
            "SELECT * FROM a WHERE t >= {start_at}\n"
            "UNION ALL\n"
            "SELECT * FROM b WHERE t >= {start_at} AND t < {end_at};",
        )
        q = queries[0]
        assert len(q.params) == 2
        assert q.wire_sql.count("$1") == 2  # reused
        assert q.wire_sql.count("$2") == 1

    def test_execrows(self):
        queries = self._parse(
            "CREATE TABLE t (id TEXT PRIMARY KEY);",
            "-- name: DeleteOld :execrows\n"
            "DELETE FROM t WHERE id = {id};",
        )
        assert queries[0].kind == "execrows"


# ---------------------------------------------------------------------------
# Code emission
# ---------------------------------------------------------------------------

class TestEmitModels:
    def test_basic_model(self):
        tables = {
            "users": Table("users", [
                Column("id", "text", "str", has_default=True),
                Column("name", "text", "str", is_nullable=False),
                Column("bio", "text", "str", is_nullable=True),
            ]),
        }
        queries = [Query("GetUser", "get_user", "one", "", "", returns_table="users")]
        code = emit_models(tables, queries)
        assert "class User(Model):" in code
        assert "id: str" in code
        assert "name: str" in code
        assert "bio: str | None" in code

    def test_array_field(self):
        tables = {
            "items": Table("items", [
                Column("tags", "text", "list[str]", is_array=True, is_nullable=False),
            ]),
        }
        queries = [Query("ListItems", "list_items", "many", "", "", returns_table="items")]
        code = emit_models(tables, queries)
        assert "tags: list[str]" in code

    def test_no_optional_import(self):
        tables = {"t": Table("t", [Column("id", "text", "str")])}
        queries = [Query("GetT", "get_t", "one", "", "", returns_table="t")]
        code = emit_models(tables, queries)
        assert "Optional" not in code


class TestEmitQueries:
    def test_one_method(self):
        tables = {
            "users": Table("users", [
                Column("id", "text", "str", has_default=True),
                Column("name", "text", "str"),
            ]),
        }
        queries = [Query(
            "GetUser", "get_user", "one",
            "SELECT * FROM users WHERE id = {id}",
            "SELECT * FROM users WHERE id = $1",
            params=[QueryParam("id", 1)],
            returns_table="users",
        )]
        code = emit_queries(queries, tables, "models")
        assert "def get_user(self, *, id: str) -> Awaitable[User | None]:" in code

    def test_many_method(self):
        tables = {"t": Table("t", [Column("id", "text", "str")])}
        queries = [Query("ListT", "list_t", "many", "", "", returns_table="t")]
        code = emit_queries(queries, tables, "models")
        assert "-> Awaitable[list[T]]:" in code

    def test_model_methods_emit_typed_pg_sentinels(self):
        tables = {
            "users": Table("users", [
                Column("id", "text", "str", has_default=True),
                Column("name", "text", "str"),
            ]),
        }
        queries = [Query(
            "GetUser", "get_user", "one",
            "SELECT * FROM users WHERE id = {id}",
            "SELECT * FROM users WHERE id = $1",
            params=[QueryParam("id", 1)],
            returns_table="users",
        )]
        code = emit_queries(queries, tables, "models")
        assert "return _snek.pg_fetch_one_model(GET_USER, (id,), User)" in code

    def test_row_models_are_imported_for_typed_queries(self):
        query = Query(
            "GetStats",
            "get_stats",
            "one",
            "SELECT COUNT(*)::INT AS count",
            "SELECT COUNT(*)::INT AS count",
            select_items=[SelectItem(alias="", column="", expression="COUNT(*)::INT", as_name="count")],
        )
        code = emit_queries([query], {}, "models")
        assert "from models import GetStatsRow" in code
        assert "return _snek.pg_fetch_one_model(GET_STATS, (), GetStatsRow)" in code

    def test_exec_method(self):
        tables = {"t": Table("t", [Column("id", "text", "str")])}
        queries = [Query(
            "DeleteT", "delete_t", "exec", "", "",
            params=[QueryParam("id", 1)],
        )]
        code = emit_queries(queries, tables, "models")
        assert "-> Awaitable[None]:" in code

    def test_execrows_method(self):
        tables = {"t": Table("t", [Column("id", "text", "str")])}
        queries = [Query(
            "DeleteOld", "delete_old", "execrows", "", "",
            params=[QueryParam("id", 1)],
        )]
        code = emit_queries(queries, tables, "models")
        assert "-> Awaitable[int]:" in code

    def test_sql_constants(self):
        queries = [Query(
            "GetUser", "get_user", "one",
            "", "SELECT * FROM users WHERE id = $1",
        )]
        code = emit_queries(queries, {}, "models")
        assert 'GET_USER = """SELECT * FROM users WHERE id = $1"""' in code

    def test_no_future_import(self):
        queries = [Query("GetT", "get_t", "one", "", "")]
        code = emit_queries(queries, {}, "models")
        assert "__future__" not in code
        assert "import types" not in code


# ---------------------------------------------------------------------------
# Integration: end-to-end from .sql files
# ---------------------------------------------------------------------------

class TestEndToEnd:
    def _run(self, schema_sql: str, query_sql: str) -> tuple[str, str]:
        with TemporaryDirectory() as d:
            sp = Path(d) / "schema.sql"
            sp.write_text(schema_sql)
            qp = Path(d) / "query.sql"
            qp.write_text(query_sql)
            tables = parse_schemas([sp])
            queries = parse_queries(qp, tables)
            models = emit_models(tables, queries)
            db = emit_queries(queries, tables, "models")
            return models, db

    def test_full_crud(self):
        models, db = self._run(
            "CREATE TABLE ideas (\n"
            "    id TEXT PRIMARY KEY,\n"
            "    description TEXT NOT NULL,\n"
            "    tags TEXT[] NOT NULL DEFAULT '{}',\n"
            "    created_at TIMESTAMPTZ NOT NULL DEFAULT now()\n"
            ");",
            "-- name: GetIdea :one\n"
            "SELECT * FROM ideas WHERE id = {id};\n\n"
            "-- name: ListIdeas :many\n"
            "SELECT * FROM ideas ORDER BY created_at DESC;\n\n"
            "-- name: CreateIdea :one\n"
            "INSERT INTO ideas (id, description, tags)\n"
            "VALUES ({id}, {description}, {tags})\n"
            "RETURNING *;\n\n"
            "-- name: DeleteIdea :exec\n"
            "DELETE FROM ideas WHERE id = {id};\n\n"
            "-- name: UpsertIdea :one\n"
            "INSERT INTO ideas (id, description, tags)\n"
            "VALUES ({id}, {description}, {tags})\n"
            "ON CONFLICT (id) DO UPDATE\n"
            "SET description = EXCLUDED.description, tags = EXCLUDED.tags\n"
            "RETURNING *;",
        )
        # Models
        assert "class Idea(Model):" in models
        assert "id: str" in models
        assert "description: str" in models
        assert "tags: list[str]" in models
        assert "created_at: datetime" in models
        assert "Optional" not in models

        # Db methods
        assert "def get_idea(self, *, id: str) -> Awaitable[Idea | None]:" in db
        assert "def list_ideas(self) -> Awaitable[list[Idea]]:" in db
        assert "def create_idea(self, *, id: str, description: str, tags: list[str]) -> Awaitable[Idea | None]:" in db
        assert "def delete_idea(self, *, id: str) -> Awaitable[None]:" in db
        assert "def upsert_idea(self, *, id: str, description: str, tags: list[str]) -> Awaitable[Idea | None]:" in db
        assert "@types.coroutine" not in db

        # SQL constants
        assert "$1" in db
        assert "{id}" not in db  # all params rewritten

    def test_string_literal_safety(self):
        _, db = self._run(
            "CREATE TABLE t (id TEXT PRIMARY KEY, status TEXT NOT NULL);",
            "-- name: ListOpen :many\n"
            "SELECT * FROM t WHERE status NOT IN ('closed', 'draft');",
        )
        assert "closed" in db
        assert "draft" in db
        assert "$" not in db  # no params

    def test_cast_safety(self):
        _, db = self._run(
            "CREATE TABLE t (id TEXT PRIMARY KEY);",
            "-- name: FindByIds :many\n"
            "SELECT * FROM t WHERE id = ANY({ids}::text[]);",
        )
        assert "$1::text[]" in db
        assert len([l for l in db.split("\n") if "ids" in l and "def " in l]) == 1

    def test_bare_column_scalars_do_not_require_aliases(self):
        models, db = self._run(
            "CREATE TABLE ideas (\n"
            "    id TEXT PRIMARY KEY,\n"
            "    description TEXT NOT NULL,\n"
            "    created_at TIMESTAMPTZ NOT NULL DEFAULT now()\n"
            ");",
            "-- name: GetIdeaLite :one\n"
            "SELECT id, description, created_at FROM ideas WHERE id = {id};",
        )
        assert "class GetIdeaLiteRow(Model):" in models
        assert "    id: str" in models
        assert "    description: str" in models
        assert "    created_at: datetime" in models
        assert "def get_idea_lite(self, *, id: str) -> Awaitable[GetIdeaLiteRow | None]:" in db

    def test_mixed_alias_and_bare_scalars_track_field_order(self):
        schema_sql = (
            "CREATE TABLE ideas (\n"
            "    id TEXT PRIMARY KEY,\n"
            "    description TEXT NOT NULL\n"
            ");\n"
            "CREATE TABLE theses (\n"
            "    id TEXT PRIMARY KEY,\n"
            "    idea_id TEXT NOT NULL REFERENCES ideas(id),\n"
            "    summary TEXT NOT NULL\n"
            ");"
        )
        query_sql = (
            "-- name: GetIdeaWithBareSummary :one\n"
            "SELECT idea.id, idea.description, summary\n"
            "FROM ideas idea\n"
            "JOIN theses thesis ON thesis.idea_id = idea.id\n"
            "WHERE idea.id = {id};"
        )
        models, db = self._run(schema_sql, query_sql)
        assert "class GetIdeaWithBareSummaryRow(Model):" in models
        assert "class GetIdeaWithBareSummaryRowIdea(Model):" in models
        assert "    idea: GetIdeaWithBareSummaryRowIdea" in models
        assert "    summary: str" in models
        assert "    __snek_field_order__ = ('idea', 'summary')" in models
        assert "    __snek_scalar_indexes__ = {'summary': 2}" in models
        assert "def get_idea_with_bare_summary(self, *, id: str) -> Awaitable[GetIdeaWithBareSummaryRow | None]:" in db
