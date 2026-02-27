-- TamperTrail PostgreSQL initialization
-- This script runs once when the container is first created.

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Create the tenants table
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL UNIQUE,
    color VARCHAR(20) NOT NULL DEFAULT 'cyan',
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    allowed_environments JSONB NOT NULL DEFAULT '["production", "staging"]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Create the partitioned audit_logs table
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    tenant_id UUID NOT NULL,
    actor VARCHAR(255) NOT NULL,
    action VARCHAR(255) NOT NULL,
    level VARCHAR(10),
    message VARCHAR(1000),
    target_type VARCHAR(255),
    target_id VARCHAR(255),
    environment VARCHAR(100) DEFAULT 'production',
    metadata BYTEA,
    tags JSONB,
    source_ip INET,
    status VARCHAR(50) NOT NULL DEFAULT '200',
    user_agent_raw TEXT,
    device_type VARCHAR(16),
    request_id VARCHAR(255),
    prev_hash CHAR(64) NOT NULL,
    hash CHAR(64) NOT NULL,

    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Unique constraint on hash (includes partition key)
CREATE UNIQUE INDEX IF NOT EXISTS uq_audit_logs_hash ON audit_logs (hash, created_at);

-- Performance indexes
CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_created ON audit_logs (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_actor ON audit_logs (tenant_id, actor);
CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_action ON audit_logs (tenant_id, action);
CREATE INDEX IF NOT EXISTS ix_audit_logs_tenant_env ON audit_logs (tenant_id, environment);

-- GIN index for JSONB tags search
CREATE INDEX IF NOT EXISTS ix_audit_logs_tags ON audit_logs USING gin (tags jsonb_path_ops);

-- Create partitions for the current and next month
DO $$
DECLARE
    current_start DATE := date_trunc('month', CURRENT_DATE);
    current_end DATE := date_trunc('month', CURRENT_DATE) + INTERVAL '1 month';
    next_start DATE := date_trunc('month', CURRENT_DATE) + INTERVAL '1 month';
    next_end DATE := date_trunc('month', CURRENT_DATE) + INTERVAL '2 months';
    current_name TEXT := 'audit_logs_' || to_char(CURRENT_DATE, 'YYYY_MM');
    next_name TEXT := 'audit_logs_' || to_char(CURRENT_DATE + INTERVAL '1 month', 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF audit_logs FOR VALUES FROM (%L) TO (%L)',
        current_name, current_start, current_end
    );
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF audit_logs FOR VALUES FROM (%L) TO (%L)',
        next_name, next_start, next_end
    );
END $$;

-- Create the api_keys table
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    key_prefix CHAR(8) NOT NULL,
    key_hash TEXT NOT NULL,
    name VARCHAR(255),
    scopes TEXT[] NOT NULL DEFAULT '{}',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_api_keys_prefix ON api_keys (key_prefix);
CREATE INDEX IF NOT EXISTS ix_api_keys_tenant ON api_keys (tenant_id);

-- Demo logs: sample data that lives outside the hash chain and can be freely deleted
CREATE TABLE IF NOT EXISTS demo_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    tenant_id UUID NOT NULL,
    actor VARCHAR(255) NOT NULL,
    action VARCHAR(255) NOT NULL,
    level VARCHAR(10),
    message VARCHAR(1000),
    target_type VARCHAR(255),
    target_id VARCHAR(255),
    environment VARCHAR(100) DEFAULT 'production',
    tags JSONB,
    source_ip INET,
    status VARCHAR(50) NOT NULL DEFAULT '200',
    user_agent_raw TEXT,
    device_type VARCHAR(16),
    request_id VARCHAR(255)
);

CREATE INDEX IF NOT EXISTS ix_demo_logs_tenant_created ON demo_logs (tenant_id, created_at DESC);

-- Chain checkpoints: verified snapshots for retention-safe chain verification
CREATE TABLE IF NOT EXISTS chain_checkpoints (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    start_date TIMESTAMPTZ NOT NULL,
    end_date TIMESTAMPTZ NOT NULL,
    start_hash CHAR(64) NOT NULL,
    end_hash CHAR(64) NOT NULL,
    row_count INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, start_date, end_date)
);

CREATE INDEX IF NOT EXISTS ix_chain_checkpoints_tenant ON chain_checkpoints (tenant_id, end_date DESC);

-- Users: multi-user authentication with roles
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    username VARCHAR(100) NOT NULL,
    password_hash TEXT NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'viewer',
    permissions JSONB NOT NULL DEFAULT '{"view_logs":true,"export_logs":false,"manage_keys":false,"verify_integrity":false,"manage_users":false}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at TIMESTAMPTZ,
    UNIQUE (tenant_id, username)
);

CREATE INDEX IF NOT EXISTS ix_users_tenant ON users (tenant_id);
CREATE INDEX IF NOT EXISTS ix_users_username ON users (tenant_id, username);

-- User sessions: track login/logout history
CREATE TABLE IF NOT EXISTS user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL,
    login_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    logout_at TIMESTAMPTZ,
    ip_address INET,
    user_agent TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS ix_user_sessions_user ON user_sessions (user_id, login_at DESC);
CREATE INDEX IF NOT EXISTS ix_user_sessions_tenant_active ON user_sessions (tenant_id, is_active);

-- ── Immutability: block UPDATE and DELETE on audit logs ─────────
-- Audit logs are append-only. Even direct psql access cannot modify
-- or delete individual rows. The only way to remove data is via
-- partition DROP (used by the retention system for old months).

CREATE OR REPLACE FUNCTION prevent_audit_log_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_logs are immutable — % is prohibited. '
        'Audit logs are append-only to guarantee tamper-proof integrity.',
        TG_OP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Apply to the parent table — PostgreSQL propagates to all partitions
DROP TRIGGER IF EXISTS trg_immutable_audit_logs ON audit_logs;
CREATE TRIGGER trg_immutable_audit_logs
    BEFORE UPDATE OR DELETE ON audit_logs
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_mutation();

-- Also protect chain checkpoints (integrity records)
CREATE OR REPLACE FUNCTION prevent_checkpoint_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'chain_checkpoints are immutable — % is prohibited.',
        TG_OP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_immutable_checkpoints ON chain_checkpoints;
CREATE TRIGGER trg_immutable_checkpoints
    BEFORE UPDATE OR DELETE ON chain_checkpoints
    FOR EACH ROW EXECUTE FUNCTION prevent_checkpoint_mutation();

-- ── Row-Level Security (Defense in Depth) ──────────────────────
-- Even if application code forgets a WHERE tenant_id clause,
-- Postgres itself refuses to return another tenant's rows.

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_audit_logs ON audit_logs
    USING (tenant_id = NULLIF(current_setting('app.current_tenant', true), '')::uuid);

ALTER TABLE chain_checkpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE chain_checkpoints FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_checkpoints ON chain_checkpoints
    USING (tenant_id = NULLIF(current_setting('app.current_tenant', true), '')::uuid);

-- System settings: license key, retention config, etc.
CREATE TABLE IF NOT EXISTS system_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_key TEXT,
    log_retention_days INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed the default tenant
INSERT INTO tenants (id, name, color, is_default)
VALUES ('00000000-0000-0000-0000-000000000001', 'Default', 'cyan', TRUE)
ON CONFLICT (id) DO NOTHING;
