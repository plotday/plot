# Plot Database

## Schema

- The schema is defined in `schema/` is the source of truth for the database structure.
- Migrations are generated from this schema.
- All tales must have RLS enabled. Tables that aren't synced to the app should have no rules to keep them private.
- Tables should default to standard bigint primary keys. Tables with rows created on the client should use UUID primary keys.

## Migrations

Don't create migrations manually. Migrations are generated from the schema.

## Generate Types

Do not edit `src/types.ts` directly. Run `pnpm run types` in this package to regenerate.
