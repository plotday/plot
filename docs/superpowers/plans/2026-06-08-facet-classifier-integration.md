# Facet Classifier Integration — Implementation Plan (Plan 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make thread facets (from Plan 1) actually affect classification: focuses gain LLM-derived `facet_filters`, the classifier hard-gates the scoring stage (fail-open, with a per-focus trusted-sender exception + live org-domain trust), and focus creation persists its description.

**Architecture:** New nullable `priority.facet_filters` / `priority.description` columns and a seeded `freemail_domain` table. Pure SQL helpers (`intrinsic_facets_violate`, `is_trusted_for_focus`, `author_matches_org_domain`, `thread_facets_gated`) encode the gate. `classify_thread_for_user_explain` loads `thread.facets`/`author_id` and excludes gated focuses when selecting the scoring winner. A new API module derives `facet_filters` from a focus's title+description via Claude (reusing the `priority-match.ts` gateway pattern) in a `waitUntil` background task on `/sync/priorities`. `find-matching-threads` applies the same intrinsic filters to its preview.

**Tech Stack:** PostgreSQL + Atlas + pgTAP, Kysely, Hono (Cloudflare Workers), `@ai-sdk/anthropic` + `ai` (`generateObject`) + zod, Vitest.

**Prerequisite:** Plan 1 merged (`thread.facets` column exists; connectors emit facets). This plan is entirely in the **main repo** (no submodule changes). Optionally one tiny Flutter serialization change (Task 8, flagged for your decision).

---

## Pre-flight

- [ ] **Step 0.1: Confirm Plan 1 landed and DB is current**

Run:
```bash
psql "$DATABASE_URL" -tAc "show port;"   # worktree port, not 54322 if in a worktree
psql "$DATABASE_URL" -tAc "SELECT 1 FROM information_schema.columns WHERE table_name='thread' AND column_name='facets';"
```
Expected: the port prints; the second query returns `1` (Plan 1's `thread.facets` exists). If empty, apply Plan 1's migration first (`pnpm apply-migrations`).

- [ ] **Step 0.2: Branch**

```bash
cd /Users/kris.braun/code/plot
git checkout -b facet-classifier-integration
```

---

## File Structure

- Modify: `libs/db/schema/50-tables/22-priority.sql` — `facet_filters`, `description` columns.
- Create: `libs/db/schema/50-tables/35-freemail_domain.sql` — reference table.
- Create: `libs/db/schema/99-data/10-freemail-domain.sql` — seed.
- Create: `libs/db/schema/60-functions/facet_gate.sql` — gate helper functions.
- Modify: `libs/db/schema/60-functions/classify_thread_for_user.sql` — load facets/author_id, gate winner selection.
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — persist `description` in `upsert_priority`.
- Create: `libs/db/tests/65-facet-gate.sql` — pgTAP.
- Create: `workers/api/src/state/facet-registry.ts` — dimension/value descriptions + zod schema.
- Create: `workers/api/src/state/derive-facet-filters.ts` — LLM derivation.
- Create: `workers/api/src/state/facet-registry.test.ts`, `derive-facet-filters.test.ts`.
- Modify: `workers/api/src/app/sync/priorities.ts` — kick off derivation in `waitUntil`.
- Modify: `workers/api/src/app/sync/priority-match.ts` — intrinsic filtering of preview.
- Modify: `docs/updates.md`, `docs/features.md`.
- (Optional) `apps/plot/...` — include `description` in the priority sync payload.

---

## Task 1: Schema — `facet_filters`, `description`, `freemail_domain`

**Files:**
- Modify: `libs/db/schema/50-tables/22-priority.sql`
- Create: `libs/db/schema/50-tables/35-freemail_domain.sql`
- Create: `libs/db/schema/99-data/10-freemail-domain.sql`

- [ ] **Step 1.1: Add priority columns**

In `libs/db/schema/50-tables/22-priority.sql`, after the `"config" jsonb,` line (line 33), add:

```sql
    "facet_filters" jsonb,
    "description" text,
```

(Both nullable, backend-only. They will NOT be added to the `user.priority` view, so they never sync to clients — see Step 1.5.)

- [ ] **Step 1.2: Create the freemail reference table**

Create `libs/db/schema/50-tables/35-freemail_domain.sql`:

```sql
-- Freemail / public email hosts. Used by the classifier's org-domain trust
-- check: a sender whose domain is in this table is NOT treated as "same org"
-- as the user. Seeded in 99-data; safe to extend.
CREATE TABLE "public"."freemail_domain" (
    "domain" text PRIMARY KEY
);
```

- [ ] **Step 1.3: Seed the freemail domains**

Create `libs/db/schema/99-data/10-freemail-domain.sql`:

```sql
INSERT INTO "public"."freemail_domain" ("domain") VALUES
    ('gmail.com'), ('yahoo.com'), ('hotmail.com'), ('outlook.com'),
    ('icloud.com'), ('aol.com'), ('protonmail.com'), ('proton.me'),
    ('mail.com'), ('zoho.com'), ('yandex.com'), ('gmx.com'),
    ('live.com'), ('me.com'), ('msn.com')
ON CONFLICT ("domain") DO NOTHING;
```

- [ ] **Step 1.4: Generate, apply, regenerate types**

```bash
cd /Users/kris.braun/code/plot
pnpm gen-migration -- add_facet_filters_description_freemail
pnpm apply-migrations
```
Expected: migration adds two priority columns + the `freemail_domain` table + seed; applies cleanly; auto-runs `pnpm types`. Confirm `psql "$DATABASE_URL" -tAc "SELECT count(*) FROM freemail_domain;"` returns `15`.

- [ ] **Step 1.5: Verify backend-only (not synced)**

Run: `rg -n "facet_filters|p\.description|description" libs/db/schema/90-user-schema/22-priority.sql`
Expected: no matches (the `user.priority` view names columns explicitly and does not include these). If it somehow does, remove them — they must not sync.

- [ ] **Step 1.6: Verify schema/migration sync and commit**

```bash
pnpm diff-schema-migrations   # expect: no differences
git add libs/db/schema/50-tables/22-priority.sql libs/db/schema/50-tables/35-freemail_domain.sql libs/db/schema/99-data/10-freemail-domain.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add priority.facet_filters/description + freemail_domain"
```

---

## Task 2: SQL gate helper functions

**Files:**
- Create: `libs/db/schema/60-functions/facet_gate.sql`

- [ ] **Step 2.1: Create the helper functions**

Create `libs/db/schema/60-functions/facet_gate.sql`:

```sql
-- Facet gate helpers used by classify_thread_for_user (scoring stage) and the
-- find-matching-threads preview. See docs/superpowers/specs/2026-06-08-thread-facet-classification-design.md.

-- True if a thread's intrinsic facets (format/automation/reach) violate a
-- focus's include/exclude filters. Fail-open: a null/absent facet value never
-- violates an include filter. Null filters → never violates.
CREATE OR REPLACE FUNCTION public.intrinsic_facets_violate (
    p_facets jsonb,
    p_filters jsonb
)
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT COALESCE((
        SELECT bool_or(
            -- exclude violation: known value is in the exclude set
            (
                p_filters -> dims.dim ? 'exclude'
                AND p_facets ->> dims.dim IS NOT NULL
                AND p_facets ->> dims.dim IN (
                    SELECT jsonb_array_elements_text(p_filters -> dims.dim -> 'exclude')
                )
            )
            OR
            -- include violation: include set present, value known, not included
            (
                p_filters -> dims.dim ? 'include'
                AND p_facets ->> dims.dim IS NOT NULL
                AND p_facets ->> dims.dim NOT IN (
                    SELECT jsonb_array_elements_text(p_filters -> dims.dim -> 'include')
                )
            )
        )
        FROM (VALUES ('format'), ('automation'), ('reach')) AS dims(dim)
    ), FALSE);
$function$;

COMMENT ON FUNCTION public.intrinsic_facets_violate IS 'True if a thread''s format/automation/reach facets violate a focus''s include/exclude filters. Fail-open on null facet values.';

-- True if the user has explicitly associated the author with the focus: the
-- author participates in a thread filed in the focus that the user moved in
-- (user_moved) or composed (created_by = user). Powers both the gate''s sender
-- exception and the trust filter.
CREATE OR REPLACE FUNCTION public.is_trusted_for_focus (
    p_user_id uuid,
    p_author_id uuid,
    p_priority_id uuid
)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT p_author_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.priority_id = p_priority_id
          AND (tp.user_moved = TRUE OR t.created_by = p_user_id)
          AND p_author_id = ANY(t.contacts)
    );
$function$;

COMMENT ON FUNCTION public.is_trusted_for_focus IS 'True if the author participates in a thread the user moved into / composed in this focus (per-focus trusted sender).';

-- True if the author''s email domain matches one of the user''s own linked
-- identity domains, excluding freemail/public hosts.
CREATE OR REPLACE FUNCTION public.author_matches_org_domain (
    p_user_id uuid,
    p_author_id uuid
)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    WITH author_domain AS (
        SELECT lower(split_part(c.email, '@', 2)) AS dom
        FROM public.contact c
        WHERE c.id = p_author_id AND c.email IS NOT NULL
    ),
    user_domains AS (
        SELECT DISTINCT lower(split_part(c.email, '@', 2)) AS dom
        FROM public.user_contact uc
        JOIN public.contact c ON c.id = uc.contact_id
        WHERE uc.user_id = p_user_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
          AND c.email IS NOT NULL
    )
    SELECT EXISTS (
        SELECT 1
        FROM author_domain ad
        JOIN user_domains ud ON ud.dom = ad.dom
        WHERE ad.dom <> ''
          AND NOT EXISTS (SELECT 1 FROM public.freemail_domain f WHERE f.domain = ad.dom)
    );
$function$;

COMMENT ON FUNCTION public.author_matches_org_domain IS 'True if author email domain matches the user''s own linked identity domain, excluding freemail.';

-- Whether a thread should be EXCLUDED from a focus by its facet filters.
-- Intrinsic violations are bypassed when the author is trusted for the focus
-- (per-focus user override). trustedSendersOnly admits trusted-for-focus or
-- org-domain authors. Null filters → never gated.
CREATE OR REPLACE FUNCTION public.thread_facets_gated (
    p_user_id uuid,
    p_facets jsonb,
    p_author_id uuid,
    p_priority_id uuid
)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    v_filters jsonb;
    v_trusted_focus boolean;
BEGIN
    SELECT facet_filters INTO v_filters FROM public.priority WHERE id = p_priority_id;
    IF v_filters IS NULL THEN
        RETURN FALSE;
    END IF;

    v_trusted_focus := public.is_trusted_for_focus(p_user_id, p_author_id, p_priority_id);

    -- Intrinsic gate, bypassed by a trusted-for-focus author.
    IF NOT v_trusted_focus AND public.intrinsic_facets_violate(p_facets, v_filters) THEN
        RETURN TRUE;
    END IF;

    -- Trust filter.
    IF COALESCE((v_filters ->> 'trustedSendersOnly')::boolean, FALSE)
       AND NOT (v_trusted_focus OR public.author_matches_org_domain(p_user_id, p_author_id)) THEN
        RETURN TRUE;
    END IF;

    RETURN FALSE;
END;
$function$;

COMMENT ON FUNCTION public.thread_facets_gated IS 'True if a thread is excluded from a focus by facet filters. Bypassed for per-focus trusted senders; trustedSendersOnly admits trusted-for-focus or org-domain authors.';
```

- [ ] **Step 2.2: Generate and apply the migration**

```bash
cd /Users/kris.braun/code/plot
pnpm gen-migration -- add_facet_gate_functions
pnpm apply-migrations
```
Expected: migration creates the four functions; applies cleanly.

- [ ] **Step 2.3: Smoke-test the pure helper**

Run:
```bash
psql "$DATABASE_URL" -tAc "SELECT public.intrinsic_facets_violate('{\"format\":\"notification\"}'::jsonb, '{\"format\":{\"exclude\":[\"notification\"]}}'::jsonb);"
psql "$DATABASE_URL" -tAc "SELECT public.intrinsic_facets_violate('{\"format\":null}'::jsonb, '{\"format\":{\"include\":[\"reading\"]}}'::jsonb);"
```
Expected: first prints `t` (excluded), second prints `f` (fail-open on null).

- [ ] **Step 2.4: Commit**

```bash
git add libs/db/schema/60-functions/facet_gate.sql libs/db/migrations/
git commit -m "feat(db): facet gate helper functions"
```

---

## Task 3: Wire the gate into `classify_thread_for_user_explain`

**Files:**
- Modify: `libs/db/schema/60-functions/classify_thread_for_user.sql`

- [ ] **Step 3.1: Declare facets/author locals**

In `classify_thread_for_user.sql`, in the `DECLARE` block (after `v_groups uuid[];`, ~line 78), add:

```sql
    v_facets jsonb;
    v_author_id uuid;
```

- [ ] **Step 3.2: Load facets + author_id with the other thread signals**

Replace the signal-load SELECT (lines ~86-89):

```sql
        SELECT t.embedding, t.topic, t.contacts, t.groups
        INTO v_embedding, v_topic, v_contacts, v_groups
        FROM public.thread t
        WHERE t.id = p_thread_id;
```

with:

```sql
        SELECT t.embedding, t.topic, t.contacts, t.groups, t.facets, t.author_id
        INTO v_embedding, v_topic, v_contacts, v_groups, v_facets, v_author_id
        FROM public.thread t
        WHERE t.id = p_thread_id;
```

(When called without `p_thread_id` — the param-only eval path — `v_facets`/`v_author_id` stay NULL and the gate is a no-op. That's intended.)

- [ ] **Step 3.3: Gate the scoring-stage winner selection**

Replace the winner SELECT (lines ~271-276):

```sql
    SELECT (x.priority_id)::uuid INTO v_matched
    FROM jsonb_to_recordset(v_scores->'top')
        AS x(priority_id uuid, combined numeric)
    WHERE x.combined >= 0.15
    ORDER BY x.combined DESC
    LIMIT 1;
```

with (adds the gate predicate):

```sql
    SELECT (x.priority_id)::uuid INTO v_matched
    FROM jsonb_to_recordset(v_scores->'top')
        AS x(priority_id uuid, combined numeric)
    WHERE x.combined >= 0.15
      -- Facet gate: drop a scored focus whose filters this thread violates,
      -- unless a per-focus trusted-sender exception applies. Only the scoring
      -- stage is gated; explicit/structural stages above always win. A
      -- fully-gated thread falls through to priority_prefix / root_fallback.
      AND NOT public.thread_facets_gated(p_user_id, v_facets, v_author_id, x.priority_id)
    ORDER BY x.combined DESC
    LIMIT 1;
```

- [ ] **Step 3.4: Update the file's algorithm comment (step 3)**

In the header comment block, in the bullet describing step 3 (scoring, ~lines 38-44), append a sentence:

```sql
--      Focuses whose facet_filters this thread violates are excluded here
--      (public.thread_facets_gated), unless the author is trusted for that
--      focus. The earlier stages are never gated.
```

- [ ] **Step 3.5: Generate and apply**

```bash
cd /Users/kris.braun/code/plot
pnpm gen-migration -- gate_classifier_scoring_on_facets
pnpm apply-migrations
pnpm diff-schema-migrations   # expect no differences
```
Expected: migration `CREATE OR REPLACE`s both `classify_thread_for_user_explain` and the `classify_thread_for_user` wrapper (Atlas regenerates both from the file); applies cleanly.

- [ ] **Step 3.6: Commit**

```bash
git add libs/db/schema/60-functions/classify_thread_for_user.sql libs/db/migrations/
git commit -m "feat(db): gate classifier scoring stage on facet filters"
```

---

## Task 4: pgTAP — gate, trust, exception, org-domain

**Files:**
- Create: `libs/db/tests/65-facet-gate.sql`

- [ ] **Step 4.1: Write the pgTAP test**

Create `libs/db/tests/65-facet-gate.sql`:

```sql
-- Facet gate: intrinsic violation, fail-open, per-focus sender exception,
-- org-domain trust, and end-to-end gating through classify_thread_for_user.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(9);

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_user_c  uuid;                       -- user's own (linked) contact
    v_root    uuid := gen_random_uuid();  -- root priority
    v_focus   uuid := gen_random_uuid();  -- gated focus (excludes notification)
    v_trust   uuid := gen_random_uuid();  -- trustedSendersOnly focus
    v_a       uuid := gen_random_uuid();  -- author/sender contact (org domain)
    v_b       uuid := gen_random_uuid();  -- shared recipient contact
    v_moved   uuid := gen_random_uuid();  -- user_moved positive example in focus
    v_t_notif uuid := gen_random_uuid();  -- candidate: notification from A
    v_t_msg   uuid := gen_random_uuid();  -- candidate: message (not excluded)
    v_x       uuid := gen_random_uuid();  -- thread that makes A trusted-for-focus
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);

    -- A is in the same org domain as the user (acme.com, non-freemail). B is a
    -- neutral shared recipient.
    INSERT INTO contact (id, email, name) VALUES
        (v_a, 'sender@acme.com', 'A Sender'),
        (v_b, 'b@elsewhere.com', 'B Recipient');

    -- Root + a gated focus + a trust focus.
    INSERT INTO priority (id, created_by, user_id, title, path) VALUES
        (v_root, v_user, v_user, 'Root', 'root'::ltree),
        (v_focus, v_user, v_user, 'Reading', 'root.reading'::ltree),
        (v_trust, v_user, v_user, 'People', 'root.people'::ltree);
    UPDATE priority SET facet_filters = '{"format":{"exclude":["notification"]}}'::jsonb WHERE id = v_focus;
    UPDATE priority SET facet_filters = '{"trustedSendersOnly":true}'::jsonb WHERE id = v_trust;

    -- Positive scoring example: a user_moved thread in the focus sharing
    -- contact B with the candidates (gives a contacts-Jaccard score >= 0.15).
    -- It does NOT contain A, so it does not make A trusted-for-focus.
    INSERT INTO thread (id, created_by, title, contacts) VALUES
        (v_moved, v_user, 'Old reading', ARRAY[v_b]);
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
        VALUES (v_moved, v_user, v_focus, TRUE);

    -- Candidate threads: both share B (score the focus), topic NULL (reach
    -- scoring stage). author_id = A on the notification one.
    INSERT INTO thread (id, created_by, title, contacts, author_id, facets) VALUES
        (v_t_notif, v_user, 'New notif', ARRAY[v_b], v_a, '{"format":"notification"}'::jsonb),
        (v_t_msg,   v_user, 'New msg',   ARRAY[v_b], v_a, '{"format":"message"}'::jsonb);
END $$;

-- (1) intrinsic_facets_violate: notification excluded → violates.
SELECT ok(public.intrinsic_facets_violate('{"format":"notification"}'::jsonb,
                                          '{"format":{"exclude":["notification"]}}'::jsonb),
          'notification violates an exclude filter');

-- (2) fail-open: null facet value never violates an include filter.
SELECT ok(NOT public.intrinsic_facets_violate('{"format":null}'::jsonb,
                                              '{"format":{"include":["reading"]}}'::jsonb),
          'null facet value fails open against include');

-- (3) author_matches_org_domain: A (acme.com) matches the user's org domain.
SELECT ok((SELECT public.author_matches_org_domain(u, a)
           FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                (SELECT id a FROM contact WHERE email='sender@acme.com') aa),
          'org-domain match for same-domain non-freemail sender');

-- (4) is_trusted_for_focus: A is NOT yet trusted (no moved/created thread in
-- the focus contains A).
SELECT ok(NOT (SELECT public.is_trusted_for_focus(u, a, f)
               FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                    (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                    (SELECT id f FROM priority WHERE title='Reading') ff),
          'A not yet trusted for the focus');

-- (5) thread_facets_gated: notification from A is gated out of the focus.
SELECT ok((SELECT public.thread_facets_gated(u, '{"format":"notification"}'::jsonb, a, f)
           FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                (SELECT id f FROM priority WHERE title='Reading') ff),
          'notification gated out of the focus');

-- (6) end-to-end: classify the notification candidate → NOT the focus (gated).
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New notif'))),
    (SELECT id FROM priority WHERE title='Reading'),
    'gated notification does not classify into the focus');

-- (7) end-to-end: the non-excluded message candidate DOES classify into focus.
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New msg'))),
    (SELECT id FROM priority WHERE title='Reading'),
    'non-excluded message classifies into the focus');

-- (8) sender exception: move a thread authored by A into the focus, making A
-- trusted-for-focus. Now the notification candidate bypasses the gate.
DO $$
DECLARE v_x uuid := gen_random_uuid();
BEGIN
    INSERT INTO thread (id, created_by, title, contacts, author_id)
    VALUES (v_x, (SELECT id FROM "user" WHERE email='me@acme.com'), 'A thread',
            ARRAY[(SELECT id FROM contact WHERE email='sender@acme.com')],
            (SELECT id FROM contact WHERE email='sender@acme.com'));
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved)
    VALUES (v_x, (SELECT id FROM "user" WHERE email='me@acme.com'),
            (SELECT id FROM priority WHERE title='Reading'), TRUE);
END $$;

SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New notif'))),
    (SELECT id FROM priority WHERE title='Reading'),
    'sender exception: trusted-for-focus author bypasses the gate');

-- (9) trustedSendersOnly: thread_facets_gated admits A via org-domain even with
-- no per-focus history (the People focus has trustedSendersOnly + A is org).
SELECT ok(NOT (SELECT public.thread_facets_gated(u, '{"format":"message"}'::jsonb, a, t)
               FROM (SELECT id u FROM "user" WHERE email='me@acme.com') uu,
                    (SELECT id a FROM contact WHERE email='sender@acme.com') aa,
                    (SELECT id t FROM priority WHERE title='People') tt),
          'trustedSendersOnly admits an org-domain author');

SELECT finish();
ROLLBACK;
```

- [ ] **Step 4.2: Run the pgTAP suite**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/db run test:run`
Expected: `65-facet-gate.sql` reports `ok 1..9`, all passing, and the overall suite stays green. If assertion (7) fails because the contacts-Jaccard score is below 0.15, confirm both candidate and `v_moved` share exactly `{v_b}` (Jaccard = 1 → con = 0.35). If (6) returns the focus, confirm Task 3's gate predicate was applied and the migration ran.

- [ ] **Step 4.3: Commit**

```bash
git add libs/db/tests/65-facet-gate.sql
git commit -m "test(db): pgTAP for facet gate, trust, and sender exception"
```

---

## Task 5: Persist `priority.description` in `upsert_priority`

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`

- [ ] **Step 5.1: Persist description on INSERT**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, in the non-move `INSERT INTO priority (...)` (lines 567-572), add `description` to the column list and `p_priority ->> 'description'` to the VALUES. The INSERT becomes:

```sql
        INSERT INTO priority (id, user_id, archived_at, title, color, icon, path, created_by, updated_by, description)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.icon, _input.path, _input.created_by, _input.updated_by, p_priority ->> 'description')
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                icon = COALESCE(_input.icon, priority.icon),
                updated_by = _input.updated_by,
                -- Present-key semantics: only overwrite description when the
                -- caller actually sent it; preserve it otherwise. facet_filters
                -- is owned by the server-side derivation, never set here.
                description = CASE WHEN p_priority ? 'description'
                    THEN p_priority ->> 'description' ELSE priority.description END
            RETURNING
                id INTO _priority_id;
```

(The `_is_move` UPDATE branch is left unchanged — a move never carries a description.)

- [ ] **Step 5.2: Generate and apply**

```bash
cd /Users/kris.braun/code/plot
pnpm gen-migration -- persist_priority_description
pnpm apply-migrations
pnpm diff-schema-migrations   # expect no differences
```
Expected: migration `CREATE OR REPLACE`s `upsert_priority`; applies cleanly.

- [ ] **Step 5.3: Smoke-test**

Run:
```bash
psql "$DATABASE_URL" -tAc "
WITH u AS (INSERT INTO \"user\"(id,email) VALUES (gen_random_uuid(),'d@test.local') RETURNING id)
SELECT (SELECT description FROM \"user\".upsert_priority((SELECT id FROM u),
  jsonb_build_object('id', gen_random_uuid(), 'title','Reading','path','root.reading',
                     'created_by',(SELECT id FROM u),'description','newsletters and long reads')));" 2>&1 | tail -1
```
Expected: prints `newsletters and long reads`. (If the view's row type lacks `description`, the SELECT through `user.priority up` at the function end won't return it — that's fine; query the base table instead: `SELECT description FROM priority WHERE title='Reading' AND user_id=...`. The point is the column is populated.)

- [ ] **Step 5.4: Commit**

```bash
git add libs/db/schema/90-user-schema/85-user-sync-upserts.sql libs/db/migrations/
git commit -m "feat(db): persist priority.description in upsert_priority"
```

---

## Task 6: LLM filter-derivation module + registry

**Files:**
- Create: `workers/api/src/state/facet-registry.ts`
- Create: `workers/api/src/state/facet-registry.test.ts`
- Create: `workers/api/src/state/derive-facet-filters.ts`
- Create: `workers/api/src/state/derive-facet-filters.test.ts`

- [ ] **Step 6.1: Write the registry + schema test (failing)**

Create `workers/api/src/state/facet-registry.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { FACET_REGISTRY, FacetFiltersSchema, registryPromptBlock } from "./facet-registry";

describe("facet-registry", () => {
  it("lists every format/automation/reach value with a description", () => {
    expect(Object.keys(FACET_REGISTRY.format.values)).toContain("reading");
    expect(Object.keys(FACET_REGISTRY.format.values)).toContain("notification");
    for (const dim of ["format", "automation", "reach"] as const) {
      for (const desc of Object.values(FACET_REGISTRY[dim].values)) {
        expect(desc.length).toBeGreaterThan(0);
      }
    }
  });

  it("prompt block mentions every value", () => {
    const block = registryPromptBlock();
    for (const dim of ["format", "automation", "reach"] as const) {
      for (const value of Object.keys(FACET_REGISTRY[dim].values)) {
        expect(block).toContain(value);
      }
    }
  });

  it("schema accepts a valid filter object", () => {
    const parsed = FacetFiltersSchema.parse({
      format: { include: ["reading"], exclude: ["notification"] },
      trustedSendersOnly: true,
    });
    expect(parsed.format?.exclude).toEqual(["notification"]);
  });

  it("schema rejects an unknown format value", () => {
    expect(() => FacetFiltersSchema.parse({ format: { include: ["bogus"] } })).toThrow();
  });
});
```

- [ ] **Step 6.2: Run to verify it fails**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api test facet-registry`
Expected: FAIL — `./facet-registry` not found.

- [ ] **Step 6.3: Implement the registry**

Create `workers/api/src/state/facet-registry.ts`:

```typescript
import { z } from "zod";
import type { Automation, Format, Reach } from "@plotday/twister/facets";

// Single source of truth for the LLM derivation prompt. Mirrors the SDK facet
// vocabulary; the gate enforces the same values.
export const FACET_REGISTRY = {
  format: {
    description: "The kind of content.",
    values: {
      chat: "A short, conversational message (e.g. a quick chat).",
      message: "Substantive personal or business correspondence.",
      reading: "Long-form content meant to be read: newsletters, articles, digests.",
      notification: "A transactional or system notification (app alerts, 'X commented').",
      receipt: "A purchase, order, or payment confirmation.",
      invoice: "A bill, payment request, or statement.",
      promotion: "A marketing or promotional blast (sales, offers, deals).",
    } satisfies Record<Format, string>,
  },
  automation: {
    description: "Whether a person or a system produced the message.",
    values: {
      human: "Composed by a person.",
      automated: "Generated by a system, bot, or no-reply sender.",
    } satisfies Record<Automation, string>,
  },
  reach: {
    description: "How the user was addressed.",
    values: {
      direct: "Sent specifically to the user (and maybe a few others).",
      list: "A broadcast / mailing-list / bulk message.",
    } satisfies Record<Reach, string>,
  },
} as const;

const FORMAT_VALUES = Object.keys(FACET_REGISTRY.format.values) as [Format, ...Format[]];
const AUTOMATION_VALUES = Object.keys(FACET_REGISTRY.automation.values) as [Automation, ...Automation[]];
const REACH_VALUES = Object.keys(FACET_REGISTRY.reach.values) as [Reach, ...Reach[]];

function dimFilter<T extends string>(values: [T, ...T[]]) {
  return z
    .object({
      include: z.array(z.enum(values)).optional(),
      exclude: z.array(z.enum(values)).optional(),
    })
    .optional();
}

// The stored shape of priority.facet_filters and the LLM output contract.
export const FacetFiltersSchema = z.object({
  format: dimFilter(FORMAT_VALUES),
  automation: dimFilter(AUTOMATION_VALUES),
  reach: dimFilter(REACH_VALUES),
  trustedSendersOnly: z.boolean().optional(),
});

export type FacetFilters = z.infer<typeof FacetFiltersSchema>;

// Human-readable description of every dimension/value for the LLM prompt.
export function registryPromptBlock(): string {
  const lines: string[] = [];
  for (const dim of ["format", "automation", "reach"] as const) {
    lines.push(`${dim} — ${FACET_REGISTRY[dim].description}`);
    for (const [value, desc] of Object.entries(FACET_REGISTRY[dim].values)) {
      lines.push(`  - ${value}: ${desc}`);
    }
  }
  lines.push(
    "trustedSendersOnly — when true, only admit messages from senders the user already engages with (people they've messaged or whose threads they've filed here) or colleagues in their own email domain."
  );
  return lines.join("\n");
}
```

- [ ] **Step 6.4: Run to verify it passes**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api test facet-registry`
Expected: PASS.

- [ ] **Step 6.5: Implement the derivation module**

Create `workers/api/src/state/derive-facet-filters.ts`:

```typescript
import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { FacetFiltersSchema, registryPromptBlock, type FacetFilters } from "./facet-registry";

const SYSTEM_PROMPT = `You configure classification filters for a "focus" — a project or area-of-life a user gathers related items under.

Given the focus's title and description, decide which message FACETS belong in it. Output include/exclude sets per dimension and an optional trustedSendersOnly flag, using ONLY the documented values.

Be conservative: constrain a dimension ONLY when the focus clearly implies it. Leave a dimension out entirely when unsure — an absent dimension means "no filtering on that axis". It is far better to under-filter than to wrongly exclude wanted items.

Facets:
${registryPromptBlock()}

Examples:
- "Reading — newsletters and long reads" → { "format": { "include": ["reading"] }, "exclude unrelated kinds": prefer also excluding notification/promotion/receipt/invoice }
- "Receipts & invoices" → { "format": { "include": ["receipt","invoice"] } }
- "Important people" → { "trustedSendersOnly": true, "automation": { "exclude": ["automated"] } }
- "Work" (generic) → {} (no clear facet implication)`;

/**
 * Derive facet filters for a focus from its title + description. Returns the
 * validated filters, or null when the LLM is unavailable/failed (fail-open:
 * the focus then classifies with no facet gate).
 */
export async function deriveFacetFilters(
  env: Bindings,
  title: string,
  description: string | null
): Promise<FacetFilters | null> {
  const logger = createLogger({ component: "derive-facet-filters" });
  if (!env.AI_GATEWAY_ACCOUNT_ID || !env.AI_GATEWAY_ID || !env.AI_GATEWAY_TOKEN) {
    return null;
  }

  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const anthropic = createAnthropic({
    baseURL: `${gatewayBaseUrl}/anthropic`,
    apiKey: env.ANTHROPIC_API_KEY,
    headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
  });
  const model: any = anthropic("claude-sonnet-4-6");

  const userPrompt = `Focus title: ${JSON.stringify(title || "(untitled)")}
Focus description: ${JSON.stringify(description ?? "")}

Return the facet filters for this focus.`;

  try {
    const result = await generateObject({
      model,
      schema: FacetFiltersSchema,
      schemaName: "FacetFilters",
      schemaDescription:
        "Per-dimension include/exclude sets (format/automation/reach) plus an optional trustedSendersOnly boolean.",
      maxOutputTokens: 1_000,
      messages: [
        {
          role: "system",
          content: SYSTEM_PROMPT,
          providerOptions: { anthropic: { cacheControl: { type: "ephemeral" } } },
        },
        { role: "user", content: userPrompt },
      ],
    });
    return result.object;
  } catch (error) {
    logger.warn("facet-filter derivation failed", { error: (error as Error).message });
    return null;
  }
}
```

- [ ] **Step 6.6: Write a derivation smoke test (no live LLM)**

Create `workers/api/src/state/derive-facet-filters.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { deriveFacetFilters } from "./derive-facet-filters";
import type { Bindings } from "../env";

describe("deriveFacetFilters", () => {
  it("returns null (fail-open) when the AI gateway is not configured", async () => {
    const env = {
      AI_GATEWAY_ACCOUNT_ID: "",
      AI_GATEWAY_ID: "",
      AI_GATEWAY_TOKEN: "",
      ANTHROPIC_API_KEY: "",
    } as unknown as Bindings;
    expect(await deriveFacetFilters(env, "Reading", "newsletters")).toBeNull();
  });
});
```

- [ ] **Step 6.7: Run derivation + registry tests, type-check**

```bash
cd /Users/kris.braun/code/plot
pnpm --filter @plotday/api test facet-registry derive-facet-filters
pnpm --filter @plotday/api lint
```
Expected: tests PASS; lint PASS.

- [ ] **Step 6.8: Commit**

```bash
git add workers/api/src/state/facet-registry.ts workers/api/src/state/facet-registry.test.ts workers/api/src/state/derive-facet-filters.ts workers/api/src/state/derive-facet-filters.test.ts
git commit -m "feat(api): facet registry + LLM facet-filter derivation"
```

---

## Task 7: Trigger derivation on focus create/update; filter the preview

**Files:**
- Modify: `workers/api/src/app/sync/priorities.ts`
- Modify: `workers/api/src/app/sync/priority-match.ts`

- [ ] **Step 7.1: Derive filters in a background task on `/sync/priorities`**

In `workers/api/src/app/sync/priorities.ts`, the POST handler currently upserts then does `notifySync` + a `waitUntil(enqueueChannelRouter(...))`. Add a second background task that derives and persists `facet_filters` from the focus's title + description. Snapshot the needed values before `waitUntil`, open a fresh DB connection inside it (per the project's `waitUntil` rule), and report failures to PostHog.

Add these imports at the top (with the existing imports):

```typescript
import { createDb } from "../../db";
import { deriveFacetFilters } from "../../state/derive-facet-filters";
```

After the existing `notifySync(c, body.id)` / channel-router `waitUntil` block, add:

```typescript
  // Derive facet filters for the focus from its title + description (LLM, in
  // the background so it never blocks the upsert). Skip archived focuses.
  const title = typeof body.title === "string" ? body.title.trim() : "";
  const priorityId = typeof body.id === "string" ? body.id : null;
  const description = typeof body.description === "string" ? body.description : null;
  const isArchived = body.archived_at != null;
  if (priorityId && title && !isArchived) {
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(c.env);
        try {
          const filters = await deriveFacetFilters(c.env, title, description);
          if (filters !== null) {
            await db
              .updateTable("priority")
              .set({ facet_filters: filters as any })
              .where("id", "=", priorityId)
              .where("user_id", "=", userId)
              .execute();
          }
        } catch (error) {
          c.var.tracker.captureException(error as Error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }
```

(Confirm `createDb` is exported from `workers/api/src/db.ts` — it is the canonical fresh-connection factory referenced in the project's `waitUntil` guidance. If the symbol differs, use whatever `workers/api/src/app/sync/links.ts` imports for its `waitUntil` connection.)

- [ ] **Step 7.2: Type-check the priorities handler**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api lint`
Expected: PASS. (`priority.facet_filters` is in generated types from Task 1; `deriveFacetFilters` from Task 6.)

- [ ] **Step 7.3: Filter the find-matching-threads preview by intrinsic facets**

In `workers/api/src/app/sync/priority-match.ts`, make the preview respect the same intrinsic facet filters the focus will use. After the request body is parsed and before the candidate queries, derive filters once; then inject the SQL predicate `public.intrinsic_facets_violate(t.facets, <filters>)` into both candidate queries.

Add the import:

```typescript
import { deriveFacetFilters } from "../../state/derive-facet-filters";
```

After `const exclude = ...` (the body parsing, ~line 102), add:

```typescript
  // Derive the focus's intrinsic facet filters so the preview drops items the
  // focus will gate (e.g. notifications out of a Reading focus). Best-effort:
  // null filters → no extra filtering. The per-focus trust filter is omitted
  // here (the focus has no filed threads yet at preview time).
  const derived = await deriveFacetFilters(c.env, title, description);
  const facetFilterJson = derived ? JSON.stringify(derived) : null;
```

Then in the `visible` SQL predicate (the shared `sql\`...\`` block), append a facet clause at the end:

```typescript
        ${facetFilterJson ? sql`AND NOT public.intrinsic_facets_violate(t.facets, ${facetFilterJson}::jsonb)` : sql``}`;
```

(Place it inside the existing `visible` template literal, right before its closing backtick, so both the vector and lexical candidate queries inherit it.)

- [ ] **Step 7.4: Type-check**

Run: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api lint`
Expected: PASS.

- [ ] **Step 7.5: Commit**

```bash
git add workers/api/src/app/sync/priorities.ts workers/api/src/app/sync/priority-match.ts
git commit -m "feat(api): derive facet filters on focus upsert; filter match preview"
```

---

## Task 8 (OPTIONAL — your decision): client sends `description`

The server now persists `description` **only when the client includes it** in the `/sync/priorities` body. The focus-creation form already has the description text (it sends it to `find-matching-threads`); including it in the priority upsert payload is a small, non-UI serialization change in the Flutter client.

**Decide:** include this, or accept title-only filter derivation (description stays null) for now.

If including it:
- [ ] **Step 8.1:** In the Flutter `Priority`/focus sync serialization (the `toBase`/`toJson` that builds the `/sync/priorities` body), add the `description` field, sourced from the creation form. Do NOT add it to any read/UI path — it is write-only plumbing. (Follow the same conditional-send pattern used for other optional priority fields, e.g. send only when non-null.)
- [ ] **Step 8.2:** `cd apps/plot && flutter analyze` → 0 new issues. Do NOT run `dart format`.
- [ ] **Step 8.3:** Commit: `git add apps/plot && git commit -m "feat(app): send focus description in priority sync payload"`

If skipping: filters derive from the title alone — still effective for clearly-named focuses ("Reading", "Receipts").

---

## Task 9: Finalize

- [ ] **Step 9.1: Full lint + tests**

```bash
cd /Users/kris.braun/code/plot
pnpm --filter @plotday/db run lint        # type-freshness (db:lint)
pnpm --filter @plotday/db run test:run    # pgTAP incl. 65-facet-gate
pnpm --filter @plotday/api lint
pnpm --filter @plotday/api test
```
Expected: all PASS. `pnpm diff-schema-migrations` → no differences.

- [ ] **Step 9.2: User-facing changelog**

In `docs/updates.md`, add a bullet to the top section:

```markdown
- Focuses now sort messages by what kind they are and who they're from — newsletters and notifications no longer mix, and important people stay separate from cold outreach.
```

- [ ] **Step 9.3: features.md note**

In `docs/features.md`, under the classification/focus section, add a brief line noting focuses classify by message format and sender relationship (facets), not only content.

- [ ] **Step 9.4: Verify backward compatibility & error capture**

- All new columns nullable; no view changed → no client impact, old clients unaffected.
- New catch blocks (`derive-facet-filters.ts` logs+returns null; `priorities.ts` waitUntil calls `c.var.tracker.captureException`). Confirm with: `rg -n "captureException" workers/api/src/app/sync/priorities.ts`.
- Gate fail-open verified by pgTAP assertion (2).

- [ ] **Step 9.5: Commit docs**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: facet-based focus classification"
```

- [ ] **Step 9.6: Push and open the PR**

```bash
git push -u origin facet-classifier-integration
gh pr create --title "feat: facet-based focus classification (gate + trust + LLM filters)" \
  --body "Adds priority.facet_filters/description + freemail_domain, a scoring-stage facet gate with per-focus trusted-sender exception and live org-domain trust, LLM filter derivation on focus create/update, and preview filtering in find-matching-threads. Depends on the facet-extraction foundation (Plan 1). 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review (completed by plan author)

**Spec coverage (design spec § → task):**
- §4 `priority.facet_filters` + `priority.description` + `freemail_domain` → Task 1.
- §6 intrinsic gate / fail-open → Task 2 (`intrinsic_facets_violate`) + Task 3.
- §6 per-focus trusted-sender predicate (user_moved OR created_by) → Task 2 (`is_trusted_for_focus`).
- §6 org-domain match, freemail-excluded → Task 2 (`author_matches_org_domain`).
- §6 combined gate (exception + trustedSendersOnly) → Task 2 (`thread_facets_gated`).
- §6 scoring-stage-only wiring; all-gated → root → Task 3 + pgTAP (6).
- §6 performance (indexed predicates) → uses existing `idx_thread_priority_priority_id`/`user_moved`, `idx_thread_contacts`.
- §7 registry + Claude derivation, conservative, fail-open → Task 6.
- §7 derive on create/update via `waitUntil` → Task 7.1.
- §6 find-matching-threads filtering → Task 7.3.
- §4/§7 persist description (the oversight) → Task 5 + Task 8 (client send).
- §8 testing (pgTAP + TS) → Task 4, Task 6 tests.
- §8 going-forward only (no backfill) → no backfill task exists (correct).
- §12 finalize (lint, db:lint, updates.md, captureException) → Task 9.

**Placeholder scan:** none — every code step has complete code; commands have expected output. Two explicitly-flagged confirmations (`createDb` import name in 7.1; the Flutter serialization site in 8.1) point at concrete reference files to resolve, not vague TODOs.

**Type consistency:** `FacetFilters`/`FacetFiltersSchema`/`registryPromptBlock` defined in Task 6 and consumed in Task 7. `Format`/`Automation`/`Reach` imported from `@plotday/twister/facets` (Plan 1). SQL helpers named in Task 2 are called verbatim in Task 3 (`thread_facets_gated`), Task 7.3 (`intrinsic_facets_violate`), and asserted in Task 4. `priority.facet_filters`/`description` columns (Task 1) read by Task 3/5/7 and the pgTAP seeds.

**Known approximations (by design):** preview filtering applies only intrinsic facets, not the per-focus trust filter (no filed threads exist at preview time) — noted in 7.3. Scoring gate operates within the existing top-3 scored set; a focus ranked outside the top 3 is not reconsidered after gating (pre-existing top-3 behavior).
```
