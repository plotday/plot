# Phase 1 — Dynamic Link Types — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a connection's effective link types reflect what's actually enabled at runtime — the union of its *enabled channels'* `channel.link_types` — instead of the static deploy-time `twist.permissions._providers[].linkTypes`, gated by a per-connector opt-in flag so every existing connector is unchanged.

**Architecture:** A new `Connector.dynamicLinkTypes` SDK flag flows through the deploy path into `twist.permissions._dynamic_link_types`. The `user.twist` view branches on it: when set, `link_types` = `jsonb_agg(DISTINCT …)` over the instance's enabled channels' `link_types`; otherwise the existing static aggregation. The view's `seq` gains `MAX(channel.seq)` so channel enable/disable re-syncs the row. Backward-compatible: flag defaults false, so existing connectors keep static link types; the only behavior change for them is a harmless extra re-emit when their channels change. This unblocks permission-aware agenda gating (§1.6 of the spec) with **no `twist_instance` column and no Flutter change**.

**Tech Stack:** PostgreSQL (Atlas migrations, schema files in `libs/db/schema/`), TypeScript (Twister SDK + `workers/api` deploy path), Vitest.

## Global Constraints

- **Backward compatible.** Flag defaults false → `user.twist.link_types` is byte-identical to today for every existing connector. The `migration-safety`/Squawk CI gate must pass (additive view replace + additive flag; no destructive DDL).
- **Worktree DB only.** Ambient `$DATABASE_URL` is STALE (points at the main repo's `54322`). Every DB command MUST override it from `.worktree-db` (port `54335`): `source .worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" <cmd>`, and sanity-check `psql "$DATABASE_URL" -tAc "show port;"` prints `54335` first.
- **Schema workflow is fixed** (libs/db/AGENTS.md): edit `schema/` → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` → `pnpm diff-schema-migrations` (no diff) → commit regenerated `libs/db/src/types.ts`. Never hand-edit migrations or `types.ts`.
- **Synced view re-emit.** Adding a column-affecting dependency to `user.twist` requires existing rows to re-pull: the migration ends with `UPDATE twist_instance SET updated_at = now();` (per libs/db/AGENTS.md "Also bump on schema changes that add view columns").
- **Twister change ⇒ changeset.** The SDK property change needs a `public/.changeset/*.md` (`"@plotday/twister": minor`).
- **Two repos.** Schema + deploy-path edits are in the **main repo** (worktree root, branch `google-composite-twister`); the SDK property + changeset are in the **`public/` submodule** (branch `google-composite-twister`) — commit there separately.

---

### Task 1: `user.twist` view — dynamic link types + channel-aware seq

**Files:**
- Modify: `libs/db/schema/90-user-schema/32-twist.sql` (the `link_types` subquery + the `seq` GREATEST)
- Generate: `libs/db/migrations/<ts>_dynamic_link_types.sql` (via `pnpm gen-migration`)
- Modify (generated): `libs/db/src/types.ts` (via `pnpm types`; commit it)
- Test: `libs/db/test/dynamic-link-types.test.ts` (new — psql-driven assertions; see Step 1 for the runner check)

**Interfaces:**
- Produces: `user.twist.link_types` semantics — `CASE WHEN (t.permissions ->> '_dynamic_link_types')::boolean THEN <union of enabled channels' link_types> ELSE <static _providers aggregation> END`; `user.twist.seq` additionally `GREATEST(…, MAX(channel.seq for instance))`.
- Consumes: existing `channel(twist_instance_id, enabled, link_types jsonb, seq xid8)`, `twist.permissions`.

- [ ] **Step 1: Confirm how DB/view tests run in this repo (pick the runner)**

Run: `ls libs/db/test 2>/dev/null; ls libs/db/*.test.ts 2>/dev/null; grep -rl "user\\.\\|CREATE.*VIEW\\|pg" libs/db --include=*.test.ts 2>/dev/null | head; cat libs/db/package.json | grep -A3 '"scripts"'`
Expected: reveals whether there is an existing vitest+psql harness for the DB package. If one exists, follow its pattern for Step 6. If none exists, Step 6 uses a standalone `psql`-script assertion (a `.sql` fixture + expected output) invoked from a tiny vitest test using `node:child_process` against `$DATABASE_URL`. **Report which you found before writing the test.**

- [ ] **Step 2: Write the failing test (view semantics via psql)**

Create `libs/db/test/dynamic-link-types.test.ts`. It seeds a twist (static) and a twist (dynamic) + a twist_instance + channels directly via SQL against `$DATABASE_URL`, then asserts `user.twist.link_types`. Use the runner shape confirmed in Step 1; the assertions are:

```ts
// Pseudostructure — adapt to the confirmed harness. Each `q(sql)` runs against $DATABASE_URL.
// 1. STATIC connector (no _dynamic_link_types): link_types == static _providers aggregation.
//    Seed twist with permissions {_providers:[{linkTypes:[{type:"x"}]}]}, an instance, no channels.
//    Expect: SELECT link_types FROM user.twist WHERE id=<inst> -> [{"type":"x"}]
// 2. DYNAMIC connector, calendar channel ENABLED with link_types [{type:"event",includesSchedules:true}]
//    AND mail channel ENABLED with [{type:"email"}]:
//    Expect link_types == union/distinct of both; includes includesSchedules:true.
// 3. DYNAMIC connector, calendar channel DISABLED, mail ENABLED:
//    Expect link_types == [{type:"email"}] only (NO includesSchedules) — has-calendar would be false.
// 4. DYNAMIC connector, NO enabled channels: link_types == NULL/[] (NOT the static fallback) —
//    proves a dynamic connector with nothing on yields empty, not its full static set.
```

- [ ] **Step 3: Run it to verify it fails**

Run: `source .worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" pnpm --filter @plotday/db exec vitest run test/dynamic-link-types.test.ts`
Expected: FAIL — dynamic cases return the static aggregation (the view doesn't branch yet).

- [ ] **Step 4: Edit the view schema**

In `libs/db/schema/90-user-schema/32-twist.sql`, replace the `link_types` subquery (currently lines ~43–49) with the branching form:

```sql
    CASE
        WHEN COALESCE((t.permissions ->> '_dynamic_link_types')::boolean, false) THEN
            -- Dynamic: union of the instance's ENABLED channels' link types.
            -- Empty when nothing is enabled (so has-calendar is correctly false);
            -- no fallback to the static set for dynamic connectors.
            (
                SELECT jsonb_agg(DISTINCT lt)
                FROM channel c,
                     jsonb_array_elements(c.link_types) AS lt
                WHERE c.twist_instance_id = pt.id
                  AND c.enabled = true
                  AND c.link_types IS NOT NULL
            )
        ELSE
            -- Static (unchanged): all declared providers' link types.
            (
                SELECT jsonb_agg(lt)
                FROM jsonb_array_elements(t.permissions -> '_providers') AS p,
                     jsonb_array_elements(p -> 'linkTypes') AS lt
            )
    END AS link_types,
```

And extend the `seq` GREATEST (currently lines ~20–24) so channel enable/disable re-emits the row — add a fourth term:

```sql
    GREATEST(pt.seq, t.seq, COALESCE(
        (SELECT MAX(ptc2.seq) FROM twist_instance_connection ptc2
         WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id),
        '0'::xid8
    ), COALESCE(
        (SELECT MAX(c.seq) FROM channel c WHERE c.twist_instance_id = pt.id),
        '0'::xid8
    )) AS seq,
```

- [ ] **Step 5: Generate + apply the migration**

```bash
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"   # MUST print 54335
pnpm --filter @plotday/db gen-migration -- dynamic_link_types
```
Then open the generated migration in `libs/db/migrations/` and append, after the `CREATE OR REPLACE VIEW`:

```sql
-- Re-emit every twist_instance so clients re-pull user.twist with the new link_types source.
UPDATE twist_instance SET updated_at = now();
```

Then:
```bash
pnpm --filter @plotday/db apply-migrations
pnpm --filter @plotday/db diff-schema-migrations   # expect: no differences
```
Expected: applies cleanly; diff shows nothing pending. `apply-migrations` auto-runs `pnpm types`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `source .worktree-db && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" pnpm --filter @plotday/db exec vitest run test/dynamic-link-types.test.ts`
Expected: PASS — static unchanged; dynamic reflects enabled channels; dynamic-with-nothing-enabled is empty.

- [ ] **Step 7: Confirm Squawk safety + types committed**

Run: `git -C "$(git rev-parse --show-toplevel)" diff --stat libs/db/src/types.ts` (expect it changed; stage it). The migration is a `CREATE OR REPLACE VIEW` + an `UPDATE` — additive, no Squawk violation. If `libs/db/.squawk.toml` tooling is available locally, lint the new migration; otherwise rely on CI.

- [ ] **Step 8: Commit (main repo)**

```bash
cd "$(git rev-parse --show-toplevel)"
git add libs/db/schema/90-user-schema/32-twist.sql libs/db/migrations/ libs/db/migrations/atlas.sum libs/db/src/types.ts libs/db/test/dynamic-link-types.test.ts
git commit -m "feat(db): dynamic link types in user.twist (enabled channels' link_types, opt-in flag)"
```

---

### Task 2: `Connector.dynamicLinkTypes` flag → `twist.permissions._dynamic_link_types`

**Files:**
- Modify: `public/twister/src/connector.ts` (add `readonly dynamicLinkTypes?: boolean`) — **submodule**
- Create: `public/.changeset/dynamic-link-types.md` — **submodule**
- Modify: `workers/api/src/twist/storage.ts` (collect `dynamicLinkTypes` from the factory result) — **main repo**
- Modify: `workers/api/src/twist/deployment.ts` (write `permissions._dynamic_link_types = true`) — **main repo**
- Modify: `workers/api/src/twist/factory.ts` if that's where `defaultMentionCreated`/`reactionCapabilities` are read off the twist instance (mirror it for `dynamicLinkTypes`) — **main repo**
- Test: extend the existing deploy/storage test that covers `_default_mention_*` (find it first)

**Interfaces:**
- Consumes: the `user.twist` view's read of `_dynamic_link_types` (Task 1).
- Produces: a connector declaring `readonly dynamicLinkTypes = true` results in `twist.permissions._dynamic_link_types === true` after deploy.

- [ ] **Step 1: Locate the exact flag-collection seam**

Run: `grep -rn "defaultMentionCreated\|defaultMentionMentioned\|reactionCapabilities" workers/api/src/twist/factory.ts workers/api/src/twist/storage.ts public/twister/src/connector.ts public/twister/src/twist.ts`
Expected: shows where these flags are read off the constructed twist (factory), threaded through `storeTwistModule`'s return (storage.ts:30), and written into `permissions` (deployment.ts:194-199). Mirror that exact path for `dynamicLinkTypes`. **Report the seam before editing.**

- [ ] **Step 2: Add the SDK property (failing build first)**

In `public/twister/src/connector.ts`, near `reactionCapabilities` (line ~398), add:

```ts
  /**
   * When true, this connector's effective link types are computed dynamically
   * from its enabled channels' per-channel link types (each channel carries the
   * link types for whatever product/resource it represents), rather than the
   * static union of all declared providers' link types. Lets one connection
   * surface different link types depending on what the user has enabled — e.g.
   * a combined Google connection shows calendar/event link types (and thus the
   * agenda) only when a calendar channel is enabled.
   *
   * Defaults to false (static link types — the behavior for every connector
   * that doesn't set this). Requires the connector to attach per-channel
   * `linkTypes` on the channels returned by `getChannels`.
   */
  readonly dynamicLinkTypes?: boolean;
```

- [ ] **Step 3: Thread it through the deploy path**

Mirror `defaultMentionCreated` exactly (using the seam from Step 1):
- `factory.ts`: read `twist.dynamicLinkTypes` off the constructed instance and include `dynamicLinkTypes` in the factory result.
- `storage.ts:30`: destructure `dynamicLinkTypes` from `twistFactory({...})`.
- `deployment.ts` (next to lines 194-199):

```ts
    // Store dynamic-link-types flag in permissions for the user.twist view.
    if (dynamicLinkTypes) {
      (permissions as any)._dynamic_link_types = true;
    }
```
(Pass `dynamicLinkTypes` from `storeResult` to where `permissions` is finalized, parallel to `_default_mention_*`.)

- [ ] **Step 4: Build twister + changeset**

```bash
cd public/twister && pnpm exec tsx prebuild.ts && pnpm lint   # tsc clean
```
Create `public/.changeset/dynamic-link-types.md`:
```markdown
---
"@plotday/twister": minor
---

Added: Connector.dynamicLinkTypes — opt a connector into per-instance link types computed from its enabled channels' link types (instead of the static union of all declared providers), so one connection can surface link types (and gate features like the agenda) based on what the user has enabled.
```
Run `cd public && pnpm validate-changesets` (expect pass).

- [ ] **Step 5: Test the deploy-path threading**

Find the test covering `_default_mention_*` (`grep -rln "_default_mention\|defaultMention" workers/api/src/**/*.test.ts`), and add a sibling case: a connector stub with `dynamicLinkTypes = true` produces `permissions._dynamic_link_types === true`; one without it omits the key. Run that test file with vitest; expect PASS.

- [ ] **Step 6: Commit (submodule, then main repo)**

```bash
# submodule (SDK + changeset)
cd public && git add twister/src/connector.ts .changeset/dynamic-link-types.md
git commit -m "feat(twister): Connector.dynamicLinkTypes flag"
# main repo (deploy-path threading + test)
cd "$(git rev-parse --show-toplevel)"
git add workers/api/src/twist/factory.ts workers/api/src/twist/storage.ts workers/api/src/twist/deployment.ts workers/api/src/twist/*.test.ts
git commit -m "feat(api): thread dynamicLinkTypes into twist.permissions._dynamic_link_types"
```

---

## Self-Review

**Spec coverage (Phase 1 = spec §2.5 "Dynamic link types"):**
- View derives from enabled channels' link_types when the flag is set → Task 1. ✓
- Fallback to static for existing connectors (no flag) → Task 1 CASE ELSE. ✓
- Empty (not static) when a dynamic connector has nothing enabled → Task 1 Step 2 case #4. ✓
- Channel enable/disable re-syncs the row → Task 1 `MAX(channel.seq)` in `seq`. ✓
- No `twist_instance` column, no Flutter change → confirmed (view-only). ✓
- The opt-in flag a connector sets → Task 2 (`dynamicLinkTypes` → `_dynamic_link_types`). ✓
- Phase 2's `GoogleConnector` will set `dynamicLinkTypes = true` and attach per-channel link types — out of scope here.

**Placeholder scan:** Step 1 of each task is a "locate/confirm the seam, then report" investigation step (the exact file lines for the deploy seam and the DB test runner aren't yet pinned) — these are deliberate discovery steps with concrete commands, not hand-waves; every edit step shows the actual SQL/TS. No "TODO"/"handle errors".

**Type/name consistency:** `dynamicLinkTypes` (camel SDK) ↔ `_dynamic_link_types` (permissions key) ↔ `(t.permissions ->> '_dynamic_link_types')::boolean` (view) are used consistently. `MAX(channel.seq)` uses the confirmed `channel.seq xid8` column.

**Blast radius:** `user.twist` is a core synced view read by every twist_instance. The change is additive (CASE defaulting to today's static branch) — but the `seq` now includes `MAX(channel.seq)`, so EVERY connector re-emits `user.twist` on any channel change (previously it may not have). That's extra sync traffic of an unchanged row for non-dynamic connectors. Verify in testing this is harmless (same `link_types`), and that the one-shot `UPDATE twist_instance` re-emit on migration is acceptable load.
