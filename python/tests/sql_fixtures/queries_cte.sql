-- CTE patterns: WITH, WITH RECURSIVE

-- Simple CTE
-- name: RecentIdeas :many
WITH recent AS (
    SELECT * FROM ideas WHERE created_at >= {since}
)
SELECT * FROM recent ORDER BY created_at DESC;

-- Recursive CTE: flat list result
-- name: Descendants :many
WITH RECURSIVE tree AS (
    SELECT t.* FROM todos t WHERE t.prev_todo_id = {root_id}
    UNION ALL
    SELECT t.* FROM todos t INNER JOIN tree ON t.prev_todo_id = tree.id
)
SELECT * FROM tree;

-- Recursive CTE: ancestors
-- name: Ancestors :many
WITH RECURSIVE chain AS (
    SELECT p.* FROM todos p
    JOIN todos child ON child.prev_todo_id = p.id
    WHERE child.id = {start_id}
    UNION ALL
    SELECT t.* FROM todos t JOIN chain ON chain.prev_todo_id = t.id
)
SELECT * FROM chain;
