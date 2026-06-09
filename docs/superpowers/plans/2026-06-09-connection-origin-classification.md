# Connection-origin Classification Signal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the thread classifier use the originating connection (work email vs personal email vs work chat) as a learned scoring signal, so receipts and everything else route to the focus that has seen that account before — with zero new UI and no schema column.

**Architecture:** Pure database change. A new live `connection_org_key(twist_instance_id)` SQL helper resolves a connection to a coarse org group (non-freemail account-email domain, else owning team, else NULL) by following `twist_instance → twist_instance_connection.actor_id → contact.email`. The scoring stage of `classify_thread_for_user_explain` gains a per-pair **origin** term (exact-connection > same-org > none) layered into the existing combined score. The signal is learned entirely from `user_moved` examples (seeded at focus creation by the existing `/sync/priority-moves` calls), so it self-corrects from reclassifications and never hard-gates. Going-forward only, no backfill.

**Tech Stack:** PostgreSQL (plpgsql + SQL functions), Atlas migrations, pgTAP (`pg_prove`).

**Spec:** `docs/superpowers/specs/2026-06-09-connection-origin-classification-design.md`

---

## Context the engineer needs

- **Connector-thread discriminator:** a thread was created by a connection (not a user) **iff `thread.twist_id IS NOT NULL`**; in that case `thread.created_by` is the `twist_instance.id` (the connection). This is the canonical pattern (see `libs/db/schema/90-user-schema/31-schedule.sql:70-73`).
- **Account email path:** `twist_instance_connection` has PK `(twist_instance_id, user_id, provider)` and an `actor_id uuid` (no FK, but for the owner's own email connection it is the `contact.id` whose `email` is the connected account's address). The connection's owner is `twist_instance.owner_id`.
- **`public.domain`** (`libs/db/schema/50-tables/11-domain.sql`) has `name text` (lowercased, unique) and `freemail boolean`. Seeded with ~102 freemail providers. A domain that is org-owned generally is NOT in this table — so "personal" means *the domain has a row with `freemail = true`*, and everything else (resolvable domain, not known-freemail) is treated as an org.
- **`twist_instance.team_id bigint`** is NULL for personal connections, non-NULL for team-owned (`libs/db/schema/50-tables/95-twist_instance.sql:8`).
- **Function directory rule:** functions referencing tables live in `60-functions/` (loaded after `50-tables/`). `classify_thread_for_user.sql` is already there. `connection_org_key` (SQL-language, references tables) also goes there. `classify_thread_for_user_explain` is plpgsql, so it resolves `connection_org_key` at run time — file ordering between the two does not matter.
- **DB workflow:** edit schema files → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` (auto-runs `pnpm types`) → `pnpm diff-schema-migrations` (must be clean) → commit `libs/db/src/types.ts`. Use `$DATABASE_URL`; verify port with `psql "$DATABASE_URL" -tAc "show port;"` (54322 in main repo). Run pgTAP with `pg_prove -d "$DATABASE_URL" libs/db/tests/<file>.sql`.
- **DB must be up:** `pnpm --filter @plotday/db start` if `psql "$DATABASE_URL" -c '\q'` fails.

## File structure

| File | Responsibility | Action |
| --- | --- | --- |
| `libs/db/schema/60-functions/connection_org_key.sql` | Resolve a connection to a coarse org-group key, live | Create |
| `libs/db/schema/60-functions/classify_thread_for_user.sql` | Add origin term to the scoring stage; rebalance weights | Modify |
| `libs/db/tests/66-connection-org-key.sql` | pgTAP for `connection_org_key` resolution | Create |
| `libs/db/tests/67-connection-origin-routing.sql` | pgTAP for end-to-end origin-driven routing | Create |
| `libs/db/migrations/<ts>_add_connection_origin_signal.sql` | Generated migration | Generate |
| `libs/db/src/types.ts` | Regenerated types | Regenerate |
| `docs/updates.md` | One user-facing bullet | Modify |

---

## Task 1: `connection_org_key` helper + resolution tests

**Files:**
- Create: `libs/db/schema/60-functions/connection_org_key.sql`
- Create: `libs/db/tests/66-connection-org-key.sql`

- [ ] **Step 1: Confirm the DB is reachable and on the expected port**

Run:
```bash
psql "$DATABASE_URL" -tAc "show port;"
```
Expected: `54322` (main repo). If it errors, run `pnpm --filter @plotday/db start` and retry.

- [ ] **Step 2: Write the failing pgTAP test for `connection_org_key`**

Create `libs/db/tests/66-connection-org-key.sql`:

```sql
-- connection_org_key: resolve a connection (twist_instance) to a coarse org
-- group key. Non-freemail account-email domain -> 'domain:<d>'; else owning
-- team -> 'team:<id>'; else (personal freemail, no team) -> NULL.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_user_c  uuid;
    v_team    bigint;
    v_gmail   bigint;   -- twist definition id (acts as a connector)
    v_slack   bigint;
    v_c_pers  uuid := gen_random_uuid();   -- personal gmail account contact
    v_ti_work_gmail uuid := gen_random_uuid();
    v_ti_work_slack uuid := gen_random_uuid();
    v_ti_personal   uuid := gen_random_uuid();
    v_ti_team       uuid := gen_random_uuid();
BEGIN
    -- User + the user's own contact carrying their work email.
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);

    -- A personal (freemail) account contact linked to the same user.
    INSERT INTO contact (id, email, name, user_id)
        VALUES (v_c_pers, 'me@gmail.com', 'Me Personal', v_user);

    -- A team to exercise the team_id fallback.
    INSERT INTO team (name) VALUES ('Acme') RETURNING id INTO v_team;

    -- Two twist definitions to act as connectors. twist has NOT NULL
    -- twist_package_id / name / handle / version, and a twist_owner_check
    -- constraint satisfied here by setting user_id.
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Gmail', 'gmail', '1.0')
        RETURNING id INTO v_gmail;
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Slack', 'slack', '1.0')
        RETURNING id INTO v_slack;

    -- Connections (twist_instances). owner_id must be set (trigger enforced).
    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES
        (v_ti_work_gmail, v_gmail, v_user, 'Gmail'),
        (v_ti_work_slack, v_slack, v_user, 'Slack'),
        (v_ti_personal,   v_gmail, v_user, 'Gmail (personal)');
    INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id) VALUES
        (v_ti_team, v_slack, v_user, 'Team Slack', v_team);

    -- Connection rows linking each twist_instance to the owner's account contact.
    -- Work gmail + work slack both resolve to the work email (acme.com).
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_work_gmail, v_user, 'gmail', v_user_c),
        (v_ti_work_slack, v_user, 'slack', v_user_c),
        (v_ti_personal,   v_user, 'gmail', v_c_pers);
    -- The team connection has no resolvable email contact (synthetic actor),
    -- so it should fall back to team_id.
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_team, v_user, 'slack', gen_random_uuid());
END $$;

-- (1) Work Gmail -> org domain acme.com (acme.com is not a known freemail).
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Gmail')),
    'domain:acme.com',
    'work gmail resolves to its non-freemail account domain');

-- (2) Work Slack -> SAME org key (same account email domain) -> transfer.
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Slack' AND team_id IS NULL)),
    'domain:acme.com',
    'work slack resolves to the same org domain as work gmail');

-- (3) Personal Gmail (freemail) -> NULL (no merge across personal accounts).
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Gmail (personal)')),
    NULL,
    'personal freemail connection has no org key');

-- (4) Team connection with no resolvable email -> team fallback.
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Team Slack')),
    'team:' || (SELECT id FROM team WHERE name='Acme')::text,
    'team-owned connection without an account email falls back to team_id');

-- (5) NULL / unknown twist_instance -> NULL (null-safe).
SELECT is(
    public.connection_org_key(NULL),
    NULL,
    'null connection id resolves to null');

SELECT finish();
ROLLBACK;
```

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
pg_prove -d "$DATABASE_URL" libs/db/tests/66-connection-org-key.sql
```
Expected: FAIL — `function public.connection_org_key(...) does not exist` (or the whole file errors). If instead the `team`/`twist` INSERTs error on a NOT-NULL/constraint you didn't anticipate, inspect with `psql "$DATABASE_URL" -c "\d+ twist"` / `"\d+ team"` and adjust the seed columns, then re-run until the only failure is the missing function.

- [ ] **Step 4: Create the `connection_org_key` function**

Create `libs/db/schema/60-functions/connection_org_key.sql`:

```sql
-- Resolve a connection (twist_instance) to a coarse "org group" key used by the
-- classifier's origin signal so a user's work connections merge while unrelated
-- personal accounts do not. Evaluated LIVE (no stored column):
--   1. the connection owner's account-email domain, when that domain is NOT a
--      known freemail provider                                 -> 'domain:<d>'
--   2. else the owning team                                    -> 'team:<id>'
--   3. else (personal freemail account, or unresolvable)       -> NULL
--
-- The account email comes from twist_instance_connection.actor_id -> contact
-- for the owner's own connection. A domain counts as "freemail" only if it has
-- a public.domain row with freemail = true; any other resolvable domain is
-- treated as an org domain (org domains are usually absent from public.domain).
CREATE OR REPLACE FUNCTION public.connection_org_key (p_twist_instance_id uuid)
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT CASE
        WHEN acct.domain IS NOT NULL
             AND acct.domain <> ''
             AND NOT EXISTS (
                 SELECT 1 FROM public.domain d
                 WHERE d.name = acct.domain AND d.freemail
             )
            THEN 'domain:' || acct.domain
        WHEN ti.team_id IS NOT NULL
            THEN 'team:' || ti.team_id::text
        ELSE NULL
    END
    FROM public.twist_instance ti
    LEFT JOIN LATERAL (
        SELECT lower(split_part(c.email, '@', 2)) AS domain
        FROM public.twist_instance_connection tic
        JOIN public.contact c ON c.id = tic.actor_id
        WHERE tic.twist_instance_id = ti.id
          AND tic.user_id = ti.owner_id
          AND c.email IS NOT NULL
          AND position('@' IN c.email) > 0
        ORDER BY tic.connected_at ASC
        LIMIT 1
    ) acct ON TRUE
    WHERE ti.id = p_twist_instance_id;
$function$;

COMMENT ON FUNCTION public.connection_org_key IS 'Coarse org-group key for a connection (twist_instance): non-freemail account-email domain -> domain:<d>, else owning team -> team:<id>, else NULL. Used by classify_thread_for_user_explain as the L2 origin signal.';
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
pg_prove -d "$DATABASE_URL" libs/db/tests/66-connection-org-key.sql
```
Expected: PASS — `ok 1..5`, `Result: PASS`.

Note: the function only exists in the schema file so far; `connection_org_key` is created in the test session via... no — pgTAP runs against the live DB, so the function must be applied first. Apply the schema by generating+applying the migration is done in Task 3; for a fast local test loop, load the function directly now:
```bash
psql "$DATABASE_URL" -f libs/db/schema/60-functions/connection_org_key.sql
```
Then re-run the `pg_prove` command above. (The committed migration in Task 3 is what makes it durable; this direct load is only to exercise the test in isolation.)

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/60-functions/connection_org_key.sql libs/db/tests/66-connection-org-key.sql
git commit -m "feat(db): add connection_org_key helper for origin classification"
```

---

## Task 2: Add the origin term to the classifier scoring stage

**Files:**
- Modify: `libs/db/schema/60-functions/classify_thread_for_user.sql` (the `classify_thread_for_user_explain` function only; the thin `classify_thread_for_user` wrapper is unchanged)
- Create: `libs/db/tests/67-connection-origin-routing.sql`

- [ ] **Step 1: Write the failing routing test**

Create `libs/db/tests/67-connection-origin-routing.sql`:

```sql
-- End-to-end: the originating connection breaks ties between focuses with equal
-- content signal. Exact-connection match (L1) and same-org match (L2) both
-- boost; origin never hard-gates (cross-categorization stays routable).
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

-- Helper to read a focus id by title for a given user email.
-- (Inlined as subqueries below; pgTAP has no local function sugar.)

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_user_c uuid;
    v_root   uuid;
    v_rootp  ltree;
    v_gmail  bigint;
    v_slack  bigint;
    v_c_pers uuid := gen_random_uuid();
    v_vendor uuid := gen_random_uuid();   -- shared "sender" contact = baseline con signal
    v_ti_work_gmail uuid := gen_random_uuid();
    v_ti_work_slack uuid := gen_random_uuid();
    v_ti_personal   uuid := gen_random_uuid();
    v_acme   uuid := gen_random_uuid();    -- "Acme admin" focus
    v_fin    uuid := gen_random_uuid();    -- "Personal finance" focus
    v_m_work uuid := gen_random_uuid();    -- moved example in Acme, from work gmail
    v_m_pers uuid := gen_random_uuid();    -- moved example in Finance, from personal gmail
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);
    INSERT INTO contact (id, email, name, user_id) VALUES (v_c_pers, 'me@gmail.com', 'Me Personal', v_user);
    INSERT INTO contact (id, email, name) VALUES (v_vendor, 'receipts@shop.com', 'Shop');

    SELECT id, path INTO v_root, v_rootp FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Gmail', 'gmail', '1.0') RETURNING id INTO v_gmail;
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Slack', 'slack', '1.0') RETURNING id INTO v_slack;

    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES
        (v_ti_work_gmail, v_gmail, v_user, 'Gmail'),
        (v_ti_work_slack, v_slack, v_user, 'Slack'),
        (v_ti_personal,   v_gmail, v_user, 'Gmail (personal)');
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_work_gmail, v_user, 'gmail', v_user_c),
        (v_ti_work_slack, v_user, 'slack', v_user_c),
        (v_ti_personal,   v_user, 'gmail', v_c_pers);

    INSERT INTO priority (id, created_by, user_id, title, path) VALUES
        (v_acme, v_user, v_user, 'Acme admin',       v_rootp || 'acme'),
        (v_fin,  v_user, v_user, 'Personal finance', v_rootp || 'finance');

    -- One moved example per focus. Both share the SAME contact (vendor) so the
    -- content (con) signal is identical for both focuses; only the originating
    -- connection differs. Connector threads: created_by = twist_instance,
    -- twist_id set.
    INSERT INTO thread (id, created_by, twist_id, title, contacts) VALUES
        (v_m_work, v_ti_work_gmail, v_gmail, 'Old work receipt',     ARRAY[v_vendor]),
        (v_m_pers, v_ti_personal,   v_gmail, 'Old personal receipt', ARRAY[v_vendor]);
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved) VALUES
        (v_m_work, v_user, v_acme, TRUE),
        (v_m_pers, v_user, v_fin,  TRUE);
END $$;

-- (1) A work-Gmail receipt routes to Acme admin (exact-connection L1 beats the
--     equally content-matched Personal finance).
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_g bigint := (SELECT id FROM twist WHERE handle='gmail' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Gmail' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_g, 'New work receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New work receipt'))),
    (SELECT id FROM priority WHERE title='Acme admin'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'work-gmail receipt routes to the work focus via exact-connection match');

-- (2) A personal-Gmail receipt routes to Personal finance (symmetric).
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_g bigint := (SELECT id FROM twist WHERE handle='gmail' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Gmail (personal)' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_g, 'New personal receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New personal receipt'))),
    (SELECT id FROM priority WHERE title='Personal finance'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'personal-gmail receipt routes to the finance focus via exact-connection match');

-- (3) Org-group transfer (L2): a work-SLACK candidate routes to Acme admin even
--     though Acme has only a work-GMAIL example — same org domain (acme.com),
--     different connection. Beats the personal-gmail-matched finance focus.
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_s bigint := (SELECT id FROM twist WHERE handle='slack' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Slack' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_s, 'Work slack receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='Work slack receipt'))),
    (SELECT id FROM priority WHERE title='Acme admin'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'work-slack receipt transfers to the work focus via same-org (domain) match');

-- (4) Soft, not a gate: with ONLY the finance focus seeded (drop the acme
--     example for this candidate by using a fresh user is overkill) — instead
--     assert a work-gmail candidate still classifies into SOME focus (origin
--     mismatch never produces a null/blocked classification). Re-uses test (1)
--     world; a work-gmail receipt is not gated out of finance, it simply scores
--     lower there. We assert it returns a non-null focus.
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New work receipt'))),
    NULL,
    'origin is soft: a classified thread always lands somewhere, never blocked');

-- (5) User-authored candidate (twist_id NULL) carries no origin signal and must
--     still classify by content without error.
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, title, contacts)
        VALUES (v_cand, v_u, 'Hand-written note about shop', ARRAY[v_vendor]);
END $$;
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='Hand-written note about shop'))),
    NULL,
    'user-authored candidate classifies by content with no origin signal');

SELECT finish();
ROLLBACK;
```

- [ ] **Step 2: Run the test to verify it fails**

First load the current schema function so the test runs against today's behavior:
```bash
psql "$DATABASE_URL" -f libs/db/schema/60-functions/connection_org_key.sql
pg_prove -d "$DATABASE_URL" libs/db/tests/67-connection-origin-routing.sql
```
Expected: tests (1)–(3) FAIL (without the origin term, Acme admin and Personal finance tie on `con`; the tie breaks on `MAX(updated_at)`/row order, not origin, so routing is not reliably the work/finance focus). Tests (4)–(5) likely already pass. The point is (1)–(3) must fail before the implementation.

- [ ] **Step 3: Implement the origin term in `classify_thread_for_user_explain`**

Open `libs/db/schema/60-functions/classify_thread_for_user.sql`. Replace the entire `CREATE OR REPLACE FUNCTION public.classify_thread_for_user_explain (...) ... $function$;` definition (the verbose function; keep the leading comment block and the thin wrapper below it unchanged) with this version. Changes vs. current: four new declared vars; load `created_by`/`twist_id`; compute candidate connection + org key; `moved` CTE carries `conn_id`; new `conn_key` CTE; `scored` adds the `origin` term and joins `conn_key`; `combined` rebalanced to `0.50·sem + 0.30·con + 0.12·grp + origin − 0.30·neg` in all three places; `origin` surfaced in the `_explain` jsonb.

```sql
CREATE OR REPLACE FUNCTION public.classify_thread_for_user_explain (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL,
    p_contacts uuid[] DEFAULT NULL,
    p_groups uuid[] DEFAULT NULL
)
    RETURNS TABLE (priority_id uuid, stage text, scores jsonb)
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_facets jsonb;
    v_author_id uuid;
    v_created_by uuid;
    v_twist_id bigint;
    v_conn_id uuid;       -- candidate's originating connection (twist_instance) or NULL
    v_org_key text;       -- candidate connection's coarse org-group key or NULL
    v_matched uuid;
    v_scores jsonb;
    v_channel_pk bigint;
    v_priority_key text;
BEGIN
    -- 1. Load the thread's signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups, t.facets, t.author_id,
               t.created_by, t.twist_id
        INTO v_embedding, v_topic, v_contacts, v_groups, v_facets, v_author_id,
             v_created_by, v_twist_id
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- Origin signal: a connector thread (twist_id IS NOT NULL) was created by a
    -- connection; created_by is that twist_instance. User-authored threads have
    -- no origin signal. Resolve the candidate's coarse org-group key once.
    v_conn_id := CASE WHEN v_twist_id IS NOT NULL THEN v_created_by ELSE NULL END;
    v_org_key := public.connection_org_key(v_conn_id);

    -- 2. Topic short-circuit on user_moved siblings.
    IF v_topic IS NOT NULL THEN
        SELECT tp.priority_id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND mt.topic = v_topic
        GROUP BY tp.priority_id
        ORDER BY COUNT(*) DESC, MAX(tp.updated_at) DESC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            RETURN QUERY SELECT v_matched,
                                'topic_shortcircuit'::text,
                                jsonb_build_object('topic', v_topic);
            RETURN;
        END IF;
    END IF;

    -- 2.3. Cross-user keyed priority match.
    IF p_thread_id IS NOT NULL THEN
        SELECT p.id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.priority src ON src.id = tp.priority_id
        JOIN public.priority p
          ON p.user_id = p_user_id
         AND p.key = src.key
         AND p.archived_at IS NULL
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id <> p_user_id
          AND src.key IS NOT NULL
          AND src.archived_at IS NULL
        ORDER BY tp.created_at ASC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            SELECT jsonb_build_object('key', p.key)
            INTO v_scores
            FROM public.priority p
            WHERE p.id = v_matched;
            RETURN QUERY SELECT v_matched,
                                'keyed_priority'::text,
                                COALESCE(v_scores, '{}'::jsonb);
            RETURN;
        END IF;
    END IF;

    -- 2.5. Channel default.
    IF v_topic LIKE 'channel:%' THEN
        BEGIN
            v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
            IF v_channel_pk IS NOT NULL THEN
                SELECT c.default_priority_id INTO v_matched
                FROM public.channel c
                JOIN public.priority p ON p.id = c.default_priority_id
                WHERE c.id = v_channel_pk
                  AND c.default_priority_id IS NOT NULL
                  AND p.user_id = p_user_id
                  AND p.archived_at IS NULL;
                IF v_matched IS NOT NULL THEN
                    RETURN QUERY SELECT v_matched,
                                        'channel_default'::text,
                                        jsonb_build_object('channel_id', v_channel_pk);
                    RETURN;
                END IF;
            END IF;
        EXCEPTION WHEN invalid_text_representation THEN
            NULL;
        END;
    END IF;

    -- 3. Score all moved threads when no topic match was available.
    --    Adds an origin term: a user_moved example from the SAME connection
    --    (exact, L1) or the same org group (L2) boosts the focus that has
    --    already seen this mailbox/account. origin rides inside the combined
    --    score — it does not bypass the facet gate or the structural stages.
    WITH moved AS (
        SELECT tp.priority_id,
               tp.thread_id,
               mt.embedding,
               mt.contacts,
               mt.groups,
               CASE WHEN mt.twist_id IS NOT NULL THEN mt.created_by END AS conn_id
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    -- Resolve each distinct example connection to its org key once (avoids a
    -- per-pair function call in the cross join below).
    conn_key AS (
        SELECT m.conn_id, public.connection_org_key(m.conn_id) AS org_key
        FROM (SELECT DISTINCT conn_id FROM moved WHERE conn_id IS NOT NULL) m
    ),
    candidate AS (
        SELECT public.expand_contacts(v_contacts) AS exp_contacts,
               v_groups AS groups,
               v_embedding AS embedding
    ),
    neg AS (
        SELECT n.priority_id,
               MAX(GREATEST(0, 1 - (nt.embedding <=> v_embedding))) AS neg_sim
        FROM public.thread_priority_negative n
        JOIN public.thread nt ON nt.id = n.thread_id
        WHERE n.user_id = p_user_id
          AND nt.archived_at IS NULL
          AND nt.embedding IS NOT NULL
          AND v_embedding IS NOT NULL
        GROUP BY n.priority_id
    ),
    scored AS (
        SELECT
            f.priority_id,
            f.thread_id,
            COALESCE(ng.neg_sim, 0) AS neg_sim,
            CASE
                WHEN v_conn_id IS NOT NULL AND f.conn_id = v_conn_id THEN 0.18
                WHEN v_org_key IS NOT NULL AND ck.org_key = v_org_key THEN 0.09
                ELSE 0
            END AS origin,
            CASE
                WHEN f.embedding IS NULL OR c.embedding IS NULL THEN 0
                ELSE POWER(
                    GREATEST(0, (1 - (f.embedding <=> c.embedding)) - 0.5) * 2,
                    2
                )
            END AS sem,
            CASE
                WHEN cardinality(f.contacts) = 0 OR cardinality(c.exp_contacts) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        INTERSECT
                        SELECT unnest(c.exp_contacts)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        UNION
                        SELECT unnest(c.exp_contacts)
                    )), 0),
                    2
                )
            END AS con,
            CASE
                WHEN cardinality(f.groups) = 0 OR cardinality(c.groups) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(f.groups) INTERSECT SELECT unnest(c.groups)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(f.groups) UNION SELECT unnest(c.groups)
                    )), 0),
                    2
                )
            END AS grp
        FROM moved f
        CROSS JOIN candidate c
        LEFT JOIN neg ng ON ng.priority_id = f.priority_id
        LEFT JOIN conn_key ck ON ck.conn_id = f.conn_id
    )
    SELECT jsonb_build_object(
        'top', COALESCE(jsonb_agg(
            jsonb_build_object(
                'priority_id', top_scored.pid,
                'thread_id', top_scored.tid,
                'sem', round(top_scored.sem::numeric, 4),
                'con', round(top_scored.con::numeric, 4),
                'grp', round(top_scored.grp::numeric, 4),
                'origin', round(top_scored.origin::numeric, 4),
                'combined', round((0.5 * top_scored.sem + 0.30 * top_scored.con + 0.12 * top_scored.grp + top_scored.origin - 0.3 * top_scored.neg_sim)::numeric, 4)
            )
            ORDER BY (0.5 * top_scored.sem + 0.30 * top_scored.con + 0.12 * top_scored.grp + top_scored.origin - 0.3 * top_scored.neg_sim) DESC
        ), '[]'::jsonb)
    )
    INTO v_scores
    FROM (
        SELECT scored.priority_id AS pid,
               scored.thread_id AS tid,
               scored.sem,
               scored.con,
               scored.grp,
               scored.origin,
               scored.neg_sim
        FROM scored
        ORDER BY (0.5 * scored.sem + 0.30 * scored.con + 0.12 * scored.grp + scored.origin - 0.3 * scored.neg_sim) DESC
        LIMIT 3
    ) top_scored;

    SELECT (x.priority_id)::uuid INTO v_matched
    FROM jsonb_to_recordset(v_scores->'top')
        AS x(priority_id uuid, combined numeric)
    WHERE x.combined >= 0.15
      AND NOT public.thread_facets_gated(p_user_id, v_facets, v_author_id, x.priority_id)
    ORDER BY x.combined DESC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'scoring'::text,
                            COALESCE(v_scores, '{}'::jsonb);
        RETURN;
    END IF;

    -- 5. priority:{KEY}[:{SUB_TOPIC}] prefix.
    IF v_topic LIKE 'priority:%' THEN
        v_priority_key := split_part(v_topic, ':', 2);
        IF v_priority_key <> '' THEN
            SELECT p.id INTO v_matched
            FROM public.priority p
            WHERE p.user_id = p_user_id
              AND p.key = v_priority_key
              AND p.archived_at IS NULL
            LIMIT 1;
            IF v_matched IS NOT NULL THEN
                RETURN QUERY SELECT v_matched,
                                    'priority_prefix'::text,
                                    jsonb_build_object('key', v_priority_key);
                RETURN;
            END IF;
        END IF;
    END IF;

    -- 6. Root fallback.
    SELECT p.id INTO v_matched
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'root_fallback'::text,
                            '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT NULL::uuid,
                        'none'::text,
                        '{}'::jsonb;
    RETURN;
END;
$function$;
```

- [ ] **Step 4: Load the changed function and run the routing test**

```bash
psql "$DATABASE_URL" -f libs/db/schema/60-functions/connection_org_key.sql
psql "$DATABASE_URL" -f libs/db/schema/60-functions/classify_thread_for_user.sql
pg_prove -d "$DATABASE_URL" libs/db/tests/67-connection-origin-routing.sql
```
Expected: PASS — `ok 1..5`, `Result: PASS`.

- [ ] **Step 5: Run the existing classifier/facet pgTAP to confirm no regression from the weight rebalance**

```bash
pg_prove -d "$DATABASE_URL" libs/db/tests/65-facet-gate.sql libs/db/tests/66-connection-org-key.sql libs/db/tests/67-connection-origin-routing.sql
```
Expected: all PASS. If `65-facet-gate` fails, inspect whether any assertion depended on the exact `con`/`grp` weights (it should not — it asserts routing outcomes, and `con=1` still yields `0.30 ≥ 0.15`). Fix only if a genuine threshold flip occurred.

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/60-functions/classify_thread_for_user.sql libs/db/tests/67-connection-origin-routing.sql
git commit -m "feat(db): add learned connection-origin term to thread classifier"
```

---

## Task 3: Generate migration, apply, regenerate types, verify whole suite

**Files:**
- Generate: `libs/db/migrations/<timestamp>_add_connection_origin_signal.sql`
- Regenerate: `libs/db/src/types.ts`

- [ ] **Step 1: Generate the migration from the schema files**

```bash
cd /Users/kris.braun/code/plot && pnpm gen-migration -- add_connection_origin_signal
```
Expected: a new file in `libs/db/migrations/` containing `CREATE OR REPLACE FUNCTION public.connection_org_key(...)` and the updated `classify_thread_for_user_explain`. (No table DDL — function-only.)

- [ ] **Step 2: Apply migrations to the local DB (also regenerates types)**

```bash
pnpm apply-migrations
```
Expected: applies cleanly; runs `pnpm types` and updates `libs/db/src/types.ts` (likely a no-op diff since no tables changed — that's fine).

- [ ] **Step 3: Confirm schema and migrations are in sync**

```bash
pnpm diff-schema-migrations
```
Expected: no differences.

- [ ] **Step 4: Run the full pgTAP suite**

```bash
pg_prove -d "$DATABASE_URL" libs/db/tests/*.sql
```
Expected: all PASS (212+ existing + the new 66/67). Investigate any failure before continuing.

- [ ] **Step 5: Run db lint (types-in-sync check)**

```bash
pnpm --filter @plotday/db run lint
```
Expected: passes ("types up to date").

- [ ] **Step 6: Commit migration + types**

```bash
git add libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): migration for connection-origin classification signal"
```

---

## Task 4: Finalize (docs + checklist)

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing updates bullet**

Open `docs/updates.md` and add to the top section (plain language, no internals):
```markdown
- Threads now land in the right focus based on which account they arrived through — a receipt to your work email goes to your work focus, the same receipt to your personal email goes to your personal one, learned from how you file.
```

- [ ] **Step 2: Run the finalize checklist**

Run the `/finalize` skill (lint changed packages, backwards-compat, error capture, docs, public submodule). For this change specifically:
- `pnpm --filter @plotday/db run lint` — already green from Task 3.
- No `catch` blocks added (pure SQL) — no `captureException` needed.
- No public submodule changes — connectors are untouched (origin is resolved server-side from existing data).
- Backwards compatible: additive function + `CREATE OR REPLACE`; the `classify_thread_for_user` wrapper signature is unchanged, so every existing caller (triggers, API, twist tools) is unaffected.

- [ ] **Step 3: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: note connection-aware thread routing"
```

---

## Verification (end-to-end)

- [ ] `pnpm diff-schema-migrations` — clean
- [ ] `pg_prove -d "$DATABASE_URL" libs/db/tests/*.sql` — all PASS
- [ ] `pnpm --filter @plotday/db run lint` — PASS
- [ ] Manual sanity (optional): pick a real connector thread and compare stages:
  ```bash
  psql "$DATABASE_URL" -c "SELECT * FROM public.classify_thread_for_user_explain('<user_uuid>'::uuid, '<thread_uuid>'::uuid);"
  ```
  Confirm the `scores->'top'` array now includes an `origin` field and that a thread from a trained mailbox scores into the expected focus.

## Notes / risks

- **Weights are a starting point.** `EXACT_W = 0.18`, `ORG_W = 0.09`, with `con 0.35→0.30` and `grp 0.15→0.12`. If real-world tuning is needed, the `_explain` function returns per-signal scores (`sem`/`con`/`grp`/`origin`/`combined`) for offline evaluation; adjust the five literals (three combined-formula copies + the two origin literals) together.
- **Org key resolution is best-effort.** Non-email connectors (e.g. Slack user-token-only) may have a synthetic `actor_id` with no contact email → `org_key` falls back to `team_id`, then NULL (exact-connection L1 still works). This is the intended graceful degradation; no error.
- **No backfill.** Existing connections work immediately because `actor_id → contact.email` is already populated for email connections; the signal only ever improves routing.
- **Performance:** `connection_org_key` is `STABLE` and called once per distinct example connection (via the `conn_key` CTE) plus once for the candidate — not per scored pair. For users with many `user_moved` examples this is a handful of indexed lookups.
```
