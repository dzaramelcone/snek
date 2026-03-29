-- Upsert patterns: ON CONFLICT, RETURNING

-- name: UpsertIdea :one
INSERT INTO ideas (id, description, tags)
VALUES ({id}, {description}, {tags})
ON CONFLICT (id) DO UPDATE
SET description = EXCLUDED.description, tags = EXCLUDED.tags
RETURNING *;

-- name: UpsertUser :one
INSERT INTO users (id, name, email)
VALUES ({id}, {name}, {email})
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name, email = EXCLUDED.email
RETURNING *;
