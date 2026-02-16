-- Minimal bootstrap for non-Supabase environments (GCP, etc.).
-- Derived from libs/db/schema/10-settings and libs/db/schema/20-extensions.
-- Schemas
CREATE SCHEMA IF NOT EXISTS "public";

CREATE SCHEMA IF NOT EXISTS "admin";

CREATE SCHEMA IF NOT EXISTS "extensions";

CREATE SCHEMA IF NOT EXISTS "user";

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "vector";

CREATE EXTENSION IF NOT EXISTS "ltree";

CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "plpgsql_check" WITH SCHEMA "extensions";

