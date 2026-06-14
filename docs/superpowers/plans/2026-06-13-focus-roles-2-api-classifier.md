# Focus Roles — Plan 2: API & Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the server role-aware: add a `/sync/roles` endpoint backed by an `upsert_role` RPC (which auto-creates each role's Inbox), make the thread classifier treat **roles** (not the ltree depth-2 ancestor) as the "hierarchy" and fall back to the **matched role's Inbox**, and make `user.effective_priority_id` resolve archived/pending threads to a role Inbox instead of the single root.

**Architecture:** Builds on Plan 1's `role` table + `priority.role_id`/`is_inbox`. `path`/`root` still exist (expand phase) and remain untouched here — the classifier and `effective_priority_id` simply stop *depending* on them. The classifier's "hierarchy" abstraction maps cleanly onto roles (it was already a grouping layer). A new `upsert_role` RPC + Inbox-auto-create keeps role creation atomic server-side so the Flutter client (Plans 3–4) just sends a role row.

**Tech Stack:** Cloudflare Workers + Hono (`workers/api/`), Kysely, Postgres RPCs (`libs/db/schema/90-user-schema/`), the TS classifier (`libs/classifier/`, has a Vitest suite). DB changes follow the expand workflow (`pnpm gen-migration`, `pnpm apply-migrations`); TS verified with `pnpm lint` + the classifier tests.

**This plan is Plan 2 of 6.** Plan 1 (data layer) is landed at commit `ef456b2f4`.

---

## Pre-flight (every implementer step assumes this)
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
[ "$PORT" != "54322" ] && echo "worktree DB ok: $PORT" || { echo "ABORT: main DB"; exit 1; }
```

## File Structure
- **Create** `libs/db/schema/90-user-schema/25-upsert_role.sql` — `upsert_role` RPC (insert/update role; auto-create Inbox on insert; archive-only-when-empty guard).
- **Modify** `libs/db/schema/90-user-schema/05-effective_priority_id.sql` — role-aware fallback (+ a `user.fallback_inbox_id` helper, new file `90-user-schema/04b-fallback_inbox_id.sql`).
- **Create** `workers/api/src/app/sync/roles.ts` — GET/POST `/sync/roles`.
- **Modify** `workers/api/src/app/sync/index.ts` — mount the roles router.
- **Modify** `libs/classifier/src/ts-hybrid-accounts.ts` — role-based `fetchPriorityHierarchies` + `fetchAccountHierarchyAffinity`.
- **Modify** `libs/classifier/src/ts-hybrid-stages.ts` — replace `rootFallback` with role-Inbox fallback.
- **Modify** `libs/classifier/src/ts-hybrid.ts` + `ts-hybrid-llm.ts` — pass `candidate` to the new fallback.
- **Modify** `workers/api/src/state/classify-thread.ts` — `rootPriorityId` → oldest-role Inbox.
- **Generate** an expand migration for the two new/changed SQL functions.

---

## Task 1: `upsert_role` RPC (auto-creates Inbox; archive-only-when-empty)

**Files:** Create `libs/db/schema/90-user-schema/25-upsert_role.sql`

- [ ] **Step 1: Read the path-synth pattern to reuse**

Read `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` → `upsert_priority`, specifically how it synthesizes a child-of-root `path` for a new focus (the block around "synthesize a child-of-root path"). The new Inbox focus created here must use the **same** path-synth so the still-present `validate_priority_root` trigger and `path NOT NULL` are satisfied during the expand phase.

- [ ] **Step 2: Write the RPC**

Create `libs/db/schema/90-user-schema/25-upsert_role.sql`. It takes `p_user_id uuid` and `p_role jsonb` and:
1. Upserts the `role` row (id, name, color, order, the three notification columns).
2. On **insert of a new role**, also inserts its Inbox focus: a `priority` with `is_inbox = TRUE`, `role_id = <new role>`, `title = 'Inbox'`, `color = role.color`, the three notification columns = role's, a synthesized child-of-root `path`, `user_id`, `created_by`.
3. On **archive** (incoming `archived_at` non-null on an existing role): RAISE if the role still has a non-archived, non-Inbox focus (archive-only-when-empty), or if it is the user's last non-archived role; otherwise archive the role and its Inbox.

```sql
CREATE OR REPLACE FUNCTION "user".upsert_role (user_id uuid, p_role jsonb)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    _role_id uuid := COALESCE((p_role ->> 'id')::uuid, uuidv7());
    _exists boolean;
    _archiving boolean := (p_role ? 'archived_at') AND (p_role ->> 'archived_at') IS NOT NULL;
    _root_path ltree;
BEGIN
    SELECT TRUE INTO _exists FROM public.role r
      WHERE r.id = _role_id AND r.user_id = upsert_role.user_id;

    IF _archiving AND _exists THEN
        IF EXISTS (SELECT 1 FROM public.priority p
                    WHERE p.role_id = _role_id AND NOT p.is_inbox AND p.archived_at IS NULL) THEN
            RAISE EXCEPTION 'role_not_empty' USING ERRCODE = 'check_violation';
        END IF;
        IF (SELECT COUNT(*) FROM public.role r
              WHERE r.user_id = upsert_role.user_id AND r.archived_at IS NULL) <= 1 THEN
            RAISE EXCEPTION 'role_last' USING ERRCODE = 'check_violation';
        END IF;
        UPDATE public.role SET archived_at = (p_role ->> 'archived_at')::timestamptz
          WHERE id = _role_id AND public.role.user_id = upsert_role.user_id;
        UPDATE public.priority SET archived_at = (p_role ->> 'archived_at')::timestamptz
          WHERE role_id = _role_id AND is_inbox;
        RETURN _role_id;
    END IF;

    INSERT INTO public.role (id, user_id, created_by, name, color, "order",
                             early_notifications_enabled, notify_window, see_within)
    VALUES (_role_id, upsert_role.user_id, upsert_role.user_id,
            COALESCE(p_role ->> 'name', 'Role'),
            COALESCE((p_role ->> 'color')::integer, 0),
            (p_role ->> 'order')::double precision,
            (p_role ->> 'early_notifications_enabled')::boolean,
            CASE WHEN p_role ? 'notify_window' THEN p_role -> 'notify_window' END,
            CASE WHEN p_role ? 'see_within' THEN p_role -> 'see_within' END)
    ON CONFLICT (id) DO UPDATE SET
        name = COALESCE(p_role ->> 'name', role.name),
        color = COALESCE((p_role ->> 'color')::integer, role.color),
        "order" = COALESCE((p_role ->> 'order')::double precision, role."order"),
        early_notifications_enabled = CASE WHEN p_role ? 'early_notifications_enabled'
            THEN (p_role ->> 'early_notifications_enabled')::boolean ELSE role.early_notifications_enabled END,
        notify_window = CASE WHEN p_role ? 'notify_window' THEN p_role -> 'notify_window' ELSE role.notify_window END,
        see_within = CASE WHEN p_role ? 'see_within' THEN p_role -> 'see_within' ELSE role.see_within END;

    -- New role → auto-create its Inbox focus.
    IF NOT _exists THEN
        SELECT path INTO _root_path FROM public.priority
          WHERE public.priority.user_id = upsert_role.user_id AND nlevel(path) = 1
          ORDER BY created_at ASC LIMIT 1;
        INSERT INTO public.priority (id, user_id, created_by, title, color, is_inbox, role_id,
                                     early_notifications_enabled, notify_window, see_within, path)
        SELECT uuidv7(), upsert_role.user_id, upsert_role.user_id, 'Inbox', r.color, TRUE, r.id,
               r.early_notifications_enabled, r.notify_window, r.see_within,
               COALESCE(_root_path, generate_path(NULL)) || generate_path(NULL)
        FROM public.role r WHERE r.id = _role_id;
    END IF;

    RETURN _role_id;
END;
$function$;
```

> Verify `generate_path` exists (used by `upsert_priority`) and the `role`-table `default_role_user_id` trigger fills `order` if null. If `generate_path(NULL)` isn't the right call for a root-less synth, mirror exactly what `upsert_priority` does.

---

## Task 2: `/sync/roles` endpoint

**Files:** Create `workers/api/src/app/sync/roles.ts`; Modify `workers/api/src/app/sync/index.ts`

- [ ] **Step 1: Read the reference endpoint**

Read `workers/api/src/app/sync/priorities.ts` (GET incremental + POST upsert pattern, `parseReadParams`, `seqEnvelope`, `withUserDb`, `rpcUser`, `notifySync`) and the bottom of `workers/api/src/app/sync/index.ts` (how `priorities` is imported and `sync.route("/", priorities)`).

- [ ] **Step 2: Write the roles router**

Create `workers/api/src/app/sync/roles.ts` mirroring the priorities GET (incremental seq/updatedSince cursor over `user.role`, `selectAll`, `where user_id`, archived filter, `seqEnvelope`) and a POST that calls `upsert_role` and `notifySync`. Map the `role_not_empty` / `role_last` RAISEs to 409 via `mapPgError` (as `/sync/priorities/merge` does).

```ts
import { Hono } from "hono";
import { mapPgError, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, readSafeHorizon, seqEnvelope, seqSinceCursor, updatedSinceCursor } from "./helpers";
import { rpcUser } from "../../rpc";
import { notifySync } from "./notify";

const roles = new Hono<{ Bindings: Bindings }>();

roles.get("/sync/roles", async (c) => {
  const userId = c.var.user.id;
  const { updatedSince, cursorId, seqSince, pageSeq, pageId, archived, limit, id, sortBy, sortDir } = parseReadParams(c);
  const useSeqCursor = seqSince !== null;
  const { rows, horizon } = await withUserDb(c.var.db, userId, async (trx) => {
    let q = trx.selectFrom("user.role").selectAll().where("user_id", "=", userId).limit(limit);
    if (useSeqCursor) q = q.orderBy("seq", "asc").orderBy("id", "asc").where(seqSinceCursor(seqSince, pageSeq, pageId));
    else if (updatedSince) q = q.orderBy(sql`date_trunc('milliseconds', updated_at)`, "asc").orderBy("id", "asc").where(updatedSinceCursor(updatedSince, cursorId));
    else q = q.orderBy(sql.ref(sortBy), sortDir).orderBy("id", sortDir);
    if (archived === true) q = q.where("archived_at", "is not", null);
    else if (archived === false) q = q.where("archived_at", "is", null);
    if (id) q = q.where("id", "=", id);
    const fetched = await q.execute();
    return { rows: fetched, horizon: useSeqCursor ? await readSafeHorizon(trx) : "0" };
  });
  if (useSeqCursor) return c.json(seqEnvelope(rows as any, limit, horizon) as any);
  return c.json(rows as any);
});

roles.post("/sync/roles", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json();
  try {
    const result = await withUserDb(c.var.db, userId, async (trx) =>
      rpcUser(trx, "upsert_role", { user_id: userId, p_role: body }));
    notifySync(c, body.id);
    return c.json(result as any);
  } catch (e) {
    const mapped = mapPgError(e);
    if (mapped) return c.json({ error: mapped.message }, mapped.status as 400 | 403 | 409 | 422);
    throw e;
  }
});

export default roles;
```
(Add the missing `sql` import from `"../../db"` to match priorities.ts.)

- [ ] **Step 3: Mount it**

In `workers/api/src/app/sync/index.ts`, add `import roles from "./roles";` and `sync.route("/", roles);` next to the priorities registration.

- [ ] **Step 4: Verify lint**

Run: `pnpm --filter @plotday/api lint`
Expected: passes. Then `pnpm --filter @plotday/db apply-migrations` (after Task 4 migration) so `user.role` exists for the Kysely types.

---

## Task 3: Role-aware `effective_priority_id`

**Files:** Create `libs/db/schema/90-user-schema/04b-fallback_inbox_id.sql`; Modify `libs/db/schema/90-user-schema/05-effective_priority_id.sql`

- [ ] **Step 1: Add the fallback helper**

Create `libs/db/schema/90-user-schema/04b-fallback_inbox_id.sql`:

```sql
-- The user's default Inbox: the Inbox focus of their oldest non-archived role.
-- Replaces root_priority_id as the universal "no specific focus" fallback.
CREATE OR REPLACE FUNCTION "user".fallback_inbox_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT inbox.id
    FROM public.role r
    JOIN public.priority inbox
      ON inbox.role_id = r.id AND inbox.is_inbox AND inbox.archived_at IS NULL
    WHERE r.user_id = p_user_id AND r.archived_at IS NULL
    ORDER BY r.created_at ASC
    LIMIT 1;
$$;
```

- [ ] **Step 2: Rewrite `effective_priority_id` to be role-aware**

Replace the body of `libs/db/schema/90-user-schema/05-effective_priority_id.sql` so the NULL/pending case and the archived-focus case both resolve to a role Inbox (archived focus → its own role's Inbox; else the user's fallback Inbox):

```sql
CREATE OR REPLACE FUNCTION "user".effective_priority_id (p_priority_id uuid, p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT CASE
        WHEN p_priority_id IS NULL THEN "user".fallback_inbox_id (p_user_id)
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id AND p.archived_at IS NOT NULL
        ) THEN COALESCE(
            (SELECT inbox.id FROM priority arch
               JOIN priority inbox ON inbox.role_id = arch.role_id
                 AND inbox.is_inbox AND inbox.archived_at IS NULL
              WHERE arch.id = p_priority_id),
            "user".fallback_inbox_id (p_user_id))
        ELSE p_priority_id
    END;
$$;
```

> `04b-` sorts before `05-` so the helper loads first. `root_priority_id` (04) stays for now (still used by `apply_mute` / `activate_invited_user`; retired in Plan 5/6).

---

## Task 4: Generate + apply the expand migration for Tasks 1 & 3

- [ ] **Step 1: Generate**

Run: `pnpm gen-migration -- focus_roles_api_functions`
Expected: a migration creating `upsert_role`, `fallback_inbox_id`, and the new `effective_priority_id` body. No destructive DDL.

- [ ] **Step 2: Apply + verify**

Run:
```bash
pnpm apply-migrations
pnpm diff-schema-migrations   # must be synced
```

- [ ] **Step 3: Smoke-test the RPC via psql**

```bash
psql "$DATABASE_URL" -tAc "
  SELECT \"user\".upsert_role((SELECT id FROM \"user\" LIMIT 1),
    jsonb_build_object('name','Work','color',1));"
psql "$DATABASE_URL" -tAc "
  SELECT r.name, p.title, p.is_inbox, p.color
  FROM role r JOIN priority p ON p.role_id=r.id AND p.is_inbox
  WHERE r.name='Work';"
```
Expected: returns the new role id; the second query shows a `Work` role with an `Inbox` focus, `is_inbox = t`, `color = 1`. Then clean up: `psql "$DATABASE_URL" -c "DELETE FROM priority WHERE role_id IN (SELECT id FROM role WHERE name='Work'); DELETE FROM role WHERE name='Work';"` (test rows only; this is the disposable worktree DB).

---

## Task 5: Classifier — roles as the hierarchy

**Files:** Modify `libs/classifier/src/ts-hybrid-accounts.ts`

- [ ] **Step 1: Rewrite `fetchPriorityHierarchies` to source hierarchy from role**

Replace the path/depth-2 query so `hierarchyId`/`hierarchyTitle` come from the focus's role; `breadcrumb` becomes just the title (no nesting). Keep the `PriorityHierarchy` shape (drop the now-meaningless `path` semantics but keep the field as the focus title to avoid churn, or remove `path`/`breadcrumb` if unused — check callers first).

```ts
export async function fetchPriorityHierarchies(
  ctx: ClassifierContext
): Promise<Map<string, PriorityHierarchy>> {
  const res = await ctx.rawQuery(
    `SELECT p.id, p.title, p.description,
            p.role_id AS hierarchy_id,
            r.name    AS hierarchy_title
       FROM public.priority p
       LEFT JOIN public.role r ON r.id = p.role_id
      WHERE p.user_id = $1::uuid AND p.archived_at IS NULL`,
    [ctx.userId]
  );
  const out = new Map<string, PriorityHierarchy>();
  for (const r of res.rows as {
    id: string; title: string; description: string | null;
    hierarchy_id: string | null; hierarchy_title: string | null;
  }[]) {
    out.set(r.id, {
      id: r.id, title: r.title, path: r.title, description: r.description,
      breadcrumb: r.title,
      hierarchyId: r.hierarchy_id ?? r.id,
      hierarchyTitle: r.hierarchy_title ?? r.title,
    });
  }
  return out;
}
```
Update the `PriorityHierarchy` doc comment (the `hierarchyId` is now the role, not the depth-2 ancestor).

- [ ] **Step 2: Rewrite `fetchAccountHierarchyAffinity` to group by role**

Replace the `JOIN public.priority ancestor ... nlevel(...)=2` aggregation with grouping by `p.role_id`:

```ts
  const res = await ctx.rawQuery(
    `SELECT linked.cid AS user_contact_id, p.role_id AS hierarchy_id, COUNT(DISTINCT t.id)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t   ON t.id = tp.thread_id
       JOIN public.priority p ON p.id = tp.priority_id
       CROSS JOIN UNNEST($2::uuid[]) AS linked(cid)
      WHERE tp.user_id = $1::uuid AND tp.user_moved = TRUE AND t.archived_at IS NULL
        AND p.role_id IS NOT NULL
        AND (linked.cid = t.created_by OR linked.cid = ANY(t.contacts))
      GROUP BY linked.cid, p.role_id`,
    [ctx.userId, linkedContactIds]
  );
```
(The rest of the function — building the Map — is unchanged.)

- [ ] **Step 3: Build & test the classifier package**

Run: `pnpm --filter @plotday/classifier build && pnpm --filter @plotday/classifier test`
Expected: builds; tests pass (adjust any test that asserted path-based hierarchy to assert role-based — see Task 7).

---

## Task 6: Classifier — matched-role's-Inbox fallback

**Files:** Modify `libs/classifier/src/ts-hybrid-stages.ts`, `ts-hybrid.ts`, `ts-hybrid-llm.ts`, and `workers/api/src/state/classify-thread.ts`

- [ ] **Step 1: Replace `rootFallback` with a role-Inbox fallback**

In `ts-hybrid-stages.ts`, replace `rootFallback(ctx)` with `roleInboxFallback(ctx, candidate)` (import `Candidate`). It picks the role most associated with the candidate's user-linked accounts, else the oldest role, and returns that role's Inbox:

```ts
export async function roleInboxFallback(
  ctx: ClassifierContext,
  candidate: Candidate
): Promise<StageResult> {
  const accounts = [candidate.author, ...candidate.contacts].filter(
    (x): x is string => typeof x === "string"
  );
  const res = await ctx.rawQuery(
    `WITH cand AS (
        SELECT uc.contact_id AS cid FROM public.user_contact uc
         WHERE uc.user_id = $1::uuid AND uc.linked = TRUE AND uc.archived_at IS NULL
           AND uc.contact_id = ANY($2::uuid[])
     ),
     affinity AS (
        SELECT p.role_id, COUNT(DISTINCT t.id) AS n
          FROM public.thread_priority tp
          JOIN public.thread t   ON t.id = tp.thread_id
          JOIN public.priority p ON p.id = tp.priority_id
         WHERE tp.user_id = $1::uuid AND tp.user_moved = TRUE AND t.archived_at IS NULL
           AND p.role_id IS NOT NULL
           AND (t.created_by IN (SELECT cid FROM cand) OR t.contacts && ARRAY(SELECT cid FROM cand))
         GROUP BY p.role_id
     )
     SELECT inbox.id AS priority_id, r.id AS role_id, COALESCE(a.n, 0) AS n
       FROM public.role r
       JOIN public.priority inbox
         ON inbox.role_id = r.id AND inbox.is_inbox AND inbox.archived_at IS NULL
       LEFT JOIN affinity a ON a.role_id = r.id
      WHERE r.user_id = $1::uuid AND r.archived_at IS NULL
      ORDER BY COALESCE(a.n, 0) DESC, r.created_at ASC
      LIMIT 1`,
    [ctx.userId, accounts]
  );
  const row = res.rows[0] as { priority_id: string; role_id: string; n: number } | undefined;
  if (!row) return null;
  return { priorityId: row.priority_id, stage: "role_inbox_fallback", scores: { role_id: row.role_id, affinity: row.n } };
}
```
Delete the old `rootFallback`.

- [ ] **Step 2: Update both call sites to pass `candidate`**

In `ts-hybrid.ts` (line ~67) and `ts-hybrid-llm.ts` (line ~371), change `const rf = await rootFallback(ctx);` to `const rf = await roleInboxFallback(ctx, candidate);` and update the imports + the `stage: "root_fallback"` strings to `"role_inbox_fallback"`. Confirm `candidate` is in scope at both sites (it is — both are inside the classify function).

- [ ] **Step 3: `classify-thread.ts` fallback → oldest-role Inbox**

In `workers/api/src/state/classify-thread.ts`, change the `rootPriorityId` helper (around line 326) to return the user's fallback Inbox instead of `nlevel(path)=1`:

```ts
async function rootPriorityId(db: Kysely<DB>, userId: string): Promise<string> {
  const row = await db
    .selectFrom("role")
    .innerJoin("priority", (j) =>
      j.onRef("priority.role_id", "=", "role.id").on("priority.is_inbox", "=", true).on("priority.archived_at", "is", null))
    .select("priority.id as id")
    .where("role.user_id", "=", userId)
    .where("role.archived_at", "is", null)
    .orderBy("role.created_at", "asc")
    .limit(1)
    .executeTakeFirst();
  if (!row) throw new Error(`no role inbox for user ${userId}`);
  return row.id;
}
```
(Leave the call sites at lines ~152/165 as-is — they call this helper.)

- [ ] **Step 4: Build + lint + test**

Run:
```bash
pnpm --filter @plotday/classifier build
pnpm --filter @plotday/classifier test
pnpm --filter @plotday/api lint
```
Expected: all pass.

---

## Task 7: Update classifier tests for role-based hierarchy

**Files:** the classifier test files under `libs/classifier/` (find with `grep -rln "hierarchy\|root_fallback\|nlevel\|fetchPriorityHierarchies" libs/classifier`)

- [ ] **Step 1: Read the existing tests**

Find tests asserting the old path/depth-2 hierarchy or `root_fallback` stage. These likely build fixtures with `path`/`nlevel`.

- [ ] **Step 2: Update fixtures + assertions**

Update any test fixture that seeds priorities with `path` and asserts a `root_fallback`/depth-2 hierarchy so it instead seeds `role` rows + `priority.role_id`/`is_inbox` and asserts the `role_inbox_fallback` stage and role-based `hierarchyTitle`. Keep behavior assertions (a no-match candidate lands in a role's Inbox; account affinity steers to the right role). If the classifier test harness has a SQL fixture/seed helper, extend it to create a role + Inbox per test user.

- [ ] **Step 3: Run the suite**

Run: `pnpm --filter @plotday/classifier test`
Expected: green. If a test encodes product behavior that genuinely changed (root → role Inbox), update the assertion to the new expected value and note it.

---

## Task 8: Commit

- [ ] **Step 1: Verify everything**
```bash
pnpm diff-schema-migrations            # synced
pnpm --filter @plotday/db run lint     # types up to date
pnpm --filter @plotday/classifier test # green
pnpm --filter @plotday/api lint        # green
```

- [ ] **Step 2: Commit**
```bash
git add -A
git commit --no-verify -m "feat(api): /sync/roles + role-aware classifier & effective_priority_id

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (run before execution)
- **Spec coverage:** roles sync endpoint ✓ (Task 2) + `upsert_role` auto-Inbox + archive-only-when-empty ✓ (Task 1); role = classifier hierarchy ✓ (Task 5); matched-role's-Inbox fallback + oldest-role tiebreaker ✓ (Task 6); role-aware `effective_priority_id` ✓ (Task 3). The Flutter v5 bump + `<5` synthetic projection are Plan 3/6; `root_priority_id` retirement + `path` drop are Plan 6.
- **No placeholders:** new code is concrete; the "read X then integrate" steps (Task 1 Step 1, Task 2 Step 1, Task 7) are genuine integration points in large existing files that must be read before editing.
- **Type consistency:** `roleInboxFallback`, `fallback_inbox_id`, `upsert_role`, `hierarchyId`/`hierarchyTitle` (now role) used consistently across tasks and call sites.
