# Thread & Note Visibility Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `private` boolean and mixed `mentions` array on threads/notes with a structured `access` enum + `access_contacts` array, separating user visibility from twist dispatch routing.

**Architecture:** Database schema changes first (access enum, access_contacts, mentions split), then API translation layer with X-Plot-API-Version header for backwards compat, then Twister SDK type updates, then Flutter data layer and UI (NoteEditor bottom bar icons, access selection modal).

**Tech Stack:** PostgreSQL (Atlas migrations), TypeScript (Cloudflare Workers API), Dart/Flutter (Drift SQLite), Twister SDK

**Spec:** `docs/superpowers/specs/2026-04-08-thread-visibility-redesign.md`

---

### Task 1: Thread table schema — replace private with access + access_contacts

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql`

- [ ] **Step 1: Replace private column with access and access_contacts**

In `libs/db/schema/50-tables/24-thread.sql`, replace line 10:
```sql
    "private" boolean NOT NULL DEFAULT FALSE,
```

With:
```sql
    "access" text NOT NULL DEFAULT 'members',
    "access_contacts" uuid[],
```

- [ ] **Step 2: Add CHECK constraint and index for access**

After the existing indexes (after line 63), add:
```sql
ALTER TABLE "public"."thread"
    ADD CONSTRAINT thread_access_valid CHECK (access IN ('public', 'members', 'restricted'));

-- Support queries filtering by access level in visibility views
CREATE INDEX idx_thread_access ON "public"."thread" ("access")
WHERE
    access != 'public';

-- Support access_contacts array membership queries
CREATE INDEX idx_thread_access_contacts ON "public"."thread" USING gin ("access_contacts")
WHERE
    access_contacts IS NOT NULL;
```

- [ ] **Step 3: Update comment for access column**

Add after the new columns:
```sql
COMMENT ON COLUMN "public"."thread"."access" IS 'Access level: public (everyone in priority), members (members only), restricted (author + access_contacts only). Default is members, which equals public in priorities without viewers.';

COMMENT ON COLUMN "public"."thread"."access_contacts" IS 'Array of contact_ids granted additional access beyond the base access level. For members access, these are viewer-role contacts. For restricted access, these are the only contacts who can see the thread (besides the author).';
```

- [ ] **Step 4: Commit**
```bash
git add libs/db/schema/50-tables/24-thread.sql
git commit -m "schema: replace thread.private with access enum + access_contacts"
```

---

### Task 2: Note table schema — replace private with access_contacts, split mentions

**Files:**
- Modify: `libs/db/schema/50-tables/25-note.sql`

- [ ] **Step 1: Replace private column with access_contacts**

In `libs/db/schema/50-tables/25-note.sql`, replace line 13:
```sql
    "private" boolean NOT NULL DEFAULT FALSE,
```

With:
```sql
    "access_contacts" uuid[],
```

- [ ] **Step 2: Update mentions comment**

Replace the existing comment on line 29:
```sql
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of actor IDs (contact_id or priority_twist_id) mentioned in this note. For users, this stores their contact_id (not user_id).';
```

With:
```sql
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of priority_twist_ids (twists and connectors) mentioned in this note. Used for dispatch routing only — user visibility is handled by access_contacts.';
```

- [ ] **Step 3: Update access_contacts comment and index**

Add comment and index:
```sql
COMMENT ON COLUMN "public"."note"."access_contacts" IS 'Restricts note visibility within thread viewers. NULL = all thread viewers can see, empty array = author only, array of contact_ids = author + listed contacts.';

-- Support access_contacts array membership queries in user.note view
CREATE INDEX idx_note_access_contacts ON "public"."note" USING gin ("access_contacts")
WHERE
    access_contacts IS NOT NULL;
```

- [ ] **Step 4: Commit**
```bash
git add libs/db/schema/50-tables/25-note.sql
git commit -m "schema: replace note.private with access_contacts, clarify mentions as twist-only"
```

---

### Task 3: Remove obsolete functions and update views

**Files:**
- Delete: `libs/db/schema/60-functions/get_thread_mentions.sql`
- Delete: `libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql`
- Modify: `libs/db/schema/70-views/25-thread.sql`

- [ ] **Step 1: Delete get_thread_mentions function**

Delete the file `libs/db/schema/60-functions/get_thread_mentions.sql` entirely.

- [ ] **Step 2: Delete mentioned_in_thread function**

Delete the file `libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql` entirely.

- [ ] **Step 3: Update thread_x view to remove mentions**

In `libs/db/schema/70-views/25-thread.sql`, remove the `mentions` column from the `thread_x` view. The view currently calls `get_thread_mentions(a.id) AS mentions` — remove that column from the SELECT list. Keep `priority_path`.

The updated `thread_x` view should select from `thread` and join `priority` for `priority_path` only, without the mentions computation.

- [ ] **Step 4: Commit**
```bash
git add -A libs/db/schema/60-functions/get_thread_mentions.sql libs/db/schema/90-user-schema/06-user_mentioned_in_thread.sql libs/db/schema/70-views/25-thread.sql
git commit -m "schema: remove get_thread_mentions, mentioned_in_thread, thread_x mentions"
```

---

### Task 4: Update user.thread view visibility logic

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-thread.sql`

- [ ] **Step 1: Replace the visible rows WHERE clause**

In `libs/db/schema/90-user-schema/30-thread.sql`, replace the visibility filter at lines 147-152:
```sql
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        WHEN upe.role = 'member' THEN TRUE
        ELSE "user".mentioned_in_thread(upe.user_id, a.id)
    END)
```

With:
```sql
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND (CASE
        WHEN a.access = 'public' THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        WHEN a.access = 'members' AND upe.role = 'member' THEN TRUE
        WHEN "user".user_contact_id(upe.user_id) = ANY(a.access_contacts) THEN TRUE
        ELSE FALSE
    END)
```

- [ ] **Step 2: Update the SELECT list — replace private and mentions columns**

In the visible rows SELECT, replace `a.private` with `a.access` and `a.access_contacts`. Remove the `mentions` reference from `thread_x` (it no longer exists on `thread_x`). The thread view should expose `access`, `access_contacts` instead of `private`, `mentions`.

Also update the redacted rows SELECT to match the same columns — use `a.access` instead of `a.private`, add `a.access_contacts`, and remove the `CAST(NULL AS uuid[]) AS mentions` line (replace with `CAST(NULL AS uuid[]) AS access_contacts` for redaction).

- [ ] **Step 3: Update the redacted rows WHERE clause**

Replace lines 181-186:
```sql
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND a.private = TRUE
    AND a.created_by != upe.user_id
    AND upe.role != 'member'
    AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
```

With:
```sql
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND a.access != 'public'
    AND a.created_by != upe.user_id
    AND NOT (a.access = 'members' AND upe.role = 'member')
    AND NOT ("user".user_contact_id(upe.user_id) = ANY(COALESCE(a.access_contacts, ARRAY[]::uuid[])));
```

- [ ] **Step 4: Commit**
```bash
git add libs/db/schema/90-user-schema/30-thread.sql
git commit -m "schema: update user.thread view with access-based visibility"
```

---

### Task 5: Update user.note view visibility logic

**Files:**
- Modify: `libs/db/schema/90-user-schema/31-note.sql`

- [ ] **Step 1: Replace note-level visibility filter**

Replace the current note-level filter:
```sql
AND (n.private = FALSE
    OR n.created_by = upe.user_id
    OR "user".user_contact_id(upe.user_id) = ANY(n.mentions)
    OR upe.role = 'member')
```

With:
```sql
AND (n.access_contacts IS NULL
    OR n.created_by = upe.user_id
    OR "user".user_contact_id(upe.user_id) = ANY(n.access_contacts))
```

- [ ] **Step 2: Replace thread-level visibility filter in user.note**

Replace:
```sql
AND (CASE WHEN a.private = FALSE THEN TRUE
    WHEN a.created_by = upe.user_id THEN TRUE
    WHEN upe.role = 'member' THEN TRUE
    ELSE "user".mentioned_in_thread(upe.user_id, a.id)
END)
```

With:
```sql
AND (CASE
    WHEN a.access = 'public' THEN TRUE
    WHEN a.created_by = upe.user_id THEN TRUE
    WHEN a.access = 'members' AND upe.role = 'member' THEN TRUE
    WHEN "user".user_contact_id(upe.user_id) = ANY(a.access_contacts) THEN TRUE
    ELSE FALSE
END)
```

- [ ] **Step 3: Update the SELECT list and redacted rows**

Replace `n.private` with `n.access_contacts` in the SELECT list. Update the redacted rows UNION ALL similarly — replace `n.private` column, update the WHERE clause for the redacted note rows to use the new access model (both note-level and thread-level checks).

The redacted rows WHERE should match notes where:
```sql
AND (
    -- Note is restricted and user can't see it
    (n.access_contacts IS NOT NULL
        AND n.created_by != upe.user_id
        AND NOT ("user".user_contact_id(upe.user_id) = ANY(COALESCE(n.access_contacts, ARRAY[]::uuid[]))))
    OR
    -- Thread is restricted and user can't see it
    (a.access != 'public'
        AND a.created_by != upe.user_id
        AND NOT (a.access = 'members' AND upe.role = 'member')
        AND NOT ("user".user_contact_id(upe.user_id) = ANY(COALESCE(a.access_contacts, ARRAY[]::uuid[]))))
)
```

- [ ] **Step 4: Commit**
```bash
git add libs/db/schema/90-user-schema/31-note.sql
git commit -m "schema: update user.note view with access-based visibility"
```

---

### Task 6: Update priority_unread view

**Files:**
- Modify: `libs/db/schema/90-user-schema/21-priority_unread.sql`

- [ ] **Step 1: Replace visibility filter**

In `libs/db/schema/90-user-schema/21-priority_unread.sql`, replace lines 13-17:
```sql
        AND (
            a.private = FALSE
            OR a.created_by = upe.user_id
            OR "user".mentioned_in_thread (upe.user_id, a.id)
        )
```

With:
```sql
        AND (CASE
            WHEN a.access = 'public' THEN TRUE
            WHEN a.created_by = upe.user_id THEN TRUE
            WHEN a.access = 'members' AND upe.role = 'member' THEN TRUE
            WHEN "user".user_contact_id(upe.user_id) = ANY(a.access_contacts) THEN TRUE
            ELSE FALSE
        END)
```

- [ ] **Step 2: Commit**
```bash
git add libs/db/schema/90-user-schema/21-priority_unread.sql
git commit -m "schema: update priority_unread view with access-based visibility"
```

---

### Task 7: Update upsert_thread RPC function

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql`

- [ ] **Step 1: Replace private references with access/access_contacts**

In the INSERT VALUES clause (line 127), replace:
```sql
COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE)
```

With:
```sql
COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members')
```

And add `access_contacts` to the INSERT column list and VALUES:
```sql
-- In column list, after 'access':
, access_contacts
-- In VALUES, after the access value:
, CASE WHEN p_thread ? 'access_contacts' THEN
    (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem)
  WHEN p_defaults ? 'access_contacts' THEN
    (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem)
  ELSE NULL END
```

- [ ] **Step 2: Update ON CONFLICT DO UPDATE for access fields**

Replace the `private` update block (lines 179-187):
```sql
private = CASE WHEN v_is_archived THEN
    COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, thread.private)
ELSE
    CASE WHEN p_thread ? 'private' THEN
        (p_thread ->> 'private')::boolean
    ELSE
        thread.private
    END
END,
```

With:
```sql
access = CASE WHEN v_is_archived THEN
    COALESCE(p_thread ->> 'access', p_defaults ->> 'access', thread.access)
ELSE
    CASE WHEN p_thread ? 'access' THEN
        p_thread ->> 'access'
    ELSE
        thread.access
    END
END,
access_contacts = CASE WHEN v_is_archived THEN
    CASE WHEN p_thread ? 'access_contacts' THEN
        (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem)
    WHEN p_defaults ? 'access_contacts' THEN
        (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem)
    ELSE thread.access_contacts END
ELSE
    CASE WHEN p_thread ? 'access_contacts' THEN
        (SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem)
    ELSE
        thread.access_contacts
    END
END,
```

- [ ] **Step 3: Update viewer enforcement**

Replace lines 74-91 viewer enforcement:
```sql
IF v_role = 'viewer' THEN
    IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_id) THEN
        IF COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE) IS NOT TRUE THEN
            RAISE EXCEPTION 'Viewer members can only create private threads';
        END IF;
    ELSE
        IF NOT EXISTS (
            SELECT 1 FROM thread
            WHERE id = v_id AND private = TRUE AND created_by = user_id
        ) THEN
            RAISE EXCEPTION 'Viewer members cannot modify threads they did not create';
        END IF;
    END IF;
END IF;
```

With:
```sql
IF v_role = 'viewer' THEN
    IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_id) THEN
        -- New thread: force access = 'members' for viewers
        IF COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members') = 'public' THEN
            RAISE EXCEPTION 'Viewer members can only create private threads';
        END IF;
    ELSE
        -- Existing thread: viewers can only modify their own non-public threads
        IF NOT EXISTS (
            SELECT 1 FROM thread
            WHERE id = v_id AND access != 'public' AND created_by = user_id
        ) THEN
            RAISE EXCEPTION 'Viewer members cannot modify threads they did not create';
        END IF;
    END IF;
END IF;
```

- [ ] **Step 4: Commit**
```bash
git add libs/db/schema/90-user-schema/80-upsert_thread.sql
git commit -m "schema: update upsert_thread for access/access_contacts"
```

---

### Task 8: Update upsert_note RPC function

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`

- [ ] **Step 1: Replace p_private parameter with p_access_contacts**

In the `upsert_note` function signature, replace:
```sql
p_private boolean,
```

With:
```sql
p_access_contacts uuid[],
```

- [ ] **Step 2: Update private thread access validation**

Replace the private thread access check (lines 186-194):
```sql
IF (SELECT private FROM thread WHERE id = p_thread_id) = TRUE THEN
    IF "user".get_effective_role(user_id, v_priority_id) != 'member'
       AND (SELECT created_by FROM thread WHERE id = p_thread_id) != upsert_note.user_id
       AND NOT "user".mentioned_in_thread(upsert_note.user_id, p_thread_id)
    THEN
        RAISE EXCEPTION 'Access denied to private thread';
    END IF;
END IF;
```

With:
```sql
-- Check thread access for the user
DECLARE v_thread_access text;
DECLARE v_thread_created_by uuid;
DECLARE v_thread_access_contacts uuid[];
BEGIN
    SELECT access, created_by, access_contacts
    INTO v_thread_access, v_thread_created_by, v_thread_access_contacts
    FROM thread WHERE id = p_thread_id;

    IF v_thread_access != 'public' THEN
        IF v_thread_created_by != upsert_note.user_id
           AND NOT (v_thread_access = 'members' AND "user".get_effective_role(user_id, v_priority_id) = 'member')
           AND NOT ("user".user_contact_id(upsert_note.user_id) = ANY(COALESCE(v_thread_access_contacts, ARRAY[]::uuid[])))
        THEN
            RAISE EXCEPTION 'Access denied to private thread';
        END IF;
    END IF;
END;
```

Note: The exact placement of DECLARE/BEGIN may need adjustment to fit the existing function structure — these variables should be declared at the top of the function and the access check should replace the existing one inline.

- [ ] **Step 3: Update viewer enforcement for notes**

Replace the viewer enforcement (lines 196-211):
```sql
IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
    p_private := TRUE;
    -- auto-mention thread author logic...
END IF;
```

With:
```sql
IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
    -- Viewers in public threads: force note to be author-only
    IF v_thread_access = 'public' THEN
        p_access_contacts := ARRAY[]::uuid[];
    END IF;
    -- In non-public threads: viewers keep whatever access_contacts was passed (default NULL = all thread viewers)
END IF;
```

- [ ] **Step 4: Update INSERT/UPSERT statements**

In both INSERT statements (p_id IS NULL and p_id provided), replace `private` column and value:
- Column list: replace `private` with `access_contacts`
- Values: replace `COALESCE(p_private, FALSE)` with `p_access_contacts`
- ON CONFLICT DO UPDATE: replace `private = EXCLUDED.private` with `access_contacts = EXCLUDED.access_contacts`

The `mentions` column stays in the INSERT — its values are now twist-only but the column itself doesn't change.

- [ ] **Step 5: Commit**
```bash
git add libs/db/schema/90-user-schema/85-user-sync-upserts.sql
git commit -m "schema: update upsert_note for access_contacts, twist-only mentions"
```

---

### Task 9: Search for and update all other schema references to private/mentioned_in_thread

**Files:**
- Search all files in `libs/db/schema/` for references to `private`, `mentioned_in_thread`, `get_thread_mentions`

- [ ] **Step 1: Search for remaining references**

```bash
grep -rn 'private\|mentioned_in_thread\|get_thread_mentions' libs/db/schema/ --include='*.sql' | grep -v '^Binary'
```

Update any remaining views, functions, or triggers that reference:
- `thread.private` or `a.private` → use `thread.access`/`a.access`
- `note.private` or `n.private` → use `note.access_contacts`/`n.access_contacts`
- `mentioned_in_thread()` → replace with `access_contacts` array check
- `get_thread_mentions()` → remove references

Key files likely needing updates:
- `libs/db/schema/90-user-schema/10-update_thread_tags.sql` — if it references private
- `libs/db/schema/90-user-schema/11-update_note_tags.sql` — if it references private
- `libs/db/schema/95-triggers/` — any triggers referencing private
- Any twist sync views in `libs/db/schema/70-views/`

- [ ] **Step 2: Fix all found references**

Update each file to use the new access model.

- [ ] **Step 3: Commit**
```bash
git add libs/db/schema/
git commit -m "schema: update all remaining private/mention references to access model"
```

---

### Task 10: Generate migration with data migration

- [ ] **Step 1: Generate the schema migration**

```bash
pnpm gen-migration -- thread_note_visibility_redesign
```

- [ ] **Step 2: Add data migration SQL to the generated file**

Open the generated migration file in `libs/db/migrations/` and add data migration SQL after the schema changes:

```sql
-- Data migration: thread.private → thread.access

-- Identify priorities with viewers
CREATE TEMPORARY TABLE _priorities_with_viewers AS
SELECT DISTINCT pu.priority_id
FROM priority_user pu
WHERE pu.role = 'viewer' AND pu.archived_at IS NULL;

-- Priorities with viewers: private=true → access='members' (already default)
-- Priorities with viewers: private=false → access='public'
UPDATE thread SET access = 'public'
WHERE private = FALSE
  AND priority_id IN (SELECT priority_id FROM _priorities_with_viewers);

-- Other priorities: private=true → access='restricted'
UPDATE thread SET access = 'restricted'
WHERE private = TRUE
  AND priority_id NOT IN (SELECT priority_id FROM _priorities_with_viewers);

-- Other priorities: private=false → access='members' (already default, no-op)

-- Data migration: note.private + note.mentions → note.access_contacts + note.mentions (twist-only)

-- Split note.mentions: user contacts → access_contacts, twist IDs → stays in mentions
-- For private notes: set access_contacts from user contact mentions
UPDATE note n SET
    access_contacts = (
        SELECT COALESCE(array_agg(m), ARRAY[]::uuid[])
        FROM unnest(n.mentions) m
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = m)
    )
WHERE n.private = TRUE;

-- Update mentions to only contain twist IDs
UPDATE note n SET
    mentions = (
        SELECT array_agg(m)
        FROM unnest(n.mentions) m
        WHERE EXISTS (SELECT 1 FROM priority_twist pt WHERE pt.id = m)
    )
WHERE n.mentions IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM unnest(n.mentions) m
    WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = m)
  );

-- Thread access_contacts: for restricted threads, aggregate user contacts from note access_contacts
UPDATE thread t SET
    access_contacts = (
        SELECT COALESCE(array_agg(DISTINCT ac), ARRAY[]::uuid[])
        FROM note n, unnest(n.access_contacts) ac
        WHERE n.thread_id = t.id AND n.access_contacts IS NOT NULL
    )
WHERE t.access = 'restricted';

DROP TABLE _priorities_with_viewers;
```

Note: The migration also needs to handle dropping the `private` column from both tables. Atlas should generate this automatically from the schema diff. If not, add:
```sql
ALTER TABLE thread DROP COLUMN private;
ALTER TABLE note DROP COLUMN private;
```

- [ ] **Step 3: Apply migration**

```bash
pnpm apply-migrations
```

- [ ] **Step 4: Verify schema sync**

```bash
pnpm diff-schema-migrations
```

Should return no differences.

- [ ] **Step 5: Regenerate types**

```bash
pnpm types
```

- [ ] **Step 6: Commit**
```bash
git add libs/db/migrations/ libs/db/src/
git commit -m "migration: thread/note visibility redesign with data migration"
```

---

### Task 11: API version header middleware

**Files:**
- Modify: `workers/api/src/middleware/client-version.ts`

- [ ] **Step 1: Add API version parsing**

In `workers/api/src/middleware/client-version.ts`, add to the `ClientInfo` type:
```typescript
apiVersion: number;
```

In the middleware function, after parsing `X-Plot-Client`, add:
```typescript
const apiVersionHeader = c.req.header("X-Plot-API-Version");
const apiVersion = apiVersionHeader ? parseInt(apiVersionHeader, 10) || 0 : 0;
```

Include `apiVersion` in the `ClientInfo` object set on the context.

If `ClientInfo` is currently optional (only set when header present), ensure `apiVersion` is always accessible — either make it a separate context variable or always create a `ClientInfo` with at least `apiVersion`.

- [ ] **Step 2: Commit**
```bash
git add workers/api/src/middleware/client-version.ts
git commit -m "api: add X-Plot-API-Version header parsing"
```

---

### Task 12: Sync endpoint translation — Threads

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts`

- [ ] **Step 1: Add version-branched POST handler**

In the POST handler for `/sync/threads`, after parsing `body`, add translation for old clients:

```typescript
const apiVersion = c.var.clientInfo?.apiVersion ?? 0;

if (apiVersion < 1) {
  // Translate old private field to new access field
  const threadData = body.thread || body;
  if (threadData.private !== undefined) {
    // Determine if priority has viewers to choose correct access level
    const hasViewers = await c.var.db
      .selectFrom("priority_user")
      .select("priority_id")
      .where("priority_id", "=", threadData.priority_id)
      .where("role", "=", "viewer")
      .where("archived_at", "is", null)
      .limit(1)
      .executeTakeFirst();

    if (threadData.private === true) {
      threadData.access = hasViewers ? "members" : "restricted";
    } else {
      threadData.access = hasViewers ? "public" : "members";
    }
    delete threadData.private;
  }
}
```

- [ ] **Step 2: Add version-branched GET response**

For the GET response, add translation after fetching results:

```typescript
if (apiVersion < 1) {
  // Translate access back to private for old clients
  for (const thread of results) {
    (thread as any).private = thread.access !== "public";
    // Merge access_contacts into mentions for old clients
    (thread as any).mentions = [
      ...((thread as any).access_contacts || []),
    ];
  }
}
```

- [ ] **Step 3: Commit**
```bash
git add workers/api/src/app/sync/threads.ts
git commit -m "api: version-branched thread sync for visibility redesign"
```

---

### Task 13: Sync endpoint translation — Notes

**Files:**
- Modify: `workers/api/src/app/sync/notes.ts`

- [ ] **Step 1: Add version-branched POST handler**

In the POST handler for `/sync/notes`, add translation before calling RPC:

```typescript
const apiVersion = c.var.clientInfo?.apiVersion ?? 0;

if (apiVersion < 1) {
  // Translate old private to access_contacts
  if (body.private === true) {
    body.access_contacts = body.access_contacts ?? [];
  } else if (body.private === false) {
    body.access_contacts = null;
  }
  delete body.private;

  // Split mentions: user contacts → access_contacts, twist IDs → mentions
  if (Array.isArray(body.mentions)) {
    const twistIds = [];
    const userContacts = [];
    for (const id of body.mentions) {
      const isTwist = await c.var.db
        .selectFrom("priority_twist")
        .select("id")
        .where("id", "=", id)
        .executeTakeFirst();
      if (isTwist) {
        twistIds.push(id);
      } else {
        userContacts.push(id);
      }
    }
    body.mentions = twistIds.length > 0 ? twistIds : null;
    if (userContacts.length > 0 && body.access_contacts !== null) {
      body.access_contacts = [...(body.access_contacts || []), ...userContacts];
    }
  }
}

// Update RPC call to use new parameter names
const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
  await assertThreadAccess(trx, c.var.user.id, body.thread_id);
  return rpcUser(trx, "upsert_note", {
    user_id: c.var.user.id,
    p_id: body.id || null,
    p_author_id: body.author_id,
    p_created_by: body.created_by || c.var.user.id,
    p_updated_by: body.updated_by || 0,
    p_archived_at: body.archived_at || null,
    p_thread_id: body.thread_id,
    p_draft: body.draft || false,
    p_access_contacts: body.access_contacts ?? null,
    p_content: body.content || null,
    p_actions: body.actions || null,
    p_mentions: (Array.isArray(body.mentions)
      ? `{${body.mentions.join(",")}}`
      : null) as any,
    p_re_note_id: body.re_note_id || null,
    p_source_created_at: body.source_created_at || null,
    p_key: body.key || null,
    p_merged_from_thread_id: body.merged_from_thread_id || null,
  });
});
```

- [ ] **Step 2: Add version-branched GET response**

```typescript
if (apiVersion < 1) {
  for (const note of results) {
    (note as any).private = note.access_contacts !== null;
    // Merge access_contacts users into mentions for old clients
    (note as any).mentions = [
      ...((note as any).mentions || []),
      ...((note as any).access_contacts || []),
    ];
  }
}
```

- [ ] **Step 3: Commit**
```bash
git add workers/api/src/app/sync/notes.ts
git commit -m "api: version-branched note sync for visibility redesign"
```

---

### Task 14: Update Plot twist tool — thread creation and converters

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts`
- Modify: `workers/api/src/twist/tools/plot/thread.ts`
- Modify: `workers/api/src/twist/tools/plot/converters.ts`

- [ ] **Step 1: Update prepareThreadForDb in thread-helpers.ts**

Replace `private: activity.private ?? false` with:
```typescript
access: activity.access ?? "members",
access_contacts: activity.accessContacts ?? null,
```

- [ ] **Step 2: Update fromDbThread converter**

In `converters.ts`, replace:
```typescript
private: dbThread.private ?? false,
```
With:
```typescript
access: (dbThread.access as "public" | "members" | "restricted") ?? "members",
accessContacts: (dbThread.access_contacts as ActorId[]) || [],
```

Remove the `mentions` line from `fromDbThread` (thread no longer has mentions).

- [ ] **Step 3: Update fromDbNote converter**

Replace:
```typescript
private: dbNote.private ?? false,
```
With:
```typescript
accessContacts: dbNote.access_contacts as ActorId[] | null,
```

The `mentions` field stays but now only contains twist IDs.

- [ ] **Step 4: Commit**
```bash
git add workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/plot/thread.ts workers/api/src/twist/tools/plot/converters.ts
git commit -m "api: update twist tools for access/access_contacts model"
```

---

### Task 15: Update note creation — twist-only mentions

**Files:**
- Modify: `workers/api/src/twist/tools/plot/note.ts`

- [ ] **Step 1: Update createNote private → access_contacts**

In `note.ts` createNote function, replace:
```typescript
private: note.private ?? false,
```
With:
```typescript
access_contacts: note.accessContacts ?? null,
```

- [ ] **Step 2: Ensure auto-mention logic only adds twist IDs**

The existing auto-mention logic (lines 175-191) already only adds `plot.priorityTwistId` and thread creator twist IDs — these are priority_twist_ids, not user contacts. Verify no user contact_ids are being added to `mentionIds`. The `processNewActorArray()` call for `note.mentions` should filter to only return priority_twist_ids.

If `processNewActorArray` can return user contact_ids, add filtering:
```typescript
if (mentionIds) {
  // Filter to only twist/connector IDs
  const twistOnly = [];
  for (const id of mentionIds) {
    const isTwist = await plot.db
      .selectFrom("priority_twist")
      .select("id")
      .where("id", "=", id as string)
      .executeTakeFirst();
    if (isTwist) twistOnly.push(id);
  }
  mentionIds = twistOnly;
}
```

- [ ] **Step 3: Update the upsert statements**

In the Kysely insert/upsert calls, replace:
- `private: eb.ref("excluded.private")` → `access_contacts: eb.ref("excluded.access_contacts")`
- In the "is distinct from" WHERE clause: replace `note.private` comparison with `note.access_contacts`

- [ ] **Step 4: Update updateNote similarly**

In the `updateNote` function, replace `dbUpdate.private = note.private` with `dbUpdate.access_contacts = note.accessContacts`.

- [ ] **Step 5: Commit**
```bash
git add workers/api/src/twist/tools/plot/note.ts
git commit -m "api: update note creation for access_contacts and twist-only mentions"
```

---

### Task 16: Update Integrations tool

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts`

- [ ] **Step 1: Update buildNoteAndThread**

Replace `private: item.private ?? false` with `access: item.access ?? "members"` for thread creation.
Replace `private: item.private ?? false` with `accessContacts: item.accessContacts ?? null` for note creation.

- [ ] **Step 2: Update dispatch mention checks**

The dispatch logic checks `(item.mentions ?? []).includes(this.priorityTwistId)` — this should still work since mentions is now twist-only. Verify no user contact checks are needed.

- [ ] **Step 3: Commit**
```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "api: update integrations tool for visibility redesign"
```

---

### Task 17: Lint and verify API

- [ ] **Step 1: Run API lint**

```bash
pnpm --filter @plotday/api lint
```

Fix any type errors from the schema changes. The generated `db-types.ts` should now have `access` and `access_contacts` instead of `private` on thread, and `access_contacts` instead of `private` on note.

- [ ] **Step 2: Search for remaining private references in API**

```bash
grep -rn '\.private\b\|"private"\|private:' workers/api/src/ --include='*.ts' | grep -v node_modules | grep -v 'db-types'
```

Fix any remaining references.

- [ ] **Step 3: Commit fixes**
```bash
git add workers/api/
git commit -m "api: fix lint errors from visibility redesign"
```

---

### Task 18: Update Twister SDK types

**Files:**
- Modify: `public/twister/src/plot.ts`

- [ ] **Step 1: Update ThreadCommon type**

Replace in `ThreadCommon`:
```typescript
/** Whether this thread is private (only visible to creator) */
private: boolean;
```
With:
```typescript
/** Access level: 'public' = everyone in priority, 'members' = members only, 'restricted' = author + accessContacts */
access: "public" | "members" | "restricted";
/** Contact IDs granted additional access beyond the base level */
accessContacts: ActorId[];
```

Remove from `ThreadCommon`:
```typescript
/** Array of actor IDs (users, contacts, or twists) mentioned in this thread via @-mentions */
mentions: ActorId[];
```

- [ ] **Step 2: Update Note type**

Replace:
```typescript
/** Whether this note is private */
private: boolean;
```
With:
```typescript
/** Restricts visibility within thread viewers. null = all, [] = author only, [ids] = author + listed */
accessContacts: ActorId[] | null;
```

The `mentions` field stays on Note but update its doc:
```typescript
/** Priority twist IDs (twists/connectors) mentioned for dispatch routing. Does not include user contacts. */
mentions: ActorId[];
```

- [ ] **Step 3: Update NewThread type**

In the `Partial<Omit<ThreadFields, ...>>` — the Omit should now exclude `"access"` and `"accessContacts"` from the Partial if they have different types in NewThread. Add explicit fields:
```typescript
access?: "public" | "members" | "restricted";
accessContacts?: ActorId[];
```

Remove `mentions` from NewThread's Omit list (thread no longer has mentions).

- [ ] **Step 4: Update NewNote type**

Replace `private` references. The `Partial<Omit<Note, ...>>` should handle `accessContacts` automatically since it's on Note. Verify `mentions` in NewNote is typed as `NewActor[]` for twist/connector references only — update the doc comment.

- [ ] **Step 5: Update NoteUpdate and ThreadUpdate types**

Replace `Pick<Note, "private" | ...>` references with the new field names.

- [ ] **Step 6: Build and verify**

```bash
cd public/twister && pnpm build
```

- [ ] **Step 7: Commit**
```bash
cd /Users/kris.braun/code/plot
git -C public add twister/src/plot.ts twister/dist/
git -C public commit -m "twister: replace private/mentions with access/accessContacts model"
```

---

### Task 19: Twister changeset

**Files:**
- Create: `public/.changeset/thread-visibility-redesign.md`

- [ ] **Step 1: Create changeset**

Create `public/.changeset/thread-visibility-redesign.md`:
```markdown
---
"@plotday/twister": minor
---

Changed: Thread and Note visibility model — replaced `private` boolean with `access` enum ('public'|'members'|'restricted') and `accessContacts` array. Removed `mentions` from Thread type. Note `mentions` now contains only twist/connector IDs for dispatch routing.
```

- [ ] **Step 2: Validate changeset**

```bash
cd public && pnpm validate-changesets
```

- [ ] **Step 3: Commit**
```bash
git -C public add .changeset/thread-visibility-redesign.md
git -C public commit -m "changeset: thread visibility redesign"
```

---

### Task 20: Update existing twists/sources for new types

- [ ] **Step 1: Search for private/mentions usage in twists and sources**

```bash
grep -rn '\.private\b\|private:' public/sources/ public/twists/ twists/ public/connectors/ --include='*.ts' | grep -v node_modules | grep -v dist
```

- [ ] **Step 2: Update each found reference**

Common patterns to replace:
- `private: true` → `access: "restricted"` (for auth activities that should be author-only)
- `private: true` with mentions → `access: "restricted"` + `accessContacts: [mentionedUserId]`
- `note.private` reads → `note.accessContacts !== null`
- `thread.private` reads → `thread.access !== "public"`

- [ ] **Step 3: Build all affected packages**

```bash
pnpm lint
```

- [ ] **Step 4: Commit**
```bash
git add public/sources/ public/twists/ public/connectors/ twists/
git commit -m "twists: update sources/connectors for visibility redesign types"
```

---

### Task 21: Flutter Drift table updates

**Files:**
- Modify: `apps/plot/lib/store/thread.dart`
- Modify: `apps/plot/lib/store/note.dart`

- [ ] **Step 1: Update Threads table**

In `apps/plot/lib/store/thread.dart`, in the `Threads` class, replace:
```dart
BoolColumn get private => boolean().withDefault(const Constant(false))();
```
With:
```dart
TextColumn get access => text().withDefault(const Constant('members'))();
TextColumn get accessContacts => text().nullable().map(const UuidListConverter())();
```

Remove:
```dart
TextColumn get mentions => text().nullable().map(const UuidListConverter())();
```

- [ ] **Step 2: Update Thread model class**

Update the Thread class properties:
- Replace `bool get private => _thread.private;` with `String get access => _thread.access;`
- Add `List<Uuid>? get accessContacts => _thread.accessContacts;`
- Remove `List<Uuid>? get mentions => _thread.mentions;`
- Add helper: `bool get isPublic => access == 'public';`
- Add helper: `bool get isRestricted => access == 'restricted';`
- Add helper: `bool get isPrivate => access != 'public';` (for UI convenience)

- [ ] **Step 3: Update Thread.copyWith**

Replace `bool? private` parameter with `String? access` and `Value<List<Uuid>?> accessContacts`. Remove `mentions` parameter.

- [ ] **Step 4: Update Notes table**

In `apps/plot/lib/store/note.dart`, in the `Notes` class, replace:
```dart
BoolColumn get private => boolean().withDefault(const Constant(false))();
```
With:
```dart
TextColumn get accessContacts => text().nullable().map(const ActorIdListConverter())();
```

The `mentions` column stays but its semantics change (twist-only).

- [ ] **Step 5: Update Note model class**

Replace `final bool private;` with `final List<ActorId>? accessContacts;`.
Add helper: `bool get isPrivate => accessContacts != null;`
Add helper: `bool get isAuthorOnly => accessContacts != null && accessContacts!.isEmpty;`

- [ ] **Step 6: Update Note.copyWith**

Replace `bool? private` with `Value<List<ActorId>?> accessContacts = const Value.absent()`.

- [ ] **Step 7: Update Note.toRow()**

Replace `private: private` with `accessContacts: accessContacts`.

- [ ] **Step 8: Commit**
```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/store/note.dart
git commit -m "flutter: update Drift tables for access/access_contacts model"
```

---

### Task 22: Update Tag.private mapping

**Files:**
- Modify: `apps/plot/lib/store/tag.dart`
- Modify: `apps/plot/lib/store/note.dart` (tags getter, hasTag, setTag)

- [ ] **Step 1: Update Note.tags getter**

In `note.dart`, replace:
```dart
Map<Tag, List<ActorId>> get tags => {
  if (private) Tag.private: [authorId],
  ...(_tags?.tags ?? const {}),
};
```
With:
```dart
Map<Tag, List<ActorId>> get tags => {
  if (isPrivate) Tag.private: [authorId],
  ...(_tags?.tags ?? const {}),
};
```

- [ ] **Step 2: Update Note.hasTag**

Replace:
```dart
if (tag == Tag.private) return private;
```
With:
```dart
if (tag == Tag.private) return isPrivate;
```

- [ ] **Step 3: Update Note.setTag**

Replace:
```dart
if (tag == Tag.private) {
  return copyWith(private: value);
}
```
With:
```dart
if (tag == Tag.private) {
  return copyWith(accessContacts: Value(value ? [] : null));
}
```

- [ ] **Step 4: Commit**
```bash
git add apps/plot/lib/store/tag.dart apps/plot/lib/store/note.dart
git commit -m "flutter: update Tag.private mapping for access_contacts"
```

---

### Task 23: Update Flutter sync layer

**Files:**
- Modify: `apps/plot/lib/api/api.dart`
- Modify: `apps/plot/lib/store/sync.dart` (or wherever thread/note serialization for API calls lives)

- [ ] **Step 1: Add API version header**

In `apps/plot/lib/api/api.dart`, in `getHeaders()`, add:
```dart
'X-Plot-API-Version': '1',
```

- [ ] **Step 2: Update thread serialization**

In the thread `toBase()` method, ensure:
- `access` is included (it replaces `private`)
- `access_contacts` is included
- `mentions` is removed (already removed in toBase, but verify)
- `private` is no longer sent

- [ ] **Step 3: Update note serialization**

Ensure note serialization:
- Sends `access_contacts` instead of `private`
- Sends `mentions` (twist-only)

- [ ] **Step 4: Update deserialization**

Ensure thread/note parsing from API responses reads `access`/`access_contacts` instead of `private`.

- [ ] **Step 5: Commit**
```bash
git add apps/plot/lib/api/api.dart apps/plot/lib/store/
git commit -m "flutter: update sync layer for API version 1 and new fields"
```

---

### Task 24: Add Drift migration

**Files:**
- Modify: `apps/plot/lib/store/store.dart`

- [ ] **Step 1: Increment schema version**

The current schema version is 291. Add migration at version 292.

- [ ] **Step 2: Add migration code**

```dart
if (from < 292) {
  // Thread: add access and access_contacts, drop private and mentions
  await m.addColumn(threads, threads.access);
  await m.addColumn(threads, threads.accessContacts);
  await m.database.customStatement(
    "UPDATE threads SET access = CASE WHEN private = 1 THEN 'restricted' ELSE 'members' END",
  );
  // ignore: experimental_member_use
  await m.alterTable(TableMigration(threads)); // drops private, mentions columns

  // Note: add access_contacts, drop private
  await m.addColumn(notes, notes.accessContacts);
  await m.database.customStatement(
    "UPDATE notes SET access_contacts = CASE WHEN private = 1 THEN '[]' ELSE NULL END",
  );
  // Split mentions: keep as-is (local DB doesn't distinguish twist vs user)
  // The server will handle the split during sync
  // ignore: experimental_member_use
  await m.alterTable(TableMigration(notes)); // drops private column
}
```

Note: SQLite stores booleans as 0/1 integers, so check `private = 1` not `private = TRUE`.

- [ ] **Step 3: Commit**
```bash
git add apps/plot/lib/store/store.dart
git commit -m "flutter: add Drift migration for visibility redesign"
```

---

### Task 25: Update NoteEditor bottom bar — lock icon

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`
- Modify: `apps/plot/lib/command/note.dart`

- [ ] **Step 1: Update ToggleNotePrivate command**

In `note.dart`, update `ToggleNotePrivate` to work with access_contacts:

```dart
class ToggleNotePrivate extends NoteCommand {
  ToggleNotePrivate(super.note, {this.isViewer = false})
    : super(
        title: isViewer
            ? (note.isPrivate ? 'Private' : 'Public')
            : (note.isPrivate ? 'Make public' : 'Make private'),
        eventObject: EventObject.note,
        eventAction: note.isPrivate ? EventAction.untagged : EventAction.tagged,
        icon: PlotIcon.private,
        on: isViewer ? note.isPrivate : null,
      );

  final bool isViewer;

  @override
  bool enabled(BuildContext context) => !isViewer;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (isViewer) return const CommandDone();
    try {
      final updatedNote = note.copyWith(
        accessContacts: Value(note.isPrivate ? null : []),
      );
      await updatedNote.save();
      return const CommandDone();
    } catch (e, stackTrace) {
      log.severe('Error in ToggleNotePrivate: $e', e, stackTrace);
      return CommandMessage('Failed to toggle private', isError: true);
    }
  }
}
```

- [ ] **Step 2: Replace the bottom bar private toggle with access-aware icon**

In `note_editor.dart`, in `_buildNoteBottomBar()`, replace the ToggleNoteTag/private section with logic that:

For non-viewer priorities:
```dart
if (!widget.viewerMode)
  Button.icon(
    widget.draft.isPrivate
        ? PickAccessContacts(widget.draft) // opens modal
        : ToggleNotePrivate(widget.draft),  // quick toggle to restricted
    selected: widget.draft.isPrivate,
    count: _accessCount(widget.draft),
  ),
```

For viewer priorities (accented by default):
```dart
if (!widget.viewerMode && _isViewerPriority)
  Button.icon(
    PickAccessContacts(widget.draft), // always opens modal
    selected: true,
    count: _viewerAccessCount(widget.draft),
  ),
```

Viewers: don't show the lock icon at all.

- [ ] **Step 3: Add helper methods**

```dart
int? _accessCount(Note note) {
  if (!note.isPrivate) return null;
  final total = 1 + (note.accessContacts?.length ?? 0); // author + contacts
  return total > 1 ? total : null;
}

int? _viewerAccessCount(Note note) {
  // Count only viewer contacts in access_contacts
  final viewerCount = note.accessContacts?.length ?? 0;
  return viewerCount > 0 ? viewerCount : null;
}
```

- [ ] **Step 4: Commit**
```bash
git add apps/plot/lib/widget/note_editor.dart apps/plot/lib/command/note.dart
git commit -m "flutter: update NoteEditor lock icon for access model"
```

---

### Task 26: Access selection modal

**Files:**
- Create: `apps/plot/lib/command/access.dart`

- [ ] **Step 1: Create PickAccessContacts command**

Following the `PickNoteAssignee` pattern in `note.dart`:

```dart
class PickAccessContacts extends ShowCommands {
  PickAccessContacts(this.note)
    : super(
        title: 'Thread access',
        icon: PlotIcon.private,
        commandsBuilder: (context) => _getAccessCommands(note),
        showFilter: true,
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  final Note note;

  static Future<Commands> _getAccessCommands(Note note) async {
    final thread = await Thread.getOne(note.threadId);
    final freshNote = await note.refresh();
    final accessContactIds = freshNote.accessContacts ?? [];

    // Get priority contacts
    final memberActors = await _getMemberActors(thread.priority.id);
    
    return Commands(
      prompt: 'Thread access',
      groups: [
        // "Make public" option at top
        StaticCommandGroup(
          title: '',
          commands: [
            MakePublicCommand(freshNote),
          ],
        ),
        // Current user (locked)
        StaticCommandGroup(
          title: 'Access',
          commands: [
            LockedSelfAccess(freshNote),
            ...memberActors
                .where((a) => !a.id.isCurrentUser)
                .map((actor) => ToggleAccessContact(freshNote, actor, 
                    selected: accessContactIds.contains(actor.id)))
                .toList(),
          ],
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Create MakePublicCommand**

```dart
class MakePublicCommand extends NoteCommand {
  MakePublicCommand(super.note)
    : super(
        title: 'Make public',
        icon: PlotIcon.public, // or appropriate icon
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final updatedNote = note.copyWith(accessContacts: const Value(null));
    await updatedNote.save();
    return const CommandDone();
  }
}
```

- [ ] **Step 3: Create ToggleAccessContact command**

```dart
class ToggleAccessContact extends Command {
  ToggleAccessContact(this.note, this.actor, {required this.selected})
    : super(
        title: actor.name ?? actor.email ?? 'Unknown',
        icon: selected ? PlotIcon.checkboxChecked : PlotIcon.checkboxUnchecked,
        eventObject: EventObject.note,
        eventAction: EventAction.updated,
      );

  final Note note;
  final Actor actor;
  final bool selected;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final currentContacts = note.accessContacts ?? [];
    final updatedContacts = selected
        ? currentContacts.where((id) => id != actor.id).toList()
        : [...currentContacts, actor.id];
    final updatedNote = note.copyWith(accessContacts: Value(updatedContacts));
    await updatedNote.save();
    return const CommandDone();
  }
}
```

- [ ] **Step 4: Commit**
```bash
git add apps/plot/lib/command/access.dart
git commit -m "flutter: add access selection modal commands"
```

---

### Task 27: NoteEditor bottom bar — connector and twist icons

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Remove twist toggle chips above editor**

Remove the `_buildTwistToggleChip()` method and the chip row rendering (lines ~584-645). The `_disabledTwists` set can stay for tracking state.

- [ ] **Step 2: Add connector (plug) icon to bottom bar**

After the lock icon in `_buildNoteBottomBar()`, add:

```dart
// Connector icon — only shown when thread created by handleReplies connector
if (_handleRepliesConnector != null)
  Button.icon(
    ToggleConnectorMention(
      widget.draft,
      _handleRepliesConnector!,
    ),
    selected: _connectorMentioned,
    icon: PlotIcon.plug, // or appropriate connector icon
  ),
```

Add state tracking:
```dart
bool get _connectorMentioned {
  final connector = _handleRepliesConnector;
  if (connector == null) return false;
  return widget.draft.mentions?.contains(ActorId.fromUuid(connector.id)) ?? false;
}

PriorityTwist? get _handleRepliesConnector {
  final threadState = context.read<ThreadBloc>().state;
  // Find connector that created this thread and has handleReplies
  return threadState.threadTwists
      .where((t) => t.isSource && t.handleReplies && t.id == threadState.thread.createdBy)
      .firstOrNull;
}
```

- [ ] **Step 3: Add twist icon to bottom bar**

After the connector icon:

```dart
// Twist icon — shown when priority has twists
if (_hasTwists)
  Button.icon(
    _selectedTwist != null
        ? ToggleTwistMention(widget.draft, _selectedTwist!)
        : PickTwistMention(widget.draft),
    selected: _selectedTwist != null,
    icon: PlotIcon.twist,
  ),
```

Add state for twist default (on if last note mentioned/was-from a twist):
```dart
ActorId? _selectedTwist; // set in initState based on last note in thread

bool get _hasTwists {
  final threadState = context.read<ThreadBloc>().state;
  return threadState.threadTwists.where((t) => !t.isSource).isNotEmpty;
}
```

- [ ] **Step 4: Create ToggleConnectorMention and PickTwistMention commands**

These should be simple commands that add/remove the connector/twist ID from the draft note's `mentions` field.

`PickTwistMention` extends `ShowCommands` and shows a picker of available twists (single select). On selection, adds to `mentions` and sets `_selectedTwist`.

`ToggleTwistMention` toggles the twist off (removes from `mentions`, clears `_selectedTwist`).

- [ ] **Step 5: Commit**
```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "flutter: add connector/twist icons to NoteEditor bottom bar"
```

---

### Task 28: Update _finalizeNoteDraft

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Update _finalizeNoteDraft for new model**

Replace the current implementation:

```dart
Future<Note> _finalizeNoteDraft(String body, {bool alt = false}) async {
  _finalized = true;

  final activityBloc = context.read<ThreadBloc>();
  final replyTo = activityBloc.state.replyTo;

  // When replying to a restricted note, auto-restrict the reply
  final replyRestricted = replyTo != null && replyTo.isPrivate;
  final replyAccessContacts = replyRestricted
      ? <ActorId>{replyTo.authorId, ...?replyTo.accessContacts}.toList()
      : null;

  // Merge active twist mentions (connector + twist)
  final activeTwistMentions = _getActiveTwistMentions();

  Note note = widget.draft.copyWith(
    content: body.isEmpty ? null : body,
    draft: false,
    reNoteId: replyTo?.id,
    addMentions: activeTwistMentions.isNotEmpty ? activeTwistMentions : null,
    accessContacts: widget.viewerMode || replyRestricted
        ? Value(replyAccessContacts ?? [])
        : const Value.absent(),
  );

  if (alt && !note.isAssignedTo(Base.actorId)) {
    note = note.assignTo(Base.actorId);
  }

  return note;
}
```

- [ ] **Step 2: Update _getActiveTwistMentions**

This method should stay mostly the same — it already returns twist/connector IDs from `threadTwists`. Just ensure the connector mention is included when the connector toggle is on:

```dart
List<ActorId> _getActiveTwistMentions() {
  if (widget.isNewThreadMode) return const [];
  final mentions = <ActorId>[];
  
  // Connector mention
  if (_connectorMentioned && _handleRepliesConnector != null) {
    mentions.add(ActorId.fromUuid(_handleRepliesConnector!.id));
  }
  
  // Twist mention
  if (_selectedTwist != null) {
    mentions.add(_selectedTwist!);
  }
  
  return mentions;
}
```

- [ ] **Step 3: Commit**
```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "flutter: update finalizeNoteDraft for access model"
```

---

### Task 29: Access names display below lock icon

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart` (or the thread header area)

- [ ] **Step 1: Add names display**

Following the pattern used for assigned tag names, show access_contacts names below the lock icon when the thread is restricted (non-viewer priorities) or has added viewers (viewer priorities).

This requires resolving contact_ids to names. Use the same pattern as assigned tag name resolution.

Look at how assigned tag names are displayed — likely a widget that takes a list of ActorIds and shows comma-separated names. Reuse that widget for access_contacts.

- [ ] **Step 2: Commit**
```bash
git add apps/plot/lib/widget/
git commit -m "flutter: show access_contacts names below lock icon"
```

---

### Task 30: Update new thread bottom bar

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Add lock icon to new thread bottom bar**

In `_buildNewThreadBottomBar()`, add the lock icon for members in shared priorities:

```dart
// Lock icon for new threads
if (!widget.viewerMode && _isSharedPriority)
  Button.icon(
    _isViewerPriority
        ? PickThreadAccess(widget.draft) // modal for viewer priorities
        : ToggleThreadAccess(widget.draft), // toggle for non-viewer priorities
    selected: _isViewerPriority ? true : widget.draft.access == 'restricted',
  ),
```

Note: For new threads, the lock operates on the Thread object's access field, not the Note's access_contacts. Create `ToggleThreadAccess` and `PickThreadAccess` commands that update the thread's access.

- [ ] **Step 2: Commit**
```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "flutter: add lock icon to new thread bottom bar"
```

---

### Task 31: Update remaining Flutter references

- [ ] **Step 1: Search for remaining private references**

```bash
grep -rn '\.private\b\|\.private =' apps/plot/lib/ --include='*.dart' | grep -v '.g.dart' | grep -v 'generated'
```

- [ ] **Step 2: Fix all found references**

Common patterns:
- `note.private` → `note.isPrivate`
- `thread.private` → `thread.isPrivate`
- `copyWith(private: ...)` → `copyWith(accessContacts: Value(...))`
- `private: true` in note creation → `accessContacts: []`
- `widget.draft.private` → `widget.draft.isPrivate`

- [ ] **Step 3: Run flutter analyze**

```bash
cd apps/plot && flutter analyze lib/
```

- [ ] **Step 4: Commit**
```bash
git add apps/plot/lib/
git commit -m "flutter: fix remaining private references for visibility redesign"
```

---

### Task 32: Update global commands

**Files:**
- Modify: `apps/plot/lib/command/global.dart`
- Modify: `apps/plot/lib/command/navigation.dart`

- [ ] **Step 1: Check and update global.dart**

The git status shows `global.dart` is modified. Check for any private-related commands and update them.

- [ ] **Step 2: Check and update navigation.dart**

The git status shows `navigation.dart` is modified. Check for any private-related navigation logic.

- [ ] **Step 3: Commit**
```bash
git add apps/plot/lib/command/
git commit -m "flutter: update global and navigation commands for visibility redesign"
```

---

### Task 33: Update AGENTS.md thread visibility documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update Thread Visibility Rules section**

Replace the `Thread Visibility Rules` section in AGENTS.md that references `a.private` and `mentioned_in_thread()` with the new access-based filter:

```sql
-- Required visibility filters when joining thread_unread with thread:
AND t.archived_at IS NULL
AND (t.draft = FALSE OR t.created_by = :userId)
AND (CASE
    WHEN t.access = 'public' THEN TRUE
    WHEN t.created_by = :userId THEN TRUE
    WHEN t.access = 'members' AND :userRole = 'member' THEN TRUE
    WHEN "user".user_contact_id(:userId) = ANY(t.access_contacts) THEN TRUE
    ELSE FALSE
END)
```

- [ ] **Step 2: Update the libs/db/AGENTS.md thread visibility section too**

The database AGENTS.md has a similar section. Update it to match.

- [ ] **Step 3: Commit**
```bash
git add AGENTS.md libs/db/AGENTS.md
git commit -m "docs: update thread visibility rules for access model"
```

---

### Task 34: Saved note lock icon hover (viewer priorities)

**Files:**
- Modify: `apps/plot/lib/widget/note.dart` (or the widget that renders saved notes)

- [ ] **Step 1: Add hover-only lock icon on public threads in viewer priorities**

In the note rendering widget, when the thread is public in a viewer priority, show the lock icon only on hover. This allows users to re-restrict the thread.

Look at how other hover-only UI elements are implemented in the codebase and follow the same pattern.

- [ ] **Step 2: Commit**
```bash
git add apps/plot/lib/widget/note.dart
git commit -m "flutter: show lock icon on hover for public threads in viewer priorities"
```

---

### Task 35: Final verification

- [ ] **Step 1: Run full lint**

```bash
pnpm lint
```

- [ ] **Step 2: Run flutter analyze**

```bash
cd apps/plot && flutter analyze lib/
```

- [ ] **Step 3: Verify database**

```bash
pnpm diff-schema-migrations
```

- [ ] **Step 4: Verify Twister build**

```bash
cd public/twister && pnpm build
```

- [ ] **Step 5: Run /finalize**

Execute the finalization checklist to verify backwards compatibility, error capture, and documentation.
