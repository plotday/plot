#!/usr/bin/env bash
set -e

# Load DATABASE_URL from environment or use default local development URL
URL="${DATABASE_URL:-postgres://postgres:postgres@127.0.0.1:54322/postgres?sslmode=disable}"

echo "Ensuring required local roles exist..."
psql "$URL" -c "DO \$\$ 
BEGIN 
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'readonly') THEN 
        CREATE ROLE readonly; 
    END IF; 
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'api') THEN
        CREATE ROLE api;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'migrator') THEN
        CREATE ROLE migrator;
    END IF;
END \$\$;"
