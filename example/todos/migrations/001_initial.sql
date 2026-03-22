-- migration: 001_initial
-- created: 2026-03-21

create table users (
    id          bigserial primary key,
    email       text unique not null,
    name        text not null,
    password    text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index idx_users_email on users (email);

create table todos (
    id          bigserial primary key,
    user_id     bigint not null references users(id) on delete cascade,
    title       text not null,
    body        text not null default '',
    done        boolean not null default false,
    priority    smallint not null default 0,
    due_at      timestamptz,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index idx_todos_user_id on todos (user_id);
create index idx_todos_due_at on todos (due_at) where due_at is not null;
