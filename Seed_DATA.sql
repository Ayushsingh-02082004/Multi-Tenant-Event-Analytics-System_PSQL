-- 1. Generate 5 Random Tenants
INSERT INTO tenants (tenant_id, tenant_name)
SELECT 
    't' || g.id, 
    'Company ' || CHR(64 + g.id) || ' LLC'
FROM generate_series(4, 8) AS g(id) -- Using 4-8 so it doesn't conflict with t1, t2, t3 from earlier
ON CONFLICT DO NOTHING;

-- 2. Generate 100 Random Users across those Tenants
INSERT INTO users (tenant_id, user_id, email)
SELECT 
    't' || (floor(random() * 5) + 4)::INT, -- Randomly assigns to t4, t5, t6, t7, or t8
    'user_' || g.id, 
    'user_' || g.id || '@example.com'
FROM generate_series(10, 110) AS g(id)
ON CONFLICT DO NOTHING;

-- 3. Generate 5,000 Random Events
INSERT INTO events (tenant_id, user_id, event_name, event_time, properties)
SELECT 
    u.tenant_id,
    u.user_id,
    -- Randomly pick an event type (weighted slightly toward page_views)
    (ARRAY['page_view', 'page_view', 'signup', 'add_to_cart', 'purchase'])[floor(random() * 5) + 1],
    
    -- Generate a random timestamp between April 1, 2026 and May 31, 2026
    '2026-04-01 00:00:00Z'::timestamptz + (random() * interval '60 days'),
    
    -- Generate randomized JSON properties
    (
        '{"device": "' || (ARRAY['mobile', 'desktop', 'tablet'])[floor(random() * 3) + 1] || '", ' ||
        '"amount": ' || floor(random() * 1000 + 15) || ', ' ||
        '"browser": "' || (ARRAY['chrome', 'safari', 'firefox'])[floor(random() * 3) + 1] || '"}'
    )::jsonb
FROM 
    generate_series(1, 5000),
    LATERAL (
        -- This subquery randomly selects an existing user to attach the event to
        SELECT tenant_id, user_id FROM users ORDER BY random() LIMIT 1
    ) u
ON CONFLICT DO NOTHING;


select * from users