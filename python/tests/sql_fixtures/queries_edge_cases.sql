-- Edge cases: string literals, casts, param reuse, dollar quoting

-- Param reuse across UNION ALL
-- name: CombinedSearch :many
SELECT id, description, created_at FROM ideas
WHERE created_at >= {start_at} AND created_at < {end_at}
UNION ALL
SELECT id, summary AS description, created_at FROM theses
WHERE created_at >= {start_at} AND created_at < {end_at};

-- String literal containing braces (must not be treated as param)
-- name: ListByStatus :many
SELECT * FROM todos WHERE status NOT IN ('closed', 'draft');

-- Cast next to param
-- name: FindByIds :many
SELECT * FROM ideas WHERE id = ANY({ids}::text[]);

-- Dollar-quoted block (must not scan inside)
-- name: RunMigration :exec
DO $$ BEGIN
    ALTER TABLE ideas ADD COLUMN IF NOT EXISTS color TEXT DEFAULT '{blue}';
END $$;

-- Escaped single quotes
-- name: FindByName :many
SELECT * FROM users WHERE name = {name} AND bio != 'it''s {complicated}';

-- ILIKE with param
-- name: SearchUsers :many
SELECT * FROM users WHERE name ILIKE {query} OR email ILIKE {query};

-- Multiple params in UPDATE with optimistic locking
-- name: UpdateTodoStatus :one
UPDATE todos SET status = {status}
WHERE id = {id} AND status = {expected_status}
RETURNING *;

-- No params at all
-- name: CountUsers :one
SELECT COUNT(*)::INT AS count FROM users;

-- Param adjacent to parens and commas
-- name: CreateOrder :one
INSERT INTO orders (user_id, total, status)
VALUES ({user_id},{total},{status})
RETURNING *;
