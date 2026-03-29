-- Batch operations using UNNEST
-- Param names MUST match column names for :batch queries

-- name: CreateIdeaBatch :batch
INSERT INTO ideas (id, description)
SELECT * FROM UNNEST({id}::text[], {description}::text[])
RETURNING *;

-- name: UpdateIdeaBatch :batch
UPDATE ideas SET description = u.description
FROM UNNEST({id}::text[], {description}::text[]) AS u(id, description)
WHERE ideas.id = u.id
RETURNING ideas.*;
