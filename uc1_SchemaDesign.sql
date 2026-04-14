-- 1. Create the Tenants Table
CREATE TABLE tenants (
    tenant_id VARCHAR(50) PRIMARY KEY,
    tenant_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Create the Users Table
-- We use a composite primary key because user 'u123' might exist in multiple tenants independently.
CREATE TABLE users (
    tenant_id VARCHAR(50) REFERENCES tenants(tenant_id),
    user_id VARCHAR(50),
    email VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, user_id)
);

-- 3. Create the Events Table (The Fact Table)
-- We include event_time in the Primary Key because we will partition by time.
CREATE TABLE events (
    event_id UUID DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(50),
    user_id VARCHAR(50),
    event_name VARCHAR(100) NOT NULL,
    event_time TIMESTAMPTZ NOT NULL,
    properties JSONB DEFAULT '{}'::jsonb,
    PRIMARY KEY (tenant_id, event_time, event_id),
    FOREIGN KEY (tenant_id, user_id) REFERENCES users(tenant_id, user_id)
) PARTITION BY RANGE (event_time);

-- 4. Enable Row-Level Security (RLS) for Multi-Tenant Isolation
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

-- 5. Create Security Policies
-- This ensures queries only return data for the currently active tenant in the session.
CREATE POLICY tenant_isolation_policy ON tenants
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));

CREATE POLICY user_isolation_policy ON users
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));

CREATE POLICY event_isolation_policy ON events
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));


----UC 2 , 3 partition monthly and indexing-------------------------------

-- Partition for April 2026
CREATE TABLE events_y2026m04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01 00:00:00Z') TO ('2026-05-01 00:00:00Z');

-- Partition for May 2026
CREATE TABLE events_y2026m05 PARTITION OF events
    FOR VALUES FROM ('2026-05-01 00:00:00Z') TO ('2026-06-01 00:00:00Z');


-- Run this to show partition pruning
EXPLAIN ANALYZE 
SELECT * FROM events 
WHERE event_time >= '2026-04-15' AND event_time < '2026-04-20';


-- 1. Composite Index (Tenant + Time)
CREATE INDEX idx_events_tenant_time ON events (tenant_id, event_time DESC);

-- 2. Index on Event Name
CREATE INDEX idx_events_name ON events (event_name);

-- 3. GIN Index for JSONB properties
CREATE INDEX idx_events_properties_gin ON events USING GIN (properties jsonb_path_ops);