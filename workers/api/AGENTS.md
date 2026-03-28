# API Worker Guidelines

## Hyperdrive Query Caching

**CRITICAL: Hyperdrive caches SELECT query results.** This includes `SELECT my_function(...)` calls, even if the function uses `random()`, `clock_timestamp()`, or other non-deterministic operations. Concurrent requests with identical queries receive the same cached result.

### When this matters

Any database function that must return unique/fresh results per call:
- `generate_path()` — generates random priority paths
- Any function using `random()`, `gen_random_uuid()`, `clock_timestamp()`
- Any RPC-style call where you need to guarantee distinct results across concurrent requests

### How to fix

Use `createNoCacheDb(env)` from `../db` instead of the request-scoped `db` for these calls. This uses Hyperdrive's `noCache` connection string, which bypasses the query cache while still using connection pooling.

```typescript
import { createNoCacheDb } from "../db";

// BAD: Hyperdrive may return the same cached random path to concurrent requests
const path = await rpc(db, "generate_path", { parent: parentPath });

// GOOD: Each call gets a fresh result
const noCacheDb = createNoCacheDb(env);
try {
  const path = await rpc(noCacheDb, "generate_path", { parent: parentPath });
} finally {
  await noCacheDb.destroy();
}
```

### When you DON'T need noCache

- Regular SELECT queries reading data (caching is a feature, not a bug)
- INSERT/UPDATE/DELETE (Hyperdrive only caches SELECTs)
- Queries where getting a slightly stale result is acceptable
