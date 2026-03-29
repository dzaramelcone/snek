-- Partial selects: specific columns from aliased tables

-- Partial columns from two tables
-- name: GetIdeaSummary :one
SELECT idea.id, idea.description, thesis.summary
FROM ideas idea
JOIN theses thesis ON thesis.idea_id = idea.id
WHERE idea.id = {id};

-- Single table partial (no nesting needed, but alias should still name the field)
-- name: GetUserEmail :one
SELECT u.id, u.email
FROM users u
WHERE u.id = {id};

-- Mixed: partial from one table, full from another
-- name: GetOrderWithUserName :one
SELECT o.*, u.name, u.email
FROM orders o
JOIN users u ON u.id = o.user_id
WHERE o.id = {id};
