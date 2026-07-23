--DROP TABLE IF EXISTS container_repositories;
--DROP TABLE IF EXISTS container_accounts;
--DROP TABLE IF EXISTS container_platforms;
DROP TABLE IF EXISTS github_repositories;
DROP TABLE IF EXISTS github_accounts;

--CREATE TABLE container_platforms (
--    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--    name VARCHAR(255) NOT NULL UNIQUE,
--    pulls BIGINT DEFAULT 0,
--    stars INT DEFAULT 0,
--    created_at TIMESTAMPTZ DEFAULT NOW(),
--    updated_at TIMESTAMPTZ DEFAULT NOW(),
--    deleted_at TIMESTAMPTZ
--);
--
--CREATE TABLE container_accounts (
--    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--    name VARCHAR(255) NOT NULL,
--    platform_id UUID NOT NULL REFERENCES container_platforms(id),
--    pulls BIGINT DEFAULT 0,
--    stars INT DEFAULT 0,
--    created_at TIMESTAMPTZ DEFAULT NOW(),
--    updated_at TIMESTAMPTZ DEFAULT NOW(),
--    deleted_at TIMESTAMPTZ,
--    UNIQUE(name, platform_id)
--);
--
--CREATE TABLE container_repositories (
--    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--    name VARCHAR(255) NOT NULL,
--    account_id UUID NOT NULL REFERENCES container_accounts(id),
--    pulls BIGINT DEFAULT 0,
--    stars INT DEFAULT 0,
--    created_at TIMESTAMPTZ DEFAULT NOW(),
--    updated_at TIMESTAMPTZ DEFAULT NOW(),
--    deleted_at TIMESTAMPTZ,
--    UNIQUE(name, account_id)
--);

CREATE TABLE github_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    followers INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    UNIQUE(name)
);

CREATE TABLE task_runs (
    task_name   TEXT        PRIMARY KEY,
    last_run_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE task_run_attempts (
    id BIGSERIAL PRIMARY KEY,
    task_name TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    status TEXT NOT NULL,
    summary TEXT,
    repositories_processed INT NOT NULL DEFAULT 0,
    repositories_failed INT NOT NULL DEFAULT 0,
    accounts_processed INT NOT NULL DEFAULT 0,
    accounts_failed INT NOT NULL DEFAULT 0
);

CREATE INDEX idx_task_run_attempts_task_name_started_at
    ON task_run_attempts(task_name, started_at DESC);

CREATE TABLE github_repositories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    account_id UUID NOT NULL REFERENCES github_accounts(id),
    clones INT DEFAULT 0,
    forks INT DEFAULT 0,
    stars INT DEFAULT 0,
    subscribers INT DEFAULT 0,
    views BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    UNIQUE(name, account_id)
);
