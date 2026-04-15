
CREATE TABLE tenants (
    tenant_id VARCHAR(50) PRIMARY KEY,
    tenant_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);


CREATE TABLE users (
    tenant_id VARCHAR(50) REFERENCES tenants(tenant_id),
    user_id VARCHAR(50),
    email VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (tenant_id, user_id)
);


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


CREATE POLICY tenant_isolation_policy ON tenants
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));

CREATE POLICY user_isolation_policy ON users
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));

CREATE POLICY event_isolation_policy ON events
    FOR ALL USING (tenant_id = current_setting('app.current_tenant'));


------------UC 2 , 3 partition monthly and indexing-------------------------------


CREATE TABLE events_y2026m04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01 00:00:00Z') TO ('2026-05-01 00:00:00Z');


CREATE TABLE events_y2026m05 PARTITION OF events
    FOR VALUES FROM ('2026-05-01 00:00:00Z') TO ('2026-06-01 00:00:00Z');


-- Run this to show partition pruning.
EXPLAIN ANALYZE 
SELECT * FROM events 
WHERE event_time >= '2026-04-15' AND event_time < '2026-04-20';


-- 1. Composite Index (Tenant + Time)
CREATE INDEX idx_events_tenant_time ON events (tenant_id, event_time DESC);

CREATE INDEX idx_events_name ON events (event_name);

-- 3. GIN Index for JSONB properties
CREATE INDEX idx_events_properties_gin ON events USING GIN (properties jsonb_path_ops);




----------------UC 4 and 5 ----Data Ingestion and Trigger--------------------------


CREATE OR REPLACE FUNCTION ingest_event(
    p_event_id UUID,
    p_tenant_id VARCHAR(50),
    p_user_id VARCHAR(50),
    p_event_name VARCHAR(100),
    p_event_time TIMESTAMPTZ,
    p_properties JSONB
) RETURNS VOID AS $$
BEGIN
    INSERT INTO events (event_id, tenant_id, user_id, event_name, event_time, properties)
    VALUES (
        COALESCE(p_event_id, gen_random_uuid()), 
        p_tenant_id,
        p_user_id,
        p_event_name,
        COALESCE(p_event_time, NOW()),           
        p_properties
    )
    
    ON CONFLICT (tenant_id, event_time, event_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;





-- Trigger 1: Data Validation (Ensuring purchase amounts are not negative)
CREATE OR REPLACE FUNCTION trg_validate_purchase_event()
RETURNS TRIGGER AS $$
BEGIN
 
    IF NEW.event_name = 'purchase' THEN
        IF (NEW.properties->>'amount')::NUMERIC < 0 THEN
            RAISE EXCEPTION 'Data Integrity Error: Purchase amount cannot be negative for event_id %', NEW.event_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_validate_purchase
    BEFORE INSERT ON events
    FOR EACH ROW
    EXECUTE FUNCTION trg_validate_purchase_event();


-- Trigger 2: Automatic Data Enrichment (Timestamp updates)
CREATE OR REPLACE FUNCTION trg_enrich_event()
RETURNS TRIGGER AS $$
BEGIN
    
    NEW.properties = jsonb_set(NEW.properties, '{server_received_at}', to_jsonb(NOW()));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_enrich_event
    BEFORE INSERT ON events
    FOR EACH ROW
    EXECUTE FUNCTION trg_enrich_event();



INSERT INTO tenants (tenant_id, tenant_name) 
VALUES ('t1', 'Acme Corporation')
ON CONFLICT DO NOTHING;

-- Create the User second (linked to the Tenant)
INSERT INTO users (tenant_id, user_id, email) 
VALUES ('t1', 'u123', 'user123@acme.com')
ON CONFLICT DO NOTHING;


SELECT ingest_event(
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, 
    't1', 'u123', 'purchase', '2026-04-10 10:00:00Z', 
    '{"amount": 500, "device": "mobile"}'::jsonb
);

SELECT ingest_event(
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, 
    't1', 'u123', 'purchase', '2026-04-10 10:00:00Z', 
    '{"amount": 500, "device": "mobile"}'::jsonb
);


SELECT ingest_event(
    gen_random_uuid(), 
    't1', 'u123', 'purchase', '2026-04-10 10:00:00Z', 
    '{"amount": -50, "device": "mobile"}'::jsonb
);