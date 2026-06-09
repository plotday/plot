# Groups with Email-Accepting Connections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user address a thread to a group and send it through an email-accepting connection (Gmail); the group is expanded to its member email contacts at connector dispatch, with group membership restricted to contacts that have an email so no send silently drops anyone.

**Architecture:** Three coordinated changes. (1) Server: require every group member to have an email, enforced only in user-facing group mutations. (2) Server: at create-link dispatch, expand `thread.groups` to member contact IDs (reusing the existing `expand_group_contacts` RPC) and merge into the connector recipient set — ephemeral, the thread is unchanged. (3) Flutter: the compose connection picker offers `addresses`-type (email) connections for a group and carries the group onto the target; the group member picker hides emailless contacts.

**Tech Stack:** PostgreSQL (Atlas migrations, plpgsql), Cloudflare Workers (Hono, Kysely, TypeScript, Vitest), Flutter (Dart, Bloc, Drift).

**Spec:** `docs/superpowers/specs/2026-06-09-groups-with-email-connections-design.md`

---

## Worktree & environment (read first)

All work happens in this worktree: `/Users/kris.braun/code/plot/.claude/worktrees/groups-email-connections` (branch `groups-email-connections`, based on clean `main`). Run all commands from the worktree root.

**CRITICAL — stale `$DATABASE_URL`:** `bash scripts/worktree-db` (Task 0) is run *after* this session started, so the ambient `$DATABASE_URL` is stale (points at the main repo's `54322`). Every DB command (migrations, types, and DB-backed Vitest runs) MUST override the URL from `.worktree-db`:

```bash
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"   # MUST print the worktree PORT, not 54322
```

Re-source/export in each shell that runs a DB command. The DB-backed Vitest tests `describe.skipIf(!DATABASE_URL)` — they silently skip if `DATABASE_URL` is unset, so you MUST export the worktree URL or the tests are a no-op.

---

### Task 0: Worktree database setup

**Files:** none (environment only)

- [ ] **Step 1: Provision the worktree's isolated Postgres with migrations applied**

Run:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/groups-email-connections
bash scripts/worktree-db
```
Expected: prints a PORT and applies all existing migrations; creates `.worktree-db`.

- [ ] **Step 2: Verify the DB URL resolves to the worktree port**

Run:
```bash
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "show port;"
```
Expected: prints the worktree PORT (e.g. `54337`), NOT `54322`.

- [ ] **Step 3: Baseline — schema/migrations in sync**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations
```
Expected: no differences.

---

## Part 1 — Group membership requires an email (server)

### Task 1: Reject group members without an email in user-facing mutations

**Files:**
- Modify: `libs/db/schema/60-functions/group.sql` (add helper at top; call it in `create_group` and `add_group_members`)
- Modify: `libs/db/schema/90-user-schema/84-save-group.sql` (call helper in the CREATE path)
- Modify (extend): `workers/api/src/state/save-contact-group.test.ts` (locate this file first with `git ls-files | grep save-contact-group`; it already contains `describe.skipIf(!DATABASE_URL)("save_group via rpcUser", ...)`)
- Generated: `libs/db/migrations/<timestamp>_group_member_email_required.sql`, `libs/db/src/types.ts`

- [ ] **Step 1: Write the failing tests**

Open `workers/api/src/state/save-contact-group.test.ts`. It already has a `withUser(fn)` helper (seeds a user + linked primary identity, rolls back) and a `save_group` describe block. Add these tests inside (or alongside) the existing `describe.skipIf(!DATABASE_URL)("save_group via rpcUser", ...)` block. They seed a second contact **without** an email and expect the save to be rejected:

```typescript
  it("rejects creating a group with a member that has no email", async () => {
    const clientGroupId = randomUUID();
    const emaillessContactId = randomUUID();
    await expect(
      withUser(async (trx, userId) => {
        // A contact with NO email (email column null).
        await sql`INSERT INTO contact (id, name) VALUES (${emaillessContactId}::uuid, 'No Email')`.execute(trx);
        return rpcUser(trx, "save_group", {
          user_id: userId,
          p_group: {
            id: clientGroupId,
            name: "Email Group",
            privacy: "open",
            member_contact_ids: [emaillessContactId],
          },
        });
      }),
    ).rejects.toThrow(/email/i);
  });

  it("creates a group when every member has an email", async () => {
    const clientGroupId = randomUUID();
    const memberId = randomUUID();
    const groupId = await withUser(async (trx, userId) => {
      await sql`INSERT INTO contact (id, name, email)
        VALUES (${memberId}::uuid, 'Has Email', ${`m-${memberId}@example.test`})`.execute(trx);
      return rpcUser(trx, "save_group", {
        user_id: userId,
        p_group: {
          id: clientGroupId,
          name: "Email Group",
          privacy: "open",
          member_contact_ids: [memberId],
        },
      });
    });
    expect(groupId).toBe(clientGroupId);
  });
```

If `sql` / `randomUUID` / `rpcUser` are not already imported in this file, add them (mirror `email-digest-query.test.ts`: `import { randomUUID } from "node:crypto";` and `import { sql, type Kysely } from "kysely";`, `rpcUser` from `"../rpc"`).

- [ ] **Step 2: Run the tests to verify the rejection test fails**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/api test -- save-contact-group
```
Expected: the "rejects creating a group with a member that has no email" test FAILS (current `save_group` accepts emailless members, so no error is thrown); the "creates a group when every member has an email" test passes.

- [ ] **Step 3: Add the shared validation helper**

In `libs/db/schema/60-functions/group.sql`, add this function at the very top of the file (before `create_group`). It must live in `60-functions/` because it reads the `contact` table:

```sql
-- Reject if any of the given contacts has no email address. Group membership
-- is restricted to emailable contacts so a group can always be sent through an
-- email-accepting connection (Gmail) and Plot's email notifications without
-- silently dropping anyone. Enforced only on user-facing member additions;
-- auto-maintained groups (team groups) populate group_member via triggers and
-- only ever add Plot users, who always have an email, so they are not checked.
CREATE OR REPLACE FUNCTION public.assert_group_members_have_email (p_contact_ids uuid[])
    RETURNS void
    LANGUAGE plpgsql
    STABLE
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF p_contact_ids IS NULL OR cardinality(p_contact_ids) = 0 THEN
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM contact
        WHERE id = ANY(p_contact_ids)
          AND (email IS NULL OR btrim(email) = '')
    ) THEN
        RAISE EXCEPTION 'All group members must have an email address';
    END IF;
END;
$function$;
```

- [ ] **Step 4: Call the helper in `create_group` and `add_group_members`**

In `libs/db/schema/60-functions/group.sql`, in `public.create_group`, add the check immediately before the member insert (before `IF cardinality(p_member_contact_ids) > 0 THEN`):

```sql
    PERFORM public.assert_group_members_have_email(p_member_contact_ids);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO group_member (group_id, contact_id)
        SELECT v_group_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;
```

In `public.add_group_members`, add the check immediately before the final insert (after the join-policy authorization block, before `INSERT INTO group_member ...`):

```sql
    PERFORM public.assert_group_members_have_email(p_contact_ids);

    INSERT INTO group_member (group_id, contact_id)
    SELECT p_group_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
```

(`add_group_members` is what `save_group`'s UPDATE path calls for `v_to_add`, so the rule covers adding members to an existing group automatically — and it checks only the newly-added set, so editing a legacy group with pre-existing emailless members never fails.)

- [ ] **Step 5: Call the helper in `save_group`'s CREATE path**

In `libs/db/schema/90-user-schema/84-save-group.sql`, in the CREATE branch, add the check before the member insert (before `IF cardinality(v_member_ids) > 0 THEN`):

```sql
        PERFORM public.assert_group_members_have_email(v_member_ids);

        IF cardinality(v_member_ids) > 0 THEN
            INSERT INTO group_member (group_id, contact_id)
            SELECT v_group_id, unnest(v_member_ids)
            ON CONFLICT DO NOTHING;
        END IF;
```

- [ ] **Step 6: Generate and apply the migration**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm gen-migration -- group_member_email_required
pnpm apply-migrations
```
Expected: a new migration appears under `libs/db/migrations/` containing the new function plus the `CREATE OR REPLACE` of `create_group`, `add_group_members`, and `save_group`; `apply-migrations` succeeds and auto-regenerates `libs/db/src/types.ts`.

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/api test -- save-contact-group
```
Expected: both new tests PASS (emailless member rejected with a message matching `/email/i`; all-email group created).

- [ ] **Step 8: Verify schema/migrations in sync and commit**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations
git add libs/db/schema libs/db/migrations libs/db/src/types.ts workers/api/src/state/save-contact-group.test.ts
git commit -m "feat(groups): require an email on all user-added group members"
```
Expected: `diff-schema-migrations` shows no differences; commit succeeds.

---

## Part 3 — Expand groups to member emails at dispatch (server)

### Task 2: Expand `thread.groups` into the connector recipient set

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts` (add `expandGroupsToContactIds` helper; read `threadData.groups`; use the expanded set in the create-link dispatch)
- Test: `workers/api/src/app/sync/expand-groups-to-contact-ids.test.ts` (new — DB-backed)

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/app/sync/expand-groups-to-contact-ids.test.ts`:

```typescript
import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { expandGroupsToContactIds } from "./threads";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/**
 * Seed a user (+linked primary contact), a group the user owns, two member
 * contacts with emails, then run `fn` with the trx and ids and roll back.
 */
async function withGroup<T>(
  fn: (
    trx: Kysely<DB>,
    ids: {
      userId: string;
      groupId: string;
      memberA: string;
      memberB: string;
    },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const selfContact = randomUUID();
  const groupId = randomUUID();
  const memberA = randomUUID();
  const memberB = randomUUID();
  const email = `wf-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", email)
        VALUES (${selfContact}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${userId}::uuid, ${selfContact}::uuid, true, true)`.execute(trx);
      // Group owned by the user (admin), with two emailed members.
      await sql`INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (${groupId}::uuid, 'Marketing', 'private', 'open', ${userId}::uuid)`.execute(trx);
      await sql`INSERT INTO group_admin (group_id, user_id)
        VALUES (${groupId}::uuid, ${userId}::uuid)`.execute(trx);
      await sql`INSERT INTO contact (id, name, email) VALUES
        (${memberA}::uuid, 'Alice', 'alice@example.test'),
        (${memberB}::uuid, 'Bob', 'bob@example.test')`.execute(trx);
      await sql`INSERT INTO group_member (group_id, contact_id) VALUES
        (${groupId}::uuid, ${memberA}::uuid),
        (${groupId}::uuid, ${memberB}::uuid)`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
      captured = await fn(trx, { userId, groupId, memberA, memberB });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

describe.skipIf(!DATABASE_URL)("expandGroupsToContactIds", () => {
  it("expands a group to its member contact ids", async () => {
    const ids = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [], [ids.groupId]),
    );
    expect(ids.length).toBe(2);
  });

  it("dedups members already present as direct contacts", async () => {
    const result = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [ids.memberA], [ids.groupId]).then(
        (out) => ({ out, memberA: ids.memberA, memberB: ids.memberB }),
      ),
    );
    expect(result.out.sort()).toEqual([result.memberA, result.memberB].sort());
  });

  it("returns direct contacts unchanged when no groups are passed", async () => {
    const result = await withGroup((trx, ids) =>
      expandGroupsToContactIds(trx, ids.userId, [ids.memberA], []),
    );
    expect(result).toEqual([result[0]]);
    expect(result.length).toBe(1);
  });

  it("skips a group the user cannot address without throwing", async () => {
    // A private group the user is neither admin nor member of -> expand_group_contacts
    // RAISEs (P0001); the helper must skip it and report no unexpected error.
    const errors: unknown[] = [];
    const out = await withGroup(async (trx, ids) => {
      const otherUser = randomUUID();
      const foreignGroup = randomUUID();
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO "user" (id, email) VALUES (${otherUser}::uuid, ${`o-${otherUser}@example.test`})`.execute(trx);
      await sql`INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (${foreignGroup}::uuid, 'Private', 'private', 'private', ${otherUser}::uuid)`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
      return expandGroupsToContactIds(
        trx,
        ids.userId,
        [ids.memberA],
        [foreignGroup],
        (e) => errors.push(e),
      );
    });
    expect(out).toEqual([out[0]]); // only the direct contact survives
    expect(errors).toHaveLength(0); // permission RAISE (P0001) is expected, not reported
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/api test -- expand-groups-to-contact-ids
```
Expected: FAIL to compile/import — `expandGroupsToContactIds` is not exported from `./threads`.

- [ ] **Step 3: Implement `expandGroupsToContactIds` in `threads.ts`**

In `workers/api/src/app/sync/threads.ts`, ensure these imports exist at the top (add what's missing — `createDb` is already imported; `rpc` and the Kysely/DB types likely are not):

```typescript
import { type Kysely } from "kysely";
import { rpc } from "../../rpc";
import { type DB } from "../../db";
```

Then add this exported function near the top of the file (after imports, before the route definitions):

```typescript
/**
 * Expand any addressed groups to their member contact ids and merge them with
 * the directly-addressed contacts (deduped). Used by the create-link dispatch
 * so email-accepting connectors receive a group's members as recipients.
 *
 * Reuses the permission-gated `expand_group_contacts` RPC. A group the caller
 * can no longer address (or a missing group) RAISEs `P0001`, which is expected
 * and skipped silently; any other failure is forwarded to `onUnexpectedError`.
 * Expansion is ephemeral — callers do not write the result back to the thread.
 */
export async function expandGroupsToContactIds(
  db: Kysely<DB>,
  userId: string,
  directContactIds: string[],
  groupIds: string[],
  onUnexpectedError?: (error: unknown) => void,
): Promise<string[]> {
  const ids = new Set<string>(directContactIds);
  for (const groupId of groupIds) {
    try {
      const memberIds = (await rpc(db, "expand_group_contacts", {
        p_user_id: userId,
        p_group_id: groupId,
      })) as string[] | null;
      for (const id of memberIds ?? []) ids.add(id);
    } catch (error) {
      const code = (error as { code?: string } | null)?.code;
      if (code !== "P0001") onUnexpectedError?.(error);
    }
  }
  return [...ids];
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/api test -- expand-groups-to-contact-ids
```
Expected: all four tests PASS.

- [ ] **Step 5: Wire the helper into the create-link dispatch**

In `workers/api/src/app/sync/threads.ts`, in the create-link dispatch block, add a snapshot of the groups alongside the existing `dispatchContactIds` snapshot (right after the `dispatchContactIds` declaration, ~line 879-881):

```typescript
    const dispatchGroupIds: string[] = Array.isArray(threadData.groups)
      ? (threadData.groups as string[])
      : [];
```

Then, inside the `waitUntil` async block, replace the contact-resolution lead-in. Change this:

```typescript
          const contacts: Array<{ id: string; type: "contact" | "user"; email: string | null; name: string | null }> = [];
          if (dispatchContactIds.length > 0) {
            const rows = await db
              .selectFrom("contact as c")
              .leftJoin("user_contact as uc", (join) =>
                join
                  .onRef("uc.contact_id", "=", "c.id")
                  .on("uc.user_id", "=", userId)
                  .on("uc.linked", "=", true)
                  .on("uc.archived_at", "is", null)
              )
              .select([
                "c.id",
                "c.email",
                "c.name",
                "uc.user_id as linked_user_id",
              ])
              .where("c.id", "in", dispatchContactIds)
              .execute();
```

to this (expand groups into the resolved set, then query the union):

```typescript
          const contacts: Array<{ id: string; type: "contact" | "user"; email: string | null; name: string | null }> = [];
          const resolveContactIds = await expandGroupsToContactIds(
            db,
            userId,
            dispatchContactIds,
            dispatchGroupIds,
            (error) => {
              console.error("[sync/threads] expand_group_contacts failed:", error);
              c.var.tracker.captureException(error as Error);
            },
          );
          if (resolveContactIds.length > 0) {
            const rows = await db
              .selectFrom("contact as c")
              .leftJoin("user_contact as uc", (join) =>
                join
                  .onRef("uc.contact_id", "=", "c.id")
                  .on("uc.user_id", "=", userId)
                  .on("uc.linked", "=", true)
                  .on("uc.archived_at", "is", null)
              )
              .select([
                "c.id",
                "c.email",
                "c.name",
                "uc.user_id as linked_user_id",
              ])
              .where("c.id", "in", resolveContactIds)
              .execute();
```

Leave the rest of the loop (the `for (const row of rows)` author-exclusion block, the `draft` object, and the `wrapper.dispatch(...)` call) unchanged.

- [ ] **Step 6: Typecheck/lint and commit**

Run:
```bash
pnpm --filter @plotday/api lint
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/api test -- expand-groups-to-contact-ids
git add workers/api/src/app/sync/threads.ts workers/api/src/app/sync/expand-groups-to-contact-ids.test.ts
git commit -m "feat(groups): expand addressed groups to member emails at create-link dispatch"
```
Expected: lint clean; tests pass; commit succeeds.

---

## Part 2 — Offer email connections for a group (Flutter compose)

### Task 3: `connectionsForRoster` offers `addresses`-type connectors for groups

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart:1127-1158` (`connectionsForRoster`)
- Test: `apps/plot/test/state/compose_targets_test.dart` (add a test using the existing `_insertConnector` / `_insertActor` helpers)

- [ ] **Step 1: Write the failing test**

In `apps/plot/test/state/compose_targets_test.dart`, inside the existing `group('ComposeTargetsBloc materialization (in-memory store)', ...)` block (which already defines `_insertConnector`, `_insertActor`, and the `setUp` that builds an in-memory `Store`), add:

```dart
    test('connectionsForRoster offers email (addresses) connectors for a group '
        'and carries the group onto the target, excluding contacts-type DMs',
        () async {
      // An email (addresses) connector and a contacts-type DM connector.
      await _insertConnector(
        store,
        name: 'Gmail (kris@plot.day)',
        linkType: 'email',
        targets: 'addresses',
      );
      await _insertConnector(
        store,
        name: 'Slack (Acme)',
        linkType: 'dm',
        targets: 'contacts',
      );

      final prefs = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      final bloc = ComposeTargetsBloc(prefs);
      addTearDown(bloc.close);
      await bloc.refresh();

      final groupId = Uuid.generate();
      final results = await bloc.connectionsForRoster(
        contacts: const [],
        groups: [groupId],
        inviteEmails: const [],
      );

      final connectorTargets =
          results.where((t) => t.target != null).toList();
      // The addresses connector is offered...
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'addresses'),
        isTrue,
      );
      // ...and carries the group through to the created thread.
      final addr = connectorTargets
          .firstWhere((t) => t.target!.compose.targets == 'addresses');
      expect(addr.groups, contains(groupId));
      // The contacts-type DM connector is NOT offered for a group.
      expect(
        connectorTargets.any((t) => t.target!.compose.targets == 'contacts'),
        isFalse,
      );
    });
```

If `_insertConnector` does not already accept a `targets:` named arg in this test file, check its definition near the top of the file and use whatever parameter sets `compose.targets` (the existing "base list" test calls `_insertConnector(store, name: 'Gmail (kris@plot.day)', linkType: 'email', targets: 'addresses')`, so the `targets` arg exists).

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd apps/plot && flutter test test/state/compose_targets_test.dart --plain-name 'connectionsForRoster offers email'
```
Expected: FAIL — currently `connectionsForRoster` skips all connector targets when `groups` is non-empty, so `connectorTargets` is empty and the `addresses` assertion fails.

- [ ] **Step 3: Edit `connectionsForRoster`**

In `apps/plot/lib/state/compose_targets.dart`, replace the `if (groups.isEmpty) { ... }` block (lines ~1144-1152) with an unconditional loop whose predicate keeps email (`addresses`) connectors for groups while preserving the full DM set when no group is selected, and pass `groups` onto the target:

```dart
    // DM-type connectors. With no group, offer all DM-type connectors
    // (contacts + addresses) as before. With a group selected, offer only
    // email-accepting (addresses) connectors — the group is expanded to member
    // emails at dispatch, and every member is guaranteed to have an email.
    // contacts-type DMs (e.g. Slack) are deferred until per-platform
    // reachability is modelled.
    for (final t in ctx.createTargets.where(
      (t) => t.isDmType && (groups.isEmpty || t.compose.targets == 'addresses'),
    )) {
      options.add(ComposeTarget.connector(
        t,
        connectionCount: ctx.connectionCount(t),
        contacts: contacts,
        groups: groups,
      ));
    }
```

Also update the method's leading doc comment (line ~1127) from "Plot per applicable scope + DM-type connectors (only when no formal group)." to:

```dart
  /// Connections that can reach [contacts]/[groups]/[inviteEmails], MRU-first.
  /// Plot per applicable scope, plus DM-type connectors — all DM types when no
  /// group is selected, email (addresses) connectors only when a group is.
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd apps/plot && flutter test test/state/compose_targets_test.dart --plain-name 'connectionsForRoster offers email'
```
Expected: PASS.

- [ ] **Step 5: Analyze, run the full compose test file, and commit**

Run:
```bash
cd apps/plot && flutter analyze lib/state/compose_targets.dart test/state/compose_targets_test.dart
cd apps/plot && flutter test test/state/compose_targets_test.dart
git add apps/plot/lib/state/compose_targets.dart apps/plot/test/state/compose_targets_test.dart
git commit -m "feat(groups): offer email connections for a group in the compose picker"
```
Expected: analyze clean; all compose-targets tests pass; commit succeeds.

---

## Part 1 (Flutter) — Hide emailless contacts in the group member picker

### Task 4: `requireEmail` mode for the share picker; enable it for group editing

**Files:**
- Modify: `apps/plot/lib/command/share.dart` (add `actorHasEmail` helper; add `requireEmail` param to `buildSharedSelectionCommands` and `_SelectionShareSuggestionsGroup`; filter in `list()`; add `requireEmail` to the `PickShared` factory)
- Modify: `apps/plot/lib/widget/form.dart` (`FormShareSelect`: add `requireEmail`; pass to `PickShared`)
- Modify: `apps/plot/lib/command/group.dart` (`EditGroup`: set `requireEmail: true` on the members `FormShareSelect`)
- Test: `apps/plot/test/command/share_email_filter_test.dart` (new — unit test for `actorHasEmail`)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/share_email_filter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/share.dart';
import 'package:plot/store/actor.dart';

ActorRow _actor({String? email}) => ActorRow(
      id: ActorId.fromUuid(Uuid.generate()),
      type: ActorType.contact,
      name: 'Test',
      email: email,
      avatarUrl: null,
      self: false,
      inviteable: true,
    );

void main() {
  group('actorHasEmail', () {
    test('true when the actor has a non-empty email', () {
      expect(actorHasEmail(Actor(_actor(email: 'a@example.test'))), isTrue);
    });
    test('false when the actor has no email', () {
      expect(actorHasEmail(Actor(_actor(email: null))), isFalse);
    });
    test('false when the actor email is blank', () {
      expect(actorHasEmail(Actor(_actor(email: '   '))), isFalse);
    });
  });
}
```

Note: construct `ActorRow` with whatever its generated constructor requires — open `apps/plot/lib/store/actor.dart` and match the required fields (the columns shown are `id`, `type`, `name`, `email`, `avatarUrl`, `self`, `inviteable`, plus any `SyncableTable`/`CreatedTable`/`DeletableTable` columns with defaults). If direct `ActorRow` construction is awkward, instead seed via the in-memory store the way `compose_targets_test.dart`'s `_insertActor` does and fetch with `Actor.getOne`. Keep the three assertions identical.

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd apps/plot && flutter test test/command/share_email_filter_test.dart
```
Expected: FAIL — `actorHasEmail` is not defined in `share.dart`.

- [ ] **Step 3: Add the `actorHasEmail` helper and `requireEmail` filtering**

In `apps/plot/lib/command/share.dart`, add a top-level helper (near `isValidShareEmail`, ~line 181):

```dart
/// Whether [actor] can be added to a group. Group membership is restricted to
/// emailable contacts so a group is always sendable through an email-accepting
/// connection (and Plot's email notifications) without silently dropping anyone.
bool actorHasEmail(Actor actor) =>
    actor.email != null && actor.email!.trim().isNotEmpty;
```

Add a `bool requireEmail = false` parameter to `buildSharedSelectionCommands` (in its named-parameter list, ~line 192-202) and pass it into the `_SelectionShareSuggestionsGroup(...)` constructor call (~line 291-299):

```dart
      _SelectionShareSuggestionsGroup(
        selection: selection,
        excludeActorIds: [...sharedActorIds, ...inThreadActorIds],
        excludeGroupIds: selection.groups.toSet(),
        onUpdate: onUpdate,
        candidates: candidates,
        priority: priority,
        requireEmail: requireEmail,
        title: 'Share with',
      ),
```

Add the field + constructor param to `_SelectionShareSuggestionsGroup` (~line 308-324):

```dart
  _SelectionShareSuggestionsGroup({
    required this.selection,
    required this.excludeActorIds,
    required this.excludeGroupIds,
    required this.onUpdate,
    required this.candidates,
    required this.priority,
    this.requireEmail = false,
    required String title,
  }) : super(title: title);

  final SharedSelection selection;
  final List<ActorId> excludeActorIds;
  final Set<Uuid> excludeGroupIds;
  final Future<void> Function(SharedSelection) onUpdate;
  final ShareCandidatesCache candidates;
  final Priority? priority;
  final bool requireEmail;
```

In `_SelectionShareSuggestionsGroup.list()`, filter out emailless actors when `requireEmail` is set. Change the `ActorShareCandidate` case (~line 333-337) to:

```dart
        case ActorShareCandidate(:final actor):
          if (excludedActorIds.contains(actor.id)) continue;
          if (requireEmail && !actorHasEmail(actor)) continue;
          commands.add(
            ShareSelectionActor(selection, actor, onUpdate: onUpdate),
          );
```

- [ ] **Step 4: Thread `requireEmail` through `PickShared` and `FormShareSelect`**

In `apps/plot/lib/command/share.dart`, add `bool requireEmail = false` to the `PickShared` factory parameter list (~line 512-522) and forward it to `buildSharedSelectionCommands` in the `commandsBuilder` (~line 534-545):

```dart
      commandsBuilder: (context) => buildSharedSelectionCommands(
        selection: ref[0],
        onUpdate: onChange,
        candidates: cache,
        priority: priority,
        injectSelf: injectSelf,
        threadMemberIds: threadMemberIds,
        sharedSectionTitle: sharedSectionTitle,
        threadSectionTitle: threadSectionTitle,
        prompt: prompt,
        requireEmail: requireEmail,
      ),
```

In `apps/plot/lib/widget/form.dart`, add `requireEmail` to `FormShareSelect` (constructor ~line 1403-1409 and a field), and pass it into the `PickShared(...)` call inside `activate` (~line 1446-1448):

```dart
  FormShareSelect({
    required super.key,
    super.label,
    this.placeholder,
    this.priority,
    this.requireEmail = false,
    SharedSelection? initialValue,
  }) : _value = initialValue ?? const SharedSelection();

  final String? placeholder;
  final Priority? priority;

  /// When true, contacts without an email are hidden from the suggestion list
  /// (used by group editing — group members must be emailable).
  final bool requireEmail;
```

And in `activate`:

```dart
    await PickShared(
      selection: _value,
      priority: priority,
      requireEmail: requireEmail,
      title: label ?? key,
      onUpdate: (next) async {
        // ... unchanged ...
      },
    ).run(context);
```

- [ ] **Step 5: Enable `requireEmail` for group editing**

In `apps/plot/lib/command/group.dart`, in `EditGroup.run`, set the flag on the members field (~line 285-290):

```dart
      FormShareSelect(
        key: 'members',
        label: 'Members',
        placeholder: 'Add people and groups',
        requireEmail: true,
        initialValue: SharedSelection(contacts: initialMemberContactIds),
      ),
```

(The `new_thread.dart` `FormShareSelect` call site is left untouched — `requireEmail` defaults to `false`, preserving thread-sharing behavior.)

- [ ] **Step 6: Run the test, analyze, and commit**

Run:
```bash
cd apps/plot && flutter test test/command/share_email_filter_test.dart
cd apps/plot && flutter analyze lib/command/share.dart lib/widget/form.dart lib/command/group.dart test/command/share_email_filter_test.dart
git add apps/plot/lib/command/share.dart apps/plot/lib/widget/form.dart apps/plot/lib/command/group.dart apps/plot/test/command/share_email_filter_test.dart
git commit -m "feat(groups): hide emailless contacts in the group member picker"
```
Expected: test passes; analyze clean; commit succeeds.

---

## Task 5: Documentation and finalization

**Files:**
- Modify: `docs/updates.md`
- Modify: `docs/features.md`

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, add a bullet to the top (current, unreleased) section, in plain user language:

```markdown
- You can now send a thread to a group through email connections like Gmail — Plot expands the group to its members' email addresses automatically. Group members must have an email address.
```

- [ ] **Step 2: Update the feature list**

In `docs/features.md`, find the groups section and note that groups can be used with email-accepting connections (Gmail), expanding to member emails on send, and that group members are required to have an email. Match the surrounding style.

- [ ] **Step 3: Run the finalization checks**

Run:
```bash
# Flutter
cd apps/plot && flutter analyze
# Workers / DB lint (from worktree root)
cd /Users/kris.braun/code/plot/.claude/worktrees/groups-email-connections
pnpm --filter @plotday/api lint
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm --filter @plotday/db run lint
pnpm diff-schema-migrations
```
Expected: `flutter analyze` clean; api lint clean; `db:lint` clean (types committed in Task 1); `diff-schema-migrations` shows no differences.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: groups can be sent via email connections"
```

- [ ] **Step 5: Manual verification (run-app)**

Use the `run-app` skill to verify end to end:
1. Create a group with two contacts that have emails; confirm a contact **without** an email is not offered in the member picker.
2. Start a thread, address it to the group, open the connection picker, and confirm Gmail (and any email connection) is offered.
3. Send via Gmail; confirm the outgoing message is addressed to the group members' email addresses.

---

## Self-review notes (for the executor)

- **Spec coverage:** Part 1 (membership rule) → Tasks 1 & 4; Part 2 (compose picker) → Task 3; Part 3 (dispatch expansion) → Task 2; docs/finalize → Task 5. All spec sections covered.
- **No `contacts`-type DM for groups:** enforced in Task 3's predicate (`groups.isEmpty || t.compose.targets == 'addresses'`) and asserted in its test.
- **Auto-maintained groups untouched:** validation lives only in `create_group` / `add_group_members` / `save_group` (user-facing), never on `group_member` triggers (Task 1, Step 3 comment).
- **Ephemeral expansion:** Task 2 never writes to `thread.contacts`/`thread.groups`; it only builds the in-memory recipient set.
- **Type names are consistent across tasks:** `expandGroupsToContactIds(db, userId, directContactIds, groupIds, onUnexpectedError?)`, `assert_group_members_have_email(p_contact_ids uuid[])`, `actorHasEmail(Actor)`, `requireEmail` flag.
