# Slow first-open of a thread's old notes — cold-connection query planning

## Symptom

Opening a thread that has **never been opened before in the app** takes multiple
seconds to show its old notes. Re-opening the same thread is instant.

## Root cause (measured on prod, 2026-06-17)

It is **slow query _planning_ on cold Postgres backends** — not execution, and
not the Flutter app.

When a thread is opened for the first time, the app lazily fetches that thread's
notes, tags, and reactions (`apps/plot/lib/store/note.dart` → `pullForActivity`).
This fires **three separate API requests** (`/sync/notes`, `/sync/note-tags`,
`/sync/note-reactions`). Already-opened threads read from the local Drift DB, so
only first-open touches the API — which is why the slowness tracks exactly with
"never opened before."

Each query joins the heavily-indexed `note` and `thread` tables through the
`user.*` views. EXPLAIN ANALYZE on prod for an example thread (3 notes):

| Query | Planning (cold backend) | Planning (warm) | Execution |
| --- | --- | --- | --- |
| `note` (single table, 1 index cond) | **489 ms** | ~5 ms | 0.2 ms |
| `user.note` view | 246 ms | 4.8 ms | 36 ms |
| `/sync/note-tags` seq query | **979 ms** | ~5 ms | 55 ms |
| first query on a brand-new connection | up to **4,298 ms** | — | — |

Execution is always trivial (data is tiny). The cost is the planner building the
relcache for the hot tables on a **cold backend**:

- `note` has **19 indexes**, `thread` has **19 indexes + 23 dropped columns**.
  `get_relation_info` opens every index during planning; cold, each is a relcache
  build. The HNSW vector indexes (`note_embedding_idx` 77 MB, `idx_thread_embedding`
  13 MB) and GIN trigram index (`idx_note_content_trgm` 201 MB) are especially
  expensive to cold-load.
- The `user.*` views add joins and call SQL functions
  (`user_contact_ids`/`user_group_ids`/`user_topic_ids`) that must also be planned.
- System catalogs are mildly bloated (`pg_attribute`/`pg_class`/`pg_index` ~14–16 %
  dead tuples, `pg_rewrite` 15 %, `pg_depend` 10 %), so the planner reads extra
  catalog pages.

**Why backends are cold so often:** the API connects via Cloudflare Hyperdrive
(`workers/api/src/db.ts` `createDb`, `pg.Pool({ max: 1 })` per request,
`db.destroy()` after). Hyperdrive drains idle Postgres backends; at low traffic
there were **0 app backends alive**. The next first-open then spins up cold
backends and pays the full planning tax on each of its 3 queries.

## What was already fixed in code

See the companion change: the three per-thread pulls are folded into a single
request so the relcache build is paid once (the first query in the shared
transaction), and the 2nd/3rd queries reuse the now-warm relcache. This removes
the 3× multiplier but not the one-time cold cost.

## Infra / ops actions (require prod access + a deploy — not shippable from code)

Ranked by leverage on the user-visible symptom.

### 1. Keep a minimum warm Hyperdrive connection pool (biggest lever)

The cold-backend tax is only paid when Hyperdrive opens a fresh backend. If a
small pool of backends is kept warm, virtually every request plans in ~5 ms.

- Review the Hyperdrive configuration for this database
  (`wrangler hyperdrive` / the dashboard). Hyperdrive's pool sizing and idle
  behavior determine how often backends go fully cold.
- If Hyperdrive cannot guarantee a warm floor at low traffic, add an external
  keep-warm: a Cron Trigger (every 1–3 min) that runs one trivial query against
  each hot view (`SELECT 1 FROM "user".note WHERE false`, etc.) so at least one
  backend keeps its relcache primed. (`SELECT 1` alone is **not** enough — it
  doesn't build the `note`/`thread` relcache; the warm-up query must touch the
  same tables/views the real queries use.)
- Verify with `pg_stat_activity`: at idle there should be ≥1 long-lived
  `client backend` for the api role, not zero.

### 2. Vacuum / reindex the bloated system catalogs

Reduces catalog pages read during planning on every cold backend.

```sql
VACUUM (ANALYZE, VERBOSE) pg_catalog.pg_attribute;
VACUUM (ANALYZE, VERBOSE) pg_catalog.pg_statistic;
VACUUM (ANALYZE, VERBOSE) pg_catalog.pg_class;
VACUUM (ANALYZE, VERBOSE) pg_catalog.pg_depend;
VACUUM (ANALYZE, VERBOSE) pg_catalog.pg_rewrite;
REINDEX (CONCURRENTLY) TABLE pg_catalog.pg_attribute;   -- if bloat persists
REINDEX (CONCURRENTLY) TABLE pg_catalog.pg_depend;
```

Also consider why they bloat: every deploy `CREATE OR REPLACE`s the `user.*`
views and functions, churning `pg_rewrite`/`pg_depend`/`pg_attribute`. Tune
autovacuum to be more aggressive on the catalogs (lower
`autovacuum_vacuum_scale_factor` for these tables) if bloat keeps returning.

### 3. Reclaim `thread`'s 23 dropped columns (and dropped cols on note/priority)

Dropped columns linger in `pg_attribute` and inflate the relcache build for the
table. A table rewrite reclaims them:

```sql
-- Online, no long exclusive lock:
pg_repack -t public.thread -t public.note -t public.priority -t public.thread_priority
-- or, during a maintenance window:
VACUUM FULL public.thread;   -- takes an ACCESS EXCLUSIVE lock
```

Prefer `pg_repack` to avoid the exclusive lock. After it, confirm the dropped
attributes are gone:
`SELECT count(*) FROM pg_attribute WHERE attrelid='public.thread'::regclass AND attisdropped;`

### 4. (Optional, low value) Trim genuinely-unused indexes — but NOT the embedding ones

`idx_scan=0` over 4 months looks droppable, but the big ones back features:

- `note_embedding_idx`, `idx_thread_embedding` (HNSW) back `classify_thread_for_user`,
  `reclassify_user_threads`, and the `search_notes_and_links` semantic search RPC.
  They read 0 scans only because the planner currently picks a seq scan at this
  data volume. **Do not drop.**
- `idx_note_access_groups`, `idx_thread_external_contacts`, `idx_thread_team_id`
  back group-note visibility / external-contact / team queries; tiny, so dropping
  them barely affects planning. Low priority.

## Verification

After infra changes, re-run on prod (readonly is fine):

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM "user".note
WHERE user_id = '<user>' AND thread_id = '<thread>'
ORDER BY seq ASC, id ASC LIMIT 500;
```

On a warm/primed backend, `Planning Time` should be single-digit ms (vs. the
245 ms–4.3 s observed cold). Also confirm `pg_stat_activity` shows a warm api
backend at idle.
