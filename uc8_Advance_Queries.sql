----------------------------------UC8------------------------------------------------

--Section A--------------

---- Top 5 most active users per tenant

WITH RankedUsers AS (
    SELECT 
        tenant_id, 
        user_id, 
        COUNT(*) AS total_events,
        ROW_NUMBER() OVER (PARTITION BY tenant_id ORDER BY COUNT(*) DESC) as rank
    FROM events
    GROUP BY tenant_id, user_id
)
SELECT tenant_id, user_id, total_events
FROM RankedUsers
WHERE rank <= 5;


----  Event distribution per tenant by event type

SELECT 
    tenant_id, 
    event_name, 
    COUNT(*) AS total_count
FROM events
GROUP BY 
    tenant_id, 
    event_name
ORDER BY 
    tenant_id, 
    total_count DESC;


----  Total revenue per tenant (from JSONB field)

SELECT 
    tenant_id,
    SUM( (properties->>'amount')::NUMERIC ) AS total_revenue
FROM events
WHERE event_name = 'purchase'
GROUP BY tenant_id;


------------------------------------------------------------------------------


select * from tenants


SELECT 
    tenant_id, 
    COUNT(*) as total_users 
FROM users
GROUP BY tenant_id
ORDER BY tenant_id;


SELECT 
    tenant_id, 
    user_id, 
    event_name, 
    event_time, 
    properties 
FROM events
ORDER BY event_time DESC;

select * from events

----------------------Section B----------------------------------------------------

---- Users with no activity (LEFT JOIN + NULL filtering)

SELECT 
    u.tenant_id, 
    u.user_id, 
    u.email
FROM users u
LEFT JOIN events e 
    ON u.tenant_id = e.tenant_id AND u.user_id = e.user_id
WHERE e.event_id IS NULL;

----  Identify users associated with multiple tenants

SELECT 
    user_id, 
    COUNT(DISTINCT tenant_id) AS tenant_count
FROM users
GROUP BY user_id
HAVING COUNT(DISTINCT tenant_id) > 1;


------------------------------- Section c -----------------------------------------------------

----- First event per user using ROW_NUMBER

WITH RankedEvents AS (
    SELECT 
        tenant_id, 
        user_id, 
        event_name, 
        event_time,
        -- Hand out a rank based on time (Oldest to Newest)
        ROW_NUMBER() OVER (PARTITION BY tenant_id, user_id ORDER BY event_time ASC) as chronological_rank
    FROM events
)
SELECT 
    tenant_id, 
    user_id, 
    event_name AS first_event, 
    event_time
FROM RankedEvents
WHERE chronological_rank = 1;

----  Detect session gaps using LAG


SELECT 
    tenant_id, 
    user_id, 
    event_name, 
    event_time,
    -- Look in the rearview mirror at the previous event's time
    LAG(event_time) OVER (PARTITION BY tenant_id, user_id ORDER BY event_time ASC) AS previous_event_time,
    
    -- Subtract the two times to see the gap!
    event_time - LAG(event_time) OVER (PARTITION BY tenant_id, user_id ORDER BY event_time ASC) AS time_since_last_event
FROM events
ORDER BY tenant_id, user_id, event_time;


------ Running total of events per user

SELECT 
    tenant_id, 
    user_id, 
    event_time, 
    event_name,
    -- Count the events as we move down the timeline
    COUNT(*) OVER (PARTITION BY tenant_id, user_id ORDER BY event_time ASC) AS running_total
FROM events
ORDER BY tenant_id, user_id, event_time;



------------------------------------------Section D ----------------------------------------------------------

----  Find users whose event count is greater than the average event count

SELECT 
    tenant_id,
    user_id, 
    COUNT(*) AS total_events
FROM events
GROUP BY tenant_id, user_id
HAVING COUNT(*) > (
    -- SUBQUERY: Calculate the average events per user
    SELECT AVG(event_count) 
    FROM (
        SELECT COUNT(*) AS event_count 
        FROM events 
        GROUP BY tenant_id, user_id
    ) AS AverageCalculator
);



---- Retrieve the latest event per user using a correlated subquery

SELECT 
    e1.tenant_id, 
    e1.user_id, 
    e1.event_name, 
    e1.event_time
FROM events e1
WHERE e1.event_time = (
    -- CORRELATED SUBQUERY: Find the max time for THIS specific user
    SELECT MAX(e2.event_time)
    FROM events e2
    WHERE e1.tenant_id = e2.tenant_id AND e1.user_id = e2.user_id
);


---- Identify tenants whose total events exceed the overall average across tenants


SELECT 
    tenant_id, 
    COUNT(*) AS total_tenant_events
FROM events
GROUP BY tenant_id
HAVING COUNT(*) > (
    -- SUBQUERY: Calculate the average events per tenant
    SELECT AVG(tenant_count) 
    FROM (
        SELECT COUNT(*) AS tenant_count 
        FROM events 
        GROUP BY tenant_id
    ) AS AverageCalculator
);



------------------------------- Section E ------------------------------------------------


----   Funnel analysis using multi-step CTEs


WITH signups AS (
    -- Step 1: Get all users who signed up
    SELECT tenant_id, user_id FROM events WHERE event_name = 'signup'
),
carts AS (
    -- Step 2: Get all users who added to cart
    SELECT tenant_id, user_id FROM events WHERE event_name = 'add_to_cart'
),
purchases AS (
    -- Step 3: Get all users who purchased
    SELECT tenant_id, user_id FROM events WHERE event_name = 'purchase'
)
-- Bring them together!
SELECT 
    s.tenant_id,
    COUNT(DISTINCT s.user_id) AS total_signups,
    COUNT(DISTINCT c.user_id) AS reached_cart,
    COUNT(DISTINCT p.user_id) AS reached_purchase
FROM signups s
LEFT JOIN carts c ON s.tenant_id = c.tenant_id AND s.user_id = c.user_id
LEFT JOIN purchases p ON c.tenant_id = p.tenant_id AND s.user_id = p.user_id
GROUP BY s.tenant_id;



----   Retention calculation using CTEs


WITH FirstDay AS (
    -- Get the exact date the user started
    SELECT tenant_id, user_id, DATE(MIN(event_time)) AS start_date
    FROM events
    GROUP BY tenant_id, user_id
),
AllActiveDays AS (
    -- Get a list of every single day the user did something
    SELECT DISTINCT tenant_id, user_id, DATE(event_time) AS active_date
    FROM events
)
-- Join them together where the active day is exactly Start Date + 1
SELECT 
    f.tenant_id, 
    f.start_date,
    COUNT(DISTINCT f.user_id) AS total_users,
    COUNT(DISTINCT a.user_id) AS users_retained_on_day_1
FROM FirstDay f
LEFT JOIN AllActiveDays a 
    ON f.tenant_id = a.tenant_id 
    AND f.user_id = a.user_id 
    AND a.active_date = f.start_date + INTERVAL '1 day'
GROUP BY f.tenant_id, f.start_date;



-----  Identify top-performing tenants over time using layered CTEs


WITH TenantDailyStats AS (
    -- Layer 1: Count total events per tenant, per day
    SELECT 
        tenant_id, 
        DATE(event_time) as event_date, 
        COUNT(*) as daily_events
    FROM events
    GROUP BY tenant_id, DATE(event_time)
),
RankedTenants AS (
    -- Layer 2: Read from Layer 1, and hand out a Rank (1st, 2nd, 3rd) for that day
    SELECT 
        tenant_id, 
        event_date, 
        daily_events,
        RANK() OVER (PARTITION BY event_date ORDER BY daily_events DESC) as daily_rank
    FROM TenantDailyStats
)
-- Final Output: Only show the "Winners" (Rank 1) for each day
SELECT 
    event_date, 
    tenant_id AS top_tenant, 
    daily_events
FROM RankedTenants
WHERE daily_rank = 1
ORDER BY event_date;


------------------------------ Section F ------------------------------------------


----  Combine CTE + window function to rank users within each tenant

WITH UserRevenue AS (
    -- Step 1 (CTE): Calculate total money spent by each user
    SELECT 
        tenant_id, 
        user_id, 
        SUM((properties->>'amount')::NUMERIC) AS total_spent
    FROM events
    WHERE event_name = 'purchase'
    GROUP BY tenant_id, user_id
)
-- Step 2 (Window Function): Rank them within their company
SELECT 
    tenant_id, 
    user_id, 
    total_spent,
    RANK() OVER (PARTITION BY tenant_id ORDER BY total_spent DESC) AS revenue_rank
FROM UserRevenue;


---- Use subquery + JOIN to filter high-value users


SELECT 
    e.tenant_id, 
    e.user_id, 
    e.event_name, 
    e.event_time
FROM events e
JOIN (
    -- SUBQUERY: The VIP List (Users who spent > $500 total)
    SELECT tenant_id, user_id
    FROM events
    WHERE event_name = 'purchase'
    GROUP BY tenant_id, user_id
    HAVING SUM((properties->>'amount')::NUMERIC) > 500
) AS vip_list 
    ON e.tenant_id = vip_list.tenant_id 
    AND e.user_id = vip_list.user_id
ORDER BY e.tenant_id, e.user_id, e.event_time;




-------------------------------------------------------- Section G--------------------------------------------------

---- Optimize a slow query using indexing and query rewrite

EXPLAIN ANALYZE
SELECT event_id, event_time, event_name 
FROM events 
WHERE properties @> '{"device": "mobile"}'::jsonb;


---improved query 
EXPLAIN ANALYZE
SELECT event_id, event_time, event_name 
FROM events 
WHERE properties @> '{"device": "mobile"}'::jsonb;



------  Demonstrate partition pruning using EXPLAIN ANALYZE

EXPLAIN ANALYZE 
SELECT tenant_id, user_id, event_name 
FROM events 
WHERE event_time >= '2026-04-10 00:00:00Z' 
  AND event_time < '2026-04-12 00:00:00Z'
  AND tenant_id = 't1';


  