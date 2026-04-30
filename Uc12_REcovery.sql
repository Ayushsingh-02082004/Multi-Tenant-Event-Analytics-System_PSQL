-- # Step 1: Drop and recreate the database (Run via psql or pgAdmin)
DROP DATABASE "Multi-Tenant_ Event_Analytics_System";
CREATE DATABASE "Multi-Tenant_ Event_Analytics_System";

# Step 2: Run the Restore Command
"D:\softwares\psql\bin\pg_restore.exe" -U postgres -d analytics_db -1 -j 4 "D:\backups\postgres\Multi-Tenant_ Event_Analytics_System_20260418_1548.dump"