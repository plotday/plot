# Google Composite — Bankruptcy via Per-Account Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Google composite cutover archives a user's legacy Gmail/Calendar/Tasks connections, provision one combined Google connection per Google account in a needs-auth state; reconnecting auto-enables the owned/default channels exactly like a fresh connect.

**Architecture:** A one-shot `seed_default_channels` flag on `twist_instance_connection`, set by the bankruptcy SQL on provisioned connections. `Integrations.setChannels` — which `onAuth` already runs on every (re)auth — enables the connector's `enabledByDefault` (owned) channels when the flag is set and no channels are enabled, then clears the flag. No Flutter changes (reuses the existing needs-reauth/reconnect UX).

**Tech Stack:** Cloudflare Workers + TypeScript (workers/api), Kysely, Atlas migrations (libs/db), vitest. Spec: `docs/superpowers/specs/2026-06-24-google-composite-bankruptcy-reconnect-design.md`.

## Global Constraints

- **Execute on a CLEAN branch off `core/main`** (plotday/core), not the tangled `google-composite-twister` branch — like #431. The schema migration needs a clean migration history + a worktree DB.
- **Never `DELETE` from synced tables** — archive with `archived_at = now()` (the provisioning SQL).
- **Schema-change workflow:** edit `libs/db/schema/**` only → `pnpm gen-migration -- <name>` (uses Atlas's own docker dev DB, safe) → `pnpm apply-migrations` (uses `$DATABASE_URL`) → commit the regenerated `libs/db/src/types.ts`.
- **`$DATABASE_URL` is stale in worktrees** (points at main's `54322`). For `apply-migrations`/psql, override from `.worktree-db`: `source ./.worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" pnpm apply-migrations`. Sanity-check the port first.
- **The flag is one-shot:** `setChannels` clears `seed_default_channels` after it fires (or finds nothing to seed), so it never re-enables channels a user later disables.
- **Owned-only:** seed exactly the channels with `enabledByDefault === true` — never all channels.
- **TDD, frequent commits.** All new `catch` blocks for unexpected errors call `tracker.captureException`.

---

### Task 1: Schema — `seed_default_channels` flag on `twist_instance_connection`

**Files:**
- Modify: `libs/db/schema/50-tables/96-twist_instance_connection.sql`
- Generated: `libs/db/migrations/<timestamp>_add_seed_default_channels.sql`, `libs/db/src/types.ts`

**Interfaces:**
- Produces: a `twist_instance_connection.seed_default_channels boolean NOT NULL DEFAULT false` column, read/written by Task 2 and set by Task 3.

- [ ] **Step 1: Add the column to the schema file**

In `libs/db/schema/50-tables/96-twist_instance_connection.sql`, add the column after `recovery_pending` (before the `seq` line):

```sql
    -- One-shot directive set by the Google composite bankruptcy provisioning:
    -- when true, the next `setChannels` for this connection enables the
    -- connector's owned/default (`enabledByDefault`) channels — the set a fresh
    -- user gets — then sets this back to false. Lets a freshly-provisioned,
    -- never-authed connection resume syncing on one re-auth without the client
    -- setup screen. Connectors do not read or write this.
    "seed_default_channels" boolean NOT NULL DEFAULT false,
```

- [ ] **Step 2: Generate the migration**

Run: `pnpm gen-migration -- add_seed_default_channels`
Expected: a new file in `libs/db/migrations/` adding the column; `atlas.sum` updated.

- [ ] **Step 3: Apply to the worktree DB + regenerate types**

Run:
```bash
source ./.worktree-db
psql "postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" -tAc "show port;"   # sanity: not 54322
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" pnpm apply-migrations
```
Expected: migration applies; `pnpm types` runs and updates `libs/db/src/types.ts` (the `TwistInstanceConnection` type gains `seed_default_channels: boolean`).

- [ ] **Step 4: Verify schema/migrations in sync**

Run: `pnpm diff-schema-migrations`
Expected: no differences.

- [ ] **Step 5: Commit**

```bash
git add libs/db/schema/50-tables/96-twist_instance_connection.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add twist_instance_connection.seed_default_channels flag"
```

---

### Task 2: Server — `setChannels` seeds owned defaults when flagged

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (the `setChannels` method ≈ line 619; add a private `seedDefaultChannelsIfFlagged` + an exported pure helper `selectOwnedDefaultChannels`)
- Test: `workers/api/src/twist/tools/integrations-seed-defaults.test.ts` (new)

**Interfaces:**
- Consumes: `twist_instance_connection.seed_default_channels` (Task 1); `Channel` (from `@plotday/twister/tools/integrations`) with `enabledByDefault?: boolean` and `children?: Channel[]`; existing private methods `flattenChannels(channels): Channel[]`, `applyChannelEnabled(provider, actorId, channel, syncContext): Promise<dispatchEntry | null>`, `buildSyncContext({forActor, provider}): Promise<SyncContext>`.
- Produces: `export function selectOwnedDefaultChannels(channels: Channel[]): Channel[]`; private `seedDefaultChannelsIfFlagged(provider, actorId, channels): Promise<dispatchEntry[]>`, merged into `setChannels`'s `__dispatch` return.

- [ ] **Step 1: Write the failing test for the pure selector**

Create `workers/api/src/twist/tools/integrations-seed-defaults.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import type { Channel } from "@plotday/twister/tools/integrations";
import { selectOwnedDefaultChannels } from "./integrations";

const ch = (id: string, enabledByDefault?: boolean, children?: Channel[]): Channel =>
  ({ id, title: id, enabledByDefault, children } as Channel);

describe("selectOwnedDefaultChannels", () => {
  it("returns only channels flagged enabledByDefault === true", () => {
    const out = selectOwnedDefaultChannels([
      ch("mail:INBOX", true),
      ch("mail:Label_42", false),
      ch("calendar:primary", true),
      ch("calendar:holidays"), // undefined → excluded
    ]);
    expect(out.map((c) => c.id)).toEqual(["mail:INBOX", "calendar:primary"]);
  });

  it("recurses into children (e.g. nested calendars/labels)", () => {
    const out = selectOwnedDefaultChannels([
      ch("group", undefined, [ch("calendar:primary", true), ch("calendar:shared", false)]),
    ]);
    expect(out.map((c) => c.id)).toEqual(["calendar:primary"]);
  });

  it("returns empty when none are owned-default", () => {
    expect(selectOwnedDefaultChannels([ch("mail:INBOX", false), ch("x")])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-seed-defaults.test.ts`
Expected: FAIL — `selectOwnedDefaultChannels` is not exported.

- [ ] **Step 3: Implement the pure selector**

In `workers/api/src/twist/tools/integrations.ts`, add at module scope (near the other top-level exports, e.g. above the `Integrations` class):

```typescript
/**
 * The channels a connector marks as owned/default (`enabledByDefault === true`),
 * flattened from the channel tree. This is the set a brand-new connection
 * enables; the composite bankruptcy reuses it so a reconnect resumes the same
 * channels a fresh connect would.
 */
export function selectOwnedDefaultChannels(channels: Channel[]): Channel[] {
  const out: Channel[] = [];
  const walk = (nodes: Channel[]) => {
    for (const c of nodes) {
      if (c.enabledByDefault === true) out.push(c);
      if (c.children?.length) walk(c.children);
    }
  };
  walk(channels);
  return out;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-seed-defaults.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing orchestration test for `seedDefaultChannelsIfFlagged`**

Append to `integrations-seed-defaults.test.ts`:

```typescript
import { Integrations } from "./integrations";

// Table-aware Kysely stub. The flag read hits twist_instance_connection
// (executeTakeFirst → { seed_default_channels }); the "already enabled?" probe
// hits channel (executeTakeFirst → enabledRow or undefined). updateTable
// records the flag-clear.
function makeHost(opts: {
  seedFlag: boolean;
  hasEnabledChannel: boolean;
  enableCalls: Channel[];
  cleared: { value: boolean };
}) {
  const select = (table: string) => ({
    select: () => select(table),
    where: () => select(table),
    limit: () => select(table),
    executeTakeFirst: async () =>
      table === "twist_instance_connection"
        ? { user_id: "u", seed_default_channels: opts.seedFlag }
        : table === "channel"
        ? opts.hasEnabledChannel
          ? { channel_id: "x" }
          : undefined
        : undefined,
  });
  const update = () => ({
    set: (v: any) => {
      if (v.seed_default_channels === false) opts.cleared.value = true;
      return update();
    },
    where: () => update(),
    execute: async () => {},
  });
  return {
    twistInstanceId: "ti-1",
    db: { selectFrom: (t: string) => select(t), updateTable: () => update() },
    flattenChannels: (Integrations.prototype as any).flattenChannels,
    buildSyncContext: async () => ({}),
    applyChannelEnabled: async (_p: any, _a: any, channel: Channel) => {
      opts.enableCalls.push(channel);
      return { sourceMethod: "onChannelEnabled", args: [{ id: channel.id }, {}] };
    },
    seedDefaultChannelsIfFlagged: (Integrations.prototype as any)
      .seedDefaultChannelsIfFlagged,
  } as any;
}

describe("seedDefaultChannelsIfFlagged", () => {
  const channels = [ch("mail:INBOX", true), ch("mail:Label_42", false), ch("calendar:primary", true)];

  it("flag set + no enabled channels → enables owned defaults, clears flag", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: true, hasEnabledChannel: false, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls.map((c) => c.id)).toEqual(["mail:INBOX", "calendar:primary"]);
    expect(dispatches).toHaveLength(2);
    expect(cleared.value).toBe(true);
  });

  it("flag set + already has an enabled channel → no enables (defensive), still clears flag", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: true, hasEnabledChannel: true, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls).toEqual([]);
    expect(dispatches).toEqual([]);
    expect(cleared.value).toBe(true);
  });

  it("flag unset → no-op, no flag write", async () => {
    const enableCalls: Channel[] = [];
    const cleared = { value: false };
    const host = makeHost({ seedFlag: false, hasEnabledChannel: false, enableCalls, cleared });
    const dispatches = await host.seedDefaultChannelsIfFlagged.call(host, "google", "actor-1", channels);
    expect(enableCalls).toEqual([]);
    expect(dispatches).toEqual([]);
    expect(cleared.value).toBe(false);
  });
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-seed-defaults.test.ts`
Expected: FAIL — `seedDefaultChannelsIfFlagged` is undefined.

- [ ] **Step 7: Implement `seedDefaultChannelsIfFlagged`**

In `workers/api/src/twist/tools/integrations.ts`, add this private method to the `Integrations` class (near `setChannels`):

```typescript
/**
 * One-shot: when this connection's `seed_default_channels` flag is set and it
 * has no enabled channels yet, enable the connector's owned/default channels
 * (the set a fresh user gets), then clear the flag. Returns the
 * `onChannelEnabled` dispatch entries for the seeded channels (possibly empty).
 *
 * Set only by the Google composite bankruptcy provisioning, so this is inert
 * for every other connection. The "no enabled channels" guard means it never
 * overrides a user's own channel selection.
 */
private async seedDefaultChannelsIfFlagged(
  provider: AuthProvider,
  actorId: ActorId,
  channels: Channel[]
): Promise<any[]> {
  const conn = await this.db
    .selectFrom("twist_instance_connection")
    .select(["seed_default_channels"])
    .where("twist_instance_id", "=", this.twistInstanceId)
    .where("provider", "=", provider)
    .where("actor_id", "=", actorId as string)
    .executeTakeFirst();
  if (!conn?.seed_default_channels) return [];

  const enabledRow = await this.db
    .selectFrom("channel")
    .select("channel_id")
    .where("twist_instance_id", "=", this.twistInstanceId)
    .where("enabled", "=", true)
    .limit(1)
    .executeTakeFirst();

  const dispatches: any[] = [];
  if (!enabledRow) {
    const owned = selectOwnedDefaultChannels(channels);
    if (owned.length > 0) {
      const syncContext = await this.buildSyncContext({ forActor: actorId, provider });
      for (const channel of owned) {
        const entry = await this.applyChannelEnabled(provider, actorId, channel, syncContext);
        if (entry) dispatches.push(entry);
      }
    }
  }

  // One-shot: clear regardless, so this never re-seeds (or fights a later disable).
  await this.db
    .updateTable("twist_instance_connection")
    .set({ seed_default_channels: false })
    .where("twist_instance_id", "=", this.twistInstanceId)
    .where("provider", "=", provider)
    .where("actor_id", "=", actorId as string)
    .execute();

  return dispatches;
}
```

- [ ] **Step 8: Run it to verify it passes**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-seed-defaults.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 9: Wire it into `setChannels` (collect both dispatch sources, return once)**

Refactor the tail of `setChannels` (the part from `const autoEnable = ...` to the end) so it no longer early-returns, collects dispatches from both the existing auto-enable path and the new seed-defaults path, and returns once. Replace:

```typescript
    // Auto-enable newly-discovered channels when the per-connection flag is on.
    const autoEnable = await this.store.get<boolean>(
      `auto_enable_new_channels:${provider}:${actorId}`
    );
    if (!autoEnable) return;

    const newChannels = flat.filter((c) => !knownIds.has(c.id));
    if (newChannels.length === 0) return;

    const syncContext = await this.buildSyncContext({
      forActor: actorId,
      provider,
    });
    const dispatches: any[] = [];
    for (const channel of newChannels) {
      const entry = await this.applyChannelEnabled(
        provider,
        actorId,
        channel,
        syncContext
      );
      if (entry) dispatches.push(entry);
    }
    if (dispatches.length > 0) return { __dispatch: dispatches } as any;
```

with:

```typescript
    const dispatches: any[] = [];

    // Auto-enable newly-discovered channels when the per-connection flag is on.
    const autoEnable = await this.store.get<boolean>(
      `auto_enable_new_channels:${provider}:${actorId}`
    );
    const newChannels = autoEnable
      ? flat.filter((c) => !knownIds.has(c.id))
      : [];
    if (newChannels.length > 0) {
      const syncContext = await this.buildSyncContext({
        forActor: actorId,
        provider,
      });
      for (const channel of newChannels) {
        const entry = await this.applyChannelEnabled(
          provider,
          actorId,
          channel,
          syncContext
        );
        if (entry) dispatches.push(entry);
      }
    }

    // One-shot seed of owned defaults for a bankruptcy-provisioned connection.
    dispatches.push(
      ...(await this.seedDefaultChannelsIfFlagged(provider, actorId, channels))
    );

    if (dispatches.length > 0) return { __dispatch: dispatches } as any;
```

- [ ] **Step 10: Verify the whole integrations suite + typecheck**

Run:
```bash
cd workers/api
pnpm vitest run src/twist/tools/
pnpm exec tsc --noEmit
```
Expected: all tests pass (including the existing `integrations-*` suites — the auto-enable refactor is behavior-preserving); tsc clean.

- [ ] **Step 11: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations-seed-defaults.test.ts
git commit -m "feat(api): setChannels seeds owned-default channels for flagged connections"
```

---

### Task 3: Bankruptcy provisioning SQL + runbook update

**Files:**
- Modify: `docs/superpowers/plans/2026-06-24-google-composite-cutover-runbook.md` (replace the bankruptcy `§3` archival SQL with the per-account provisioning SQL)

**Interfaces:**
- Consumes: `twist_instance_connection.seed_default_channels` (Task 1); the combined connector's catalog `twist` row (`twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d'`), created by deploying the connector.

- [ ] **Step 1: Validate the provisioning SQL against the worktree DB (rolled back)**

Run (confirms it parses + columns exist; matches 0 rows locally since the legacy connectors aren't deployed to dev):

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/google-composite-twister
source ./.worktree-db
psql "postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
-- For each (user, distinct Google account, team) that has an active legacy
-- Gmail/Calendar/Tasks connection, provision one combined Google instance in a
-- needs-auth + seed-defaults state.
WITH legacy AS (
  SELECT DISTINCT ti.owner_id, ti.team_id, tic.actor_id
  FROM public.twist_instance ti
  JOIN public.twist t ON t.id = ti.twist_id
  JOIN public.twist_instance_connection tic
    ON tic.twist_instance_id = ti.id AND tic.provider = 'google'
  WHERE t.twist_package_id IN (
    '7176b853-4495-4bba-82ee-645ae5d398d7',  -- Gmail
    '2ed4fcf8-6524-410f-b318-f9316e71c8b0',  -- Google Calendar
    '019d4129-4aee-7629-9d7b-b9fdb87db532'   -- Google Tasks
  )
  AND ti.archived_at IS NULL
),
combined AS (
  SELECT id AS twist_id FROM public.twist
  WHERE twist_package_id = '6e9e441f-aeee-4142-a37b-62cfe79ac16d' AND is_source = true
  LIMIT 1
),
created AS (
  INSERT INTO public.twist_instance (id, twist_id, owner_id, team_id, name, draft)
  SELECT gen_random_uuid(), c.twist_id, l.owner_id, l.team_id,
         'Google Mail, Calendar, and Tasks', false
  FROM legacy l CROSS JOIN combined c
  -- guard: skip accounts that already have a combined instance
  WHERE NOT EXISTS (
    SELECT 1 FROM public.twist_instance ti2
    JOIN public.twist_instance_connection tic2
      ON tic2.twist_instance_id = ti2.id
    WHERE ti2.twist_id = c.twist_id AND ti2.owner_id = l.owner_id
      AND ti2.archived_at IS NULL AND tic2.actor_id = l.actor_id
  )
  RETURNING id, owner_id, team_id
)
INSERT INTO public.twist_instance_connection
  (twist_instance_id, user_id, provider, actor_id, needs_reauth_at, seed_default_channels)
SELECT cr.id, cr.owner_id, 'google', l.actor_id, now(), true
FROM created cr
JOIN legacy l ON l.owner_id = cr.owner_id AND l.team_id IS NOT DISTINCT FROM cr.team_id;

-- Then archive the legacy instances + their catalog twists (existing §3 SQL).
UPDATE public.twist_instance SET archived_at = now()
WHERE twist_id IN (SELECT id FROM public.twist WHERE twist_package_id IN (
  '7176b853-4495-4bba-82ee-645ae5d398d7','2ed4fcf8-6524-410f-b318-f9316e71c8b0','019d4129-4aee-7629-9d7b-b9fdb87db532'))
AND archived_at IS NULL;
UPDATE public.twist SET archived_at = now()
WHERE twist_package_id IN ('7176b853-4495-4bba-82ee-645ae5d398d7','2ed4fcf8-6524-410f-b318-f9316e71c8b0','019d4129-4aee-7629-9d7b-b9fdb87db532')
AND archived_at IS NULL;
ROLLBACK;
SQL
echo "exit=$?"
```
Expected: statements parse and run; `exit=0`. (Row counts ~0 locally.) If a column/name is wrong, fix and re-run.

- [ ] **Step 2: Replace the runbook's bankruptcy section with the validated provisioning SQL**

In `docs/superpowers/plans/2026-06-24-google-composite-cutover-runbook.md`, replace step **§3** ("Run the bankruptcy SQL") with the provisioning SQL above (without the `BEGIN/ROLLBACK` wrapper — keep the BEFORE counts + `COMMIT`), and add a sentence under §0 pre-reqs: "Confirm the combined `plotTwistId` is final (the provisioning + status queries key on it)." Update §4 verification to also check: one combined needs-auth connection exists per legacy Google account; on reconnect the owned channels enable and sync resumes.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-06-24-google-composite-cutover-runbook.md
git commit -m "docs(google-composite): per-account reconnect provisioning in cutover runbook"
```

---

## Notes for execution

- The schema + `setChannels` changes (Tasks 1–2) ship as a PR to **plotday/core off `main`** (the combined connector + Phase-4 endpoint are already merged). Task 3 is a doc.
- After Tasks 1–2 merge, the runbook's deploy sequence is: deploy combined connector → run the provisioning SQL → users see one "Reconnect Google" per account → reconnect auto-enables owned defaults.
- Human-gated (in the runbook, not this plan): the prod deploy, running the SQL, and live verification with a real Google account.
