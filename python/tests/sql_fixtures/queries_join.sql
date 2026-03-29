-- JOIN patterns: full model nesting, LEFT JOIN nullability, self-join

-- Full model nesting: alias.* on both sides
-- name: GetIdeaWithThesis :one
SELECT idea.*, thesis.*
FROM ideas idea
JOIN theses thesis ON thesis.idea_id = idea.id
WHERE idea.id = {id};

-- LEFT JOIN: thesis may be NULL
-- name: GetIdeaWithOptionalThesis :one
SELECT idea.*, thesis.*
FROM ideas idea
LEFT JOIN theses thesis ON thesis.idea_id = idea.id
WHERE idea.id = {id};

-- Multiple JOINs: three tables
-- name: GetOrderWithUser :one
SELECT o.*, u.*
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.id = {id};

-- Self-join: same table, different aliases
-- name: GetTodoWithParent :one
SELECT child.*, parent.*
FROM todos child
JOIN todos parent ON child.prev_todo_id = parent.id
WHERE child.id = {id};

-- LEFT self-join: parent may be NULL (root nodes)
-- name: GetTodoWithOptionalParent :one
SELECT child.*, parent.*
FROM todos child
LEFT JOIN todos parent ON child.prev_todo_id = parent.id
WHERE child.id = {id};

-- Many with join
-- name: ListIdeasWithTheses :many
SELECT idea.*, thesis.*
FROM ideas idea
JOIN theses thesis ON thesis.idea_id = idea.id
ORDER BY idea.created_at DESC;
