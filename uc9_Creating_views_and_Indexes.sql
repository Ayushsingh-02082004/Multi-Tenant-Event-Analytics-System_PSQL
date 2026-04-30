---------------------------------UC 9--------------------------------

----  Creating the Materialized Views


-- 1. Materialized View: Daily Active Users (DAU)
CREATE MATERIALIZED VIEW mv_daily_active_users AS
SELECT 
    tenant_id,
    DATE(event_time) AS event_date,
    COUNT(DISTINCT user_id) AS dau
FROM events
GROUP BY tenant_id, DATE(event_time);

-- 2. Materialized View: Revenue Summary
CREATE MATERIALIZED VIEW mv_revenue_summary AS
SELECT 
    tenant_id,
    DATE(event_time) AS event_date,
    SUM((properties->>'amount')::NUMERIC) AS daily_revenue
FROM events
WHERE event_name = 'purchase'
GROUP BY tenant_id, DATE(event_time);



----- Add indexes on materialized views

-- Create UNIQUE composite indexes on both views
CREATE UNIQUE INDEX idx_mv_dau_tenant_date 
    ON mv_daily_active_users (tenant_id, event_date);

CREATE UNIQUE INDEX idx_mv_revenue_tenant_date 
    ON mv_revenue_summary (tenant_id, event_date);

-----   Implement refresh strategies (manual and concurrent)

-- Strategy A: Manual Refresh 
REFRESH MATERIALIZED VIEW mv_daily_active_users;

-- Strategy B: Concurrent Refresh
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_active_users;


-----  Automate refresh using cron

-- # Run at 2:00 AM every day
-- 0 2 * * * psql -U postgres -d analytics_db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_active_users;"
-- 0 2 * * * psql -U postgres -d analytics_db -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_revenue_summary;"