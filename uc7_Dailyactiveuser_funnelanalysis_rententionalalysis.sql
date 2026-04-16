
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



CREATE INDEX idx_events_tenant_time ON events (tenant_id, event_time DESC);

CREATE INDEX idx_events_name ON events (event_name);

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


-----------------UC 6 ------Stored Procedure /functions-------------

CREATE OR REPLACE PROCEDURE cleanup_tenant_data(
    p_tenant_id VARCHAR, 
    p_batch_size INT DEFAULT 5000 
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted_count INT := 0;
    v_total_deleted INT := 0;
BEGIN
    RAISE NOTICE 'Starting data cleanup for tenant % in batches of %', p_tenant_id, p_batch_size;
    
    LOOP
        
        DELETE FROM events
        WHERE event_id IN (
            SELECT event_id FROM events
            WHERE tenant_id = p_tenant_id
            LIMIT p_batch_size
        );
        
    
        GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
        v_total_deleted := v_total_deleted + v_deleted_count; 
        COMMIT;
        
       
        EXIT WHEN v_deleted_count = 0;
    END LOOP;

    RAISE NOTICE 'Successfully deleted % events for tenant %', v_total_deleted, p_tenant_id;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK; 
        RAISE EXCEPTION 'Critical error during cleanup: %', SQLERRM;
END;
$$;





CREATE OR REPLACE PROCEDURE bulk_ingest_events(p_event_batch JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_event JSONB;
BEGIN
    IF jsonb_typeof(p_event_batch) != 'array' THEN
        RAISE EXCEPTION 'Input error: Payload must be a JSON array of events.';
    END IF;

    FOR v_event IN SELECT * FROM jsonb_array_elements(p_event_batch)
    LOOP
        BEGIN 
            INSERT INTO events (event_id, tenant_id, user_id, event_name, event_time, properties)
            VALUES (
                COALESCE((v_event->>'event_id')::UUID, gen_random_uuid()),
                v_event->>'tenant_id',
                v_event->>'user_id',
                v_event->>'event_name',
                COALESCE((v_event->>'event_time')::TIMESTAMPTZ, NOW()),
                v_event->'properties'
            )
            ON CONFLICT (tenant_id, event_time, event_id) DO NOTHING; -- Deduplication
            
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Skipping invalid event: % | Reason: %', v_event, SQLERRM;
        END;
    END LOOP;

    COMMIT; 
END;
$$;



CALL bulk_ingest_events(
    '[
        {"tenant_id": "t1", "user_id": "u123", "event_name": "page_view", "properties": {"url": "/home"}},
        {"tenant_id": "t1", "user_id": "u123", "event_name": "click", "properties": {"button": "signup"}}
    ]'::jsonb
);




-----------------------uc7---------------------------------------------------------------------------



SELECT
    tenant_id,
    DATE(event_time) AS event_date,
    COUNT(DISTINCT user_id) AS daily_active_users
FROM events
GROUP BY 
    tenant_id, 
    DATE(event_time)
ORDER BY 
    tenant_id, 
    event_date DESC;


	
WITH step_1_signup AS (
    SELECT tenant_id, user_id, MIN(event_time) AS signup_time
    FROM events
    WHERE event_name = 'signup'
    GROUP BY tenant_id, user_id
),
step_2_cart AS (
    SELECT e.tenant_id, e.user_id, MIN(e.event_time) AS cart_time
    FROM events e
    JOIN step_1_signup s1 ON e.tenant_id = s1.tenant_id AND e.user_id = s1.user_id
    WHERE e.event_name = 'add_to_cart' AND e.event_time > s1.signup_time
    GROUP BY e.tenant_id, e.user_id
),
step_3_purchase AS (
    SELECT e.tenant_id, e.user_id, MIN(e.event_time) AS purchase_time
    FROM events e
    JOIN step_2_cart s2 ON e.tenant_id = s2.tenant_id AND e.user_id = s2.user_id
    WHERE e.event_name = 'purchase' AND e.event_time > s2.cart_time
    GROUP BY e.tenant_id, e.user_id
)

SELECT
    s1.tenant_id,
    COUNT(DISTINCT s1.user_id) AS total_signups,
    COUNT(DISTINCT s2.user_id) AS total_add_to_cart,
    COUNT(DISTINCT s3.user_id) AS total_purchases,
    
    -- Calculate Drop-off / Conversion Percentages
    ROUND((COUNT(DISTINCT s2.user_id)::NUMERIC / NULLIF(COUNT(DISTINCT s1.user_id), 0)) * 100, 2) AS signup_to_cart_pct,
    ROUND((COUNT(DISTINCT s3.user_id)::NUMERIC / NULLIF(COUNT(DISTINCT s2.user_id), 0)) * 100, 2) AS cart_to_purchase_pct,
    ROUND((COUNT(DISTINCT s3.user_id)::NUMERIC / NULLIF(COUNT(DISTINCT s1.user_id), 0)) * 100, 2) AS overall_conversion_pct
FROM step_1_signup s1
LEFT JOIN step_2_cart s2 ON s1.tenant_id = s2.tenant_id AND s1.user_id = s2.user_id
LEFT JOIN step_3_purchase s3 ON s2.tenant_id = s3.tenant_id AND s2.user_id = s3.user_id
GROUP BY s1.tenant_id;




WITH user_cohorts AS (
    -- Step 1: Define the cohort (the first date a user ever triggered an event)
    SELECT tenant_id, user_id, DATE(MIN(event_time)) AS cohort_date
    FROM events
    GROUP BY tenant_id, user_id
),
user_active_days AS (
    -- Step 2: Get a unique list of all days a user was active
    SELECT DISTINCT tenant_id, user_id, DATE(event_time) AS active_date
    FROM events
)
-- Step 3: Compare their active days against their cohort date
SELECT
    c.tenant_id,
    c.cohort_date,
    COUNT(DISTINCT c.user_id) AS original_cohort_size,
    
    -- Day 1 Retention (Active exactly 1 day after cohort date)
    COUNT(DISTINCT CASE WHEN a.active_date = c.cohort_date + INTERVAL '1 day' THEN c.user_id END) AS day_1_retained,
    ROUND((COUNT(DISTINCT CASE WHEN a.active_date = c.cohort_date + INTERVAL '1 day' THEN c.user_id END)::NUMERIC / NULLIF(COUNT(DISTINCT c.user_id), 0)) * 100, 2) AS day_1_retention_pct,

    -- Day 7 Retention (Active exactly 7 days after cohort date)
    COUNT(DISTINCT CASE WHEN a.active_date = c.cohort_date + INTERVAL '7 days' THEN c.user_id END) AS day_7_retained,
    ROUND((COUNT(DISTINCT CASE WHEN a.active_date = c.cohort_date + INTERVAL '7 days' THEN c.user_id END)::NUMERIC / NULLIF(COUNT(DISTINCT c.user_id), 0)) * 100, 2) AS day_7_retention_pct

FROM user_cohorts c
LEFT JOIN user_active_days a 
    ON c.tenant_id = a.tenant_id AND c.user_id = a.user_id
GROUP BY 
    c.tenant_id, 
    c.cohort_date
ORDER BY 
    c.tenant_id, 
    c.cohort_date DESC;