-- Computed columns: aggregates, casts, expressions alongside models

-- Model + scalar aggregate
-- name: GetIdeaWithThesisCount :one
SELECT idea.*, COUNT(thesis.id)::INT AS thesis_count
FROM ideas idea
LEFT JOIN theses thesis ON thesis.idea_id = idea.id
WHERE idea.id = {id}
GROUP BY idea.id;

-- Model + multiple computed columns
-- name: GetUserStats :one
SELECT u.*,
       COUNT(o.id)::INT AS order_count,
       COALESCE(SUM(o.total), 0)::FLOAT AS total_spent
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id = {id}
GROUP BY u.id;

-- Pure aggregate (no model, just scalars)
-- name: CountIdeas :one
SELECT COUNT(*)::INT AS count FROM ideas;

-- Multiple aggregates, no model
-- name: OrderStats :one
SELECT COUNT(*)::INT AS count,
       COALESCE(SUM(total), 0)::FLOAT AS total,
       COALESCE(AVG(total), 0)::FLOAT AS average
FROM orders
WHERE created_at >= {start_at} AND created_at < {end_at};

-- Subquery as computed column
-- name: GetIdeaWithSubqueryCount :one
SELECT idea.*,
       (SELECT COUNT(*)::INT FROM theses t WHERE t.idea_id = idea.id) AS thesis_count
FROM ideas idea
WHERE idea.id = {id};
