-- Basic CRUD: SELECT *, INSERT RETURNING *, UPDATE RETURNING *, DELETE

-- name: GetIdea :one
SELECT * FROM ideas WHERE id = {id};

-- name: ListIdeas :many
SELECT * FROM ideas ORDER BY created_at DESC;

-- name: CreateIdea :one
INSERT INTO ideas (id, description, tags)
VALUES ({id}, {description}, {tags})
RETURNING *;

-- name: UpdateDescription :one
UPDATE ideas SET description = {description}
WHERE id = {id}
RETURNING *;

-- name: DeleteIdea :exec
DELETE FROM ideas WHERE id = {id};

-- name: DeleteOldIdeas :execrows
DELETE FROM ideas WHERE created_at < {before};
