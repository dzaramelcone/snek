"""Contract tests for codegen using .sql fixture files.

Each test loads the shared schema + a query fixture file,
runs codegen, and asserts on the generated output.
"""

from pathlib import Path

from snek.codegen import emit_models, emit_queries, parse_queries, parse_schemas

FIXTURES = Path(__file__).parent / "sql_fixtures"
SCHEMA = FIXTURES / "schema.sql"


def _gen(query_file: str) -> tuple[str, str, list]:
    tables = parse_schemas([SCHEMA])
    queries = parse_queries(FIXTURES / query_file, tables)
    models = emit_models(tables, queries)
    db = emit_queries(queries, tables, "models")
    return models, db, queries


# ---------------------------------------------------------------------------
# Basic CRUD
# ---------------------------------------------------------------------------

class TestBasicCrud:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_basic.sql")

    def test_get_one(self):
        assert "async def get_idea(self, *, id: str) -> Idea | None:" in self.db

    def test_list_many(self):
        assert "async def list_ideas(self) -> list[Idea]:" in self.db

    def test_create_returning(self):
        assert "async def create_idea(self, *, id: str, description: str, tags: list[str]) -> Idea | None:" in self.db

    def test_update_returning(self):
        assert "async def update_description(self, *, description: str, id: str) -> Idea | None:" in self.db

    def test_delete_exec(self):
        assert "async def delete_idea(self, *, id: str) -> None:" in self.db

    def test_delete_execrows(self):
        assert "async def delete_old_ideas(self, *, before: datetime) -> int:" in self.db

    def test_model_fields(self):
        assert "class Idea(Model):" in self.models
        assert "    id: str" in self.models
        assert "    description: str" in self.models
        assert "    tags: list[str]" in self.models
        assert "    created_at: datetime" in self.models

    def test_params_rewritten(self):
        assert "{id}" not in self.db
        assert "{description}" not in self.db
        assert "$1" in self.db

    def test_no_optional_import(self):
        assert "Optional" not in self.models
        assert "Optional" not in self.db


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------

class TestUpsert:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_upsert.sql")

    def test_upsert_idea(self):
        assert "async def upsert_idea(self, *, id: str, description: str, tags: list[str]) -> Idea | None:" in self.db

    def test_upsert_sql_has_on_conflict(self):
        assert "ON CONFLICT" in self.db

    def test_upsert_returning(self):
        assert "RETURNING *" in self.db


# ---------------------------------------------------------------------------
# JOINs with nested models
# ---------------------------------------------------------------------------

class TestJoins:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_join.sql")

    def test_inner_join_nested_types(self):
        # SELECT idea.*, thesis.* → Row with idea: Idea, thesis: Thesis
        assert "idea: Idea" in self.models or "idea: Idea" in self.db
        assert "thesis: Thesis" in self.models or "thesis: Thesis" in self.db

    def test_left_join_nullable(self):
        # LEFT JOIN → thesis field should be optional
        q = next(q for q in self.queries if q.func_name == "get_idea_with_optional_thesis")
        assert q is not None
        # The nested thesis field should be Thesis | None in the row model
        combined = self.models + self.db
        assert "Thesis | None" in combined

    def test_self_join_different_aliases(self):
        # SELECT child.*, parent.* FROM todos child JOIN todos parent
        q = next(q for q in self.queries if q.func_name == "get_todo_with_parent")
        assert q is not None
        combined = self.models + self.db
        assert "child:" in combined.lower() or "child" in combined.lower()
        assert "parent:" in combined.lower() or "parent" in combined.lower()

    def test_left_self_join_nullable_parent(self):
        q = next(q for q in self.queries if q.func_name == "get_todo_with_optional_parent")
        assert q is not None
        combined = self.models + self.db
        assert "Todo | None" in combined


# ---------------------------------------------------------------------------
# Partial selects
# ---------------------------------------------------------------------------

class TestPartialSelects:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_partial.sql")

    def test_partial_two_tables(self):
        # SELECT idea.id, idea.description, thesis.summary
        # → nested partial types with only selected columns
        q = next(q for q in self.queries if q.func_name == "get_idea_summary")
        assert q is not None
        # Should have partial types with subset of fields
        assert "id: str" in self.models
        assert "description: str" in self.models
        assert "summary: str" in self.models

    def test_mixed_full_and_partial(self):
        # SELECT o.*, u.name, u.email
        q = next(q for q in self.queries if q.func_name == "get_order_with_user_name")
        assert q is not None
        # o.* should produce full Order fields
        # u.name, u.email should produce partial User type
        assert "name: str" in self.models
        assert "email: str" in self.models


# ---------------------------------------------------------------------------
# Computed columns
# ---------------------------------------------------------------------------

class TestComputedColumns:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_computed.sql")

    def test_model_plus_aggregate(self):
        # SELECT idea.*, COUNT(...)::INT AS thesis_count
        q = next(q for q in self.queries if q.func_name == "get_idea_with_thesis_count")
        assert q is not None
        combined = self.models + self.db
        assert "thesis_count" in combined

    def test_model_plus_multiple_aggregates(self):
        q = next(q for q in self.queries if q.func_name == "get_user_stats")
        assert q is not None
        combined = self.models + self.db
        assert "order_count" in combined
        assert "total_spent" in combined

    def test_pure_scalar(self):
        # SELECT COUNT(*)::INT AS count
        q = next(q for q in self.queries if q.func_name == "count_ideas")
        assert q is not None

    def test_multiple_scalars(self):
        q = next(q for q in self.queries if q.func_name == "order_stats")
        assert q is not None
        assert len(q.params) == 2
        assert q.params[0].name == "start_at"
        assert q.params[1].name == "end_at"

    def test_subquery_computed(self):
        q = next(q for q in self.queries if q.func_name == "get_idea_with_subquery_count")
        assert q is not None
        combined = self.models + self.db
        assert "thesis_count" in combined


# ---------------------------------------------------------------------------
# CTEs
# ---------------------------------------------------------------------------

class TestCtes:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_cte.sql")

    def test_simple_cte(self):
        q = next(q for q in self.queries if q.func_name == "recent_ideas")
        assert q is not None
        assert len(q.params) == 1
        assert q.params[0].name == "since"
        assert "$1" in q.wire_sql

    def test_recursive_cte(self):
        q = next(q for q in self.queries if q.func_name == "descendants")
        assert q is not None
        assert len(q.params) == 1
        assert q.params[0].name == "root_id"

    def test_recursive_ancestors(self):
        q = next(q for q in self.queries if q.func_name == "ancestors")
        assert q is not None
        assert len(q.params) == 1
        assert q.params[0].name == "start_id"


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def setup_method(self):
        self.models, self.db, self.queries = _gen("queries_edge_cases.sql")

    def test_param_reuse_union(self):
        q = next(q for q in self.queries if q.func_name == "combined_search")
        assert len(q.params) == 2  # start_at, end_at (not 4)
        assert q.wire_sql.count("$1") == 2  # start_at reused
        assert q.wire_sql.count("$2") == 2  # end_at reused

    def test_string_literal_no_params(self):
        q = next(q for q in self.queries if q.func_name == "list_by_status")
        assert len(q.params) == 0
        assert "'closed'" in q.wire_sql
        assert "'draft'" in q.wire_sql

    def test_cast_next_to_param(self):
        q = next(q for q in self.queries if q.func_name == "find_by_ids")
        assert len(q.params) == 1
        assert "$1::text[]" in q.wire_sql

    def test_dollar_quoted_block(self):
        q = next(q for q in self.queries if q.func_name == "run_migration")
        assert len(q.params) == 0  # {blue} inside $$ is NOT a param
        assert "{blue}" in q.wire_sql  # preserved verbatim

    def test_escaped_quotes(self):
        q = next(q for q in self.queries if q.func_name == "find_by_name")
        assert len(q.params) == 1
        assert q.params[0].name == "name"
        # {complicated} is inside quotes — NOT treated as a param
        assert "complicated" not in [p.name for p in q.params]
        assert "it''s {complicated}" in q.wire_sql  # preserved verbatim

    def test_ilike_param_reuse(self):
        q = next(q for q in self.queries if q.func_name == "search_users")
        assert len(q.params) == 1  # {query} used twice, same $1
        assert q.wire_sql.count("$1") == 2

    def test_optimistic_locking(self):
        q = next(q for q in self.queries if q.func_name == "update_todo_status")
        assert len(q.params) == 3
        param_names = [p.name for p in q.params]
        assert "status" in param_names
        assert "id" in param_names
        assert "expected_status" in param_names

    def test_no_params(self):
        q = next(q for q in self.queries if q.func_name == "count_users")
        assert len(q.params) == 0

    def test_adjacent_params(self):
        q = next(q for q in self.queries if q.func_name == "create_order")
        assert len(q.params) == 3
        assert "$1" in q.wire_sql
        assert "$2" in q.wire_sql
        assert "$3" in q.wire_sql
