---------------UC 10------------------------------------


---------Before-----------------------------

EXPLAIN ANALYZE
SELECT event_id, event_time, user_id
FROM events
WHERE event_name = 'purchase' 
  AND properties->>'device' = 'mobile';


---------After--------------------------------

EXPLAIN ANALYZE
SELECT event_id, event_time, user_id
FROM events
WHERE event_name = 'purchase' 
  AND properties @> '{"device": "mobile"}'::jsonb;



-----------------UC 11------------------------------------

-- STEP 1: Detach the partition
ALTER TABLE events DETACH PARTITION events_y2026m04;

-- STEP 2: Archive the Data to a file 
COPY events_y2026m04 TO '/path/to/archives/events_y2026m04_archive.csv' WITH (FORMAT CSV, HEADER);

-- STEP 3: Drop the detached table
DROP TABLE events_y2026m04;