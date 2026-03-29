CREATE TABLE ideas (
    id          TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    tags        TEXT[] NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE theses (
    id                  TEXT PRIMARY KEY,
    idea_id             TEXT NOT NULL REFERENCES ideas(id),
    summary             TEXT NOT NULL,
    epistemic_context   TEXT NOT NULL DEFAULT '',
    completion_criteria TEXT[] NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    promoted_to         TEXT
);

CREATE TABLE users (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL,
    bio        TEXT,
    is_active  BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id),
    total      NUMERIC(10,2) NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE todos (
    id            TEXT PRIMARY KEY,
    title         TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'open',
    prev_todo_id  TEXT REFERENCES todos(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
