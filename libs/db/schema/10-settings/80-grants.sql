-- Grant the api role full data access to public and user schemas.
-- The api role should be able to read/write all data and execute all functions,
-- but should NOT be able to modify the schema (CREATE/ALTER/DROP).

-- Schema usage
GRANT USAGE ON SCHEMA public TO api;
GRANT USAGE ON SCHEMA "user" TO api;

-- Tables: full data access
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "user" TO api;

-- Functions: execute
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA "user" TO api;

-- Sequences: usage (for bigint primary keys)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA "user" TO api;

-- Auto-grant on future objects created by postgres role
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO api;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA "user" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO api;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO api;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA "user" GRANT EXECUTE ON FUNCTIONS TO api;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT USAGE ON SEQUENCES TO api;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA "user" GRANT USAGE ON SEQUENCES TO api;

-- Readonly role: SELECT-only access to all tables and views in public and user schemas.
GRANT USAGE ON SCHEMA public TO readonly;
GRANT USAGE ON SCHEMA "user" TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA "user" TO readonly;

-- Auto-grant SELECT on future tables/views for readonly role
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA "user" GRANT SELECT ON TABLES TO readonly;
