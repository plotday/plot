# API Worker Guidelines

## Hyperdrive Query Caching

**CRITICAL: Hyperdrive caches SELECT query results.** This includes `SELECT my_function(...)` calls, even if the function uses `random()`, `clock_timestamp()`, or other non-deterministic operations. Concurrent requests with identical queries receive the same cached result.

### When this matters

Any database function that must return unique/fresh results per call:
- `generate_path()` — generates random priority paths
- Any function using `random()`, `gen_random_uuid()`, `clock_timestamp()`
- Any RPC-style call where you need to guarantee distinct results across concurrent requests

### How to fix

**Preferred: Generate non-deterministic values in TypeScript** instead of database functions. This completely eliminates caching concerns.

For priority paths specifically, use `generatePath()` from `src/utils/path.ts`. **Do NOT call `rpc(db, "generate_path", ...)` from TypeScript** — the database function exists for use in SQL migrations and PL/pgSQL only.

If you must use a non-deterministic database function via SELECT, you can bypass Hyperdrive's cache using the `noCache` connection string on the Hyperdrive binding (`env.HYPERDRIVE.noCache`). This skips the query cache while keeping connection pooling benefits.

### When you DON'T need noCache

- Regular SELECT queries reading data (caching is a feature, not a bug)
- INSERT/UPDATE/DELETE (Hyperdrive only caches SELECTs)
- Queries where getting a slightly stale result is acceptable
