-- Grant USAGE on all schemas to readonly and api
GRANT USAGE ON SCHEMA public, "user", admin, extensions TO readonly;
GRANT USAGE ON SCHEMA admin TO api;

-- Retroactive grants for all existing tables in all schemas
-- (Note: GRANT ON ALL TABLES includes VIEWS in PostgreSQL)
GRANT SELECT ON ALL TABLES IN SCHEMA public, "user", admin, extensions TO readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA admin TO api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA admin, extensions TO api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA admin TO api;
