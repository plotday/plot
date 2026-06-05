# OAuth Draft Connection Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a connection count as "active" only once the user has committed it (chosen channels), so abandoning an OAuth flow leaves nothing that blocks re-connecting — and an OAuth connection stays a `draft` until the user finishes setup.

**Architecture:** Today, OAuth connectors flip `twist_instance.draft = false` the instant OAuth returns — before the user picks channels — via `_activateAfterOAuth → _activateSource → activateDraft`. If the user backs out at channel selection, the result is an activated connection with **zero channels** that is hidden from the Active-connections list (`enabled_count == 0` filter) yet still trips the backend dedup guard, producing an invisible-but-blocking "This account is already connected" orphan. We fix this on two fronts: (1) **unify the definition of "active connection"** (`draft = false AND archived_at IS NULL AND ≥1 enabled channel`) across the dedup guard and the summary endpoint, which immediately unblocks existing and future orphans; (2) **defer OAuth activation** to the channel-commit step so abandoned OAuth leaves a `draft` that the existing draft-cleanup deletes — restoring `draft`'s real meaning ("uncommitted setup").

**Tech Stack:** TypeScript Cloudflare Workers (`workers/api`), Kysely, Flutter/Dart (`apps/plot`), Vitest, local Postgres via `$DATABASE_URL`.

---

## Background / Evidence (read before starting)

- Dedup guard: `workers/api/src/twist/tools/integrations.ts:2735-2766`. Filters `ti.archived_at is null` but **not** `ti.draft` and **not** enabled-channel count. Throws `AUTH_ACCOUNT_DUPLICATE_ERROR` → user message at `integrations.ts:4346-4350`.
- Active-list filter: `apps/plot/lib/command/twist.dart:391-392` (`removeWhere enabledCount == 0`).
- Summary endpoint: `workers/api/src/app/twists.ts:194-277` (`/sources/summary`) — no `draft` filter; computes `enabled_count` from `channel WHERE enabled = true`.
- OAuth activate-on-return: `apps/plot/lib/command/twist.dart:1952-1960` (`onSuccess → _activateAfterOAuth`), `2259-2310` (`_activateAfterOAuth → _activateSource`), `2312-2326` (`_activateSource → activateDraft + clearDraft`).
- Post-OAuth channel modal: `apps/plot/lib/command/twist.dart:230-250` (ManageConnections opens `EditSource(isNewlyActivated: true)` on the activated instance).
- EditSource save: `SaveSource.run` at `apps/plot/lib/command/twist.dart:3765-3857` — assumes an **already-active** instance (calls `applyChannelsBatch`, not `activateDraft`).
- No-provider path (the model to mirror): connects on a draft, shows channels via `FormChannelList`/`SetupSourceWidget`, then activates only on the explicit "Add connection" button (`_ActivateNoProviderSource`) at `twist.dart:2192-2225`, `3468-3525`.
- `activateDraft` requires `draft = true` (`workers/api/src/twist/management.ts:830-840`); for `is_source` twists it checks limits at channel-enable time (`management.ts:891-897`).
- Test harness reality: `workers/api/src/**/*.test.ts` use **mocked Kysely stubs**, not a live DB (see `src/app/sync/notes.test.ts`, `src/twist/tools/__tests__/plot.test.ts`). So SQL `where`-clause semantics are verified via a **seeded local-DB script** + run-app, while pure/extractable logic is unit-tested.

---

## Task 1: Unify the "active connection" definition in the dedup guard (backend)

This is the highest-leverage change: it makes the dedup guard ignore connections that are not committed-and-active, which **immediately unblocks the user's existing orphan and any future ones**, independent of the Flutter change.

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts:2742-2766`
- Test (new): `workers/api/src/twist/tools/active-connection.test.ts`
- Create: `workers/api/src/twist/tools/active-connection.ts` (extracted pure predicate + shared SQL doc)

- [ ] **Step 1: Write the failing unit test for the extracted predicate**

Create `workers/api/src/twist/tools/active-connection.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { isActiveConnection } from "./active-connection";

describe("isActiveConnection", () => {
  it("is active: committed, not archived, has an enabled channel", () => {
    expect(
      isActiveConnection({ draft: false, archived: false, enabledChannelCount: 1 }),
    ).toBe(true);
  });

  it("not active: still a draft (OAuth not yet committed)", () => {
    expect(
      isActiveConnection({ draft: true, archived: false, enabledChannelCount: 1 }),
    ).toBe(false);
  });

  it("not active: archived", () => {
    expect(
      isActiveConnection({ draft: false, archived: true, enabledChannelCount: 1 }),
    ).toBe(false);
  });

  it("not active: zero enabled channels (orphaned OAuth with no channels picked)", () => {
    expect(
      isActiveConnection({ draft: false, archived: false, enabledChannelCount: 0 }),
    ).toBe(false);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd workers/api && pnpm test active-connection`
Expected: FAIL — `Cannot find module './active-connection'`.

- [ ] **Step 3: Create the predicate module**

Create `workers/api/src/twist/tools/active-connection.ts`:

```typescript
/**
 * The single definition of an "active connection" shared across the codebase:
 * a connection the user has COMMITTED to and that is doing something.
 *
 *   active  ≡  draft = false  AND  archived_at IS NULL  AND  >= 1 enabled channel
 *
 * This must stay in sync with:
 *   - the dedup guard SQL in integrations.ts (Integrations.storeAuthorization)
 *   - GET /sources/summary in app/twists.ts (the Active-connections list source)
 *   - the Flutter Active-list filter in apps/plot/lib/command/twist.dart
 *
 * `draft = false` keeps an in-progress OAuth setup from counting; the
 * enabled-channel requirement keeps a committed-but-channel-less orphan from
 * counting (and from silently blocking a re-connect of the same account).
 */
export function isActiveConnection(input: {
  draft: boolean;
  archived: boolean;
  enabledChannelCount: number;
}): boolean {
  return !input.draft && !input.archived && input.enabledChannelCount > 0;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd workers/api && pnpm test active-connection`
Expected: PASS (4 tests).

- [ ] **Step 5: Apply the unified definition to the dedup guard SQL**

In `workers/api/src/twist/tools/integrations.ts`, replace the dedup query (currently `2749-2759`) so it only counts **active** connections. Add the `draft = false` filter and an enabled-channel existence check:

```typescript
          const duplicate = await this.db
            .selectFrom("twist_instance_connection as tic")
            .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
            .select("tic.twist_instance_id")
            .where("ti.twist_id", "=", selfInstance.twist_id)
            .where("ti.archived_at", "is", null)
            .where("ti.draft", "=", false) // ignore in-progress (uncommitted) setups
            .where("tic.user_id", "=", contact.user_id)
            .where("tic.provider", "=", tokenInfo.provider)
            .where("tic.actor_id", "=", actor.id)
            .where("tic.twist_instance_id", "!=", this.twistInstanceId)
            // Only an ACTIVE connection (>=1 enabled channel) blocks a re-connect.
            // A committed-but-channel-less orphan must not silently block the user.
            .where((eb) =>
              eb.exists(
                eb
                  .selectFrom("channel as ch")
                  .select("ch.id")
                  .whereRef("ch.twist_instance_id", "=", "tic.twist_instance_id")
                  .where("ch.enabled", "=", true),
              ),
            )
            .executeTakeFirst();
```

Update the comment block above (currently `2735-2741`) to state the new rule: "Counts only **active** connections (committed + ≥1 enabled channel) — see `isActiveConnection` in `active-connection.ts`."

- [ ] **Step 6: Verify the worker type-checks**

Run: `cd workers/api && pnpm lint 2>&1 | grep -c "error TS"`
Expected: same count as baseline `main` (per project memory, `main` has 2 pre-existing `error TS`; the gate is "no NEW errors"). Confirm none reference `integrations.ts` or `active-connection.ts`.

- [ ] **Step 7: Seed-DB integration check (verifies the SQL, which mocks can't)**

Create a throwaway check (do NOT commit) to prove the guard now ignores draft + zero-channel duplicates. Using `$DATABASE_URL` (verify the port first per AGENTS.md):

```bash
psql "$DATABASE_URL" -tAc "show port;"   # sanity: expected local/worktree port
```

Then exercise the real flow with the run-app skill in Task 4 (the dedup runs inside the OAuth callback, which the seed script can't trigger directly). The seed-only assertion here is that the **query** returns no row for a draft/zero-channel sibling — confirm by temporarily logging `duplicate` or by reproducing via run-app in Task 4. Record the result in the commit message.

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/twist/tools/active-connection.ts \
        workers/api/src/twist/tools/active-connection.test.ts \
        workers/api/src/twist/tools/integrations.ts
git commit -m "fix(connections): dedup guard counts only active (committed + channel-bearing) connections

An abandoned OAuth flow left a draft=false, zero-channel orphan that was
hidden from the Active-connections list but still tripped the dedup guard,
producing an invisible 'This account is already connected' block. Restrict
the guard to active connections per the shared isActiveConnection definition."
```

---

## Task 2: Exclude drafts from the Active-connections summary endpoint (backend)

After Task 3 defers activation, an in-progress OAuth setup is a real `draft` row. The summary endpoint must not surface it as an Active connection.

**Files:**
- Modify: `workers/api/src/app/twists.ts:216-219`

- [ ] **Step 1: Add the draft filter to `/sources/summary`**

In `workers/api/src/app/twists.ts`, in the `sources` query (currently `199-219`), add a `draft` filter alongside the existing `archived_at` filter:

```typescript
      .where("twist.is_source", "=", true)
      .where("twist_instance.owner_id", "=", userId)
      .where("twist_instance.archived_at", "is", null)
      .where("twist_instance.draft", "=", false) // exclude in-progress setups
      .execute();
```

- [ ] **Step 2: Verify the worker type-checks**

Run: `cd workers/api && pnpm lint 2>&1 | grep -c "error TS"`
Expected: no new errors referencing `app/twists.ts`.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/twists.ts
git commit -m "fix(connections): exclude draft twist_instances from /sources/summary

Once OAuth activation is deferred to channel-commit (next change), an
in-progress setup is a real draft and must not appear in the Active list."
```

---

## Task 3: Defer OAuth activation to the channel-commit step (Flutter)

Make OAuth behave like the no-provider path: stay a draft after OAuth, and activate only when the user commits channels in `EditSource`. Transfer draft-cleanup ownership from `AddSourceDetail` to `EditSource` so abandoning channel selection deletes the draft.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` — `_activateAfterOAuth`/`_activateSource` (`2259-2330`), `AddSourceDetail.run` cleanup (`1671-1682`), the OAuth handoff fields (`1686-1704`), ManageConnections post-OAuth branch (`230-253`), `EditSource.run` (`1140-1200`) and `SaveSource.run` (`3765-3857`).
- Test (new): `apps/plot/test/command/draft_handoff_test.dart` (pure logic only — modal flow is run-app verified).

> **Note for the implementer:** Flutter modal flows are not unit-testable here (they need a live app + OAuth). TDD applies only to the extractable pure decision (Step 1). The modal/lifecycle wiring (Steps 3–7) is verified via the run-app skill in Task 4. Do not fabricate widget-driver tests for the OAuth popup.

- [ ] **Step 1: Write the failing test for the post-OAuth routing decision**

Create `apps/plot/test/command/draft_handoff_test.dart`. Extract the "after OAuth, should we open channel selection on the draft?" decision into a pure helper so it's testable:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/twist.dart';

void main() {
  group('shouldOpenChannelSetupAfterConnect', () {
    test('OAuth connector (has providers) → open channel setup on the draft', () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: true,
          completedInSetupModal: false,
        ),
        isTrue,
      );
    });

    test('no draft id → do not open setup', () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: null,
          hasProviders: true,
          completedInSetupModal: false,
        ),
        isFalse,
      );
    });

    test('completed inside the setup modal (no-provider) → do not re-open', () {
      expect(
        shouldOpenChannelSetupAfterConnect(
          connectedDraftId: 'abc',
          hasProviders: false,
          completedInSetupModal: true,
        ),
        isFalse,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/command/draft_handoff_test.dart`
Expected: FAIL — `shouldOpenChannelSetupAfterConnect` undefined.
(If generated files are missing in a worktree, first: `flutter pub get && flutter pub run build_runner build` and copy `app.env` per the worktree-test memory.)

- [ ] **Step 3: Add the pure helper and rename the OAuth-return tracking field**

In `apps/plot/lib/command/twist.dart`, add a top-level helper mirroring the existing ManageConnections condition (currently `237-239`):

```dart
/// After an OAuth connect, decide whether to open the channel-setup
/// (EditSource) step on the still-draft instance. OAuth connectors (those with
/// providers) defer channel selection to a second step; no-provider connectors
/// finish inside the setup modal itself.
bool shouldOpenChannelSetupAfterConnect({
  required String? connectedDraftId,
  required bool hasProviders,
  required bool completedInSetupModal,
}) =>
    connectedDraftId != null && hasProviders && !completedInSetupModal;
```

Rename `AddSourceDetail.lastActivatedSourceId` → `lastConnectedDraftId` and update its doc comment to: "Set after a successful OAuth connect (the instance is still a draft); ManageConnections reads this to open channel setup." Update all references (`231-235`, `2325`, `3440`, `3521`).

- [ ] **Step 4: Stop activating on OAuth return; hand the draft to EditSource**

Replace `_activateSource` (`2312-2335`) usage. Rename `_activateAfterOAuth` → `_connectedAfterOAuth` and change its tail (currently `2304-2309`) so it does **not** activate:

```dart
    if (!context.mounted) return;
    // Do NOT activate here. The instance stays a draft until the user commits
    // channels in EditSource. Release this modal's cleanup claim so run()'s
    // dismissal cleanup doesn't delete the draft — EditSource now owns it.
    lastConnectedDraftId = draftId;
    clearDraft();
    if (context.mounted) {
      Modal.pop<CommandReturn>(context, Value(const CommandDone()));
    }
```

Delete the now-unused `_activateSource` method (`2312-2335`) and its `TwistApi.activateDraft` call. Keep the team-default computation in `_connectedAfterOAuth` but stash the resolved `owner`/`teamId` so EditSource can default to it (pass via a static `lastConnectedTeamId`, mirroring `lastConnectedDraftId`).

- [ ] **Step 5: Open EditSource on the draft from ManageConnections**

In ManageConnections (`230-253`), replace the branch to use the renamed field + helper:

```dart
          } else if (item is _AvailableSource) {
            await AddSourceDetail(item.twist).run(ctx);
            final connectedDraftId = AddSourceDetail.lastConnectedDraftId;
            final completedInSetup =
                AddSourceDetail.lastActivatedInSetupModal;
            AddSourceDetail.lastConnectedDraftId = null;
            AddSourceDetail.lastActivatedInSetupModal = false;
            if (shouldOpenChannelSetupAfterConnect(
                  connectedDraftId: connectedDraftId,
                  hasProviders: item.twist.providers.isNotEmpty,
                  completedInSetupModal: completedInSetup,
                ) &&
                ctx.mounted) {
              // The instance is still a draft; EditSource activates it on save
              // and deletes it if the user abandons channel selection.
              await EditSource(
                twistInstanceId: connectedDraftId!,
                name: item.twist.name,
                isNewlyActivated: true,
              ).run(ctx);
            }
          }
```

- [ ] **Step 6: Make EditSource own draft cleanup and activate on save**

In `EditSource.run` (`1140`+), when `isNewlyActivated` is true the instance is a draft. Wrap the run so that if the user dismisses without saving, the draft is deleted:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await super.run(context);
    // If this was a newly-connected draft and the user dismissed without
    // committing channels (SaveSource calls _committed=true on success),
    // delete the abandoned draft so no orphan remains.
    if (isNewlyActivated && !_committed) {
      try {
        await TwistApi.deleteDraft(twistInstanceId);
      } catch (e, t) {
        log.warning('Failed to delete abandoned connection draft', e, t);
      }
    }
    return result;
  }

  static bool _committed = false;
```

In `SaveSource.run` (`3765`+), when the instance is a draft (pass an `isDraft`/reuse `isNewlyActivated` flag into `SaveSource`), call `activateDraft` with the selected channels **instead of** `applyChannelsBatch`, then set `EditSource._committed = true`:

```dart
      if (isNewlyActivated) {
        // Draft: commit it. Activation enables exactly the chosen channels.
        final channels = changes.selectedChannels
            .map((key) {
              final parts = key.split(':');
              return {
                'provider': parts.first,
                'syncableId': parts.sublist(1).join(':'),
              };
            })
            .toList();
        await TwistApi.activateDraft(
          draftId: twistInstanceId,
          name: name,
          channels: channels,
          teamId: teamId,
        );
        if (accountLabel != null) {
          try {
            await TwistApi.updateTwist(
              twistInstanceId: twistInstanceId,
              accountLabel: Value(accountLabel),
            );
          } catch (e, t) {
            log.warning('Failed to apply account label after activation', e, t);
          }
        }
        EditSource._committed = true;
        return CommandMessage('Connection "$name" saved');
      }
      // ...existing already-active path (updateTwist + applyChannelsBatch)...
```

Set `EditSource._committed = false` at the top of `EditSource.run` before `super.run` (reset per open). Thread the `isNewlyActivated` flag from `EditSource` into the `SaveSource` it builds (the EditSource form already constructs `SaveSource`; pass `isNewlyActivated: isNewlyActivated`).

- [ ] **Step 7: Run the unit test + analyze**

Run: `cd apps/plot && flutter test test/command/draft_handoff_test.dart`
Expected: PASS (3 tests).

Run: `cd apps/plot && flutter analyze lib/command/twist.dart`
Expected: no new errors (info-level allowed per CI `--no-fatal-infos`).

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/command/twist.dart apps/plot/test/command/draft_handoff_test.dart
git commit -m "feat(connections): keep OAuth connections as drafts until channels are committed

OAuth no longer activates on auth-return. The instance stays a draft through
channel selection; EditSource activates it on save and deletes it if the user
abandons setup. draft=false now consistently means 'user committed'."
```

---

## Task 4: Clean up the existing orphan and verify end-to-end

**Files:** none (operational + verification).

- [ ] **Step 1: Archive the user's existing dev orphan**

The current orphan is `draft=false`; after Task 1 it no longer blocks, but archive it so it stops appearing anywhere. Verify the port first, then:

```bash
psql "$DATABASE_URL" -tAc "show port;"
psql "$DATABASE_URL" -c "UPDATE twist_instance SET archived_at = now() WHERE id = '019e9841-b616-7e6f-96b3-02701bf33406' AND draft = false;"
```

(Archive, not delete: `twist_instance_connection` cascade deletes are not synced to clients; the dedup guard and summary already exclude `archived_at IS NOT NULL`.)

- [ ] **Step 2: Verify re-connect is unblocked (Task 1 in isolation)**

Use the run-app skill. With the orphan present (before Step 1) OR a freshly created zero-channel orphan, start adding Linear and authorize. Expected: **no** "already connected" error — the OAuth flow proceeds to channel selection.

- [ ] **Step 3: Verify the deferred-draft lifecycle (Task 3)**

Use the run-app skill:
1. Add Linear → authorize OAuth → confirm channel-selection (EditSource) opens.
2. Query the DB: the instance is `draft = true` at this point.
   ```bash
   psql "$DATABASE_URL" -c "SELECT id, draft FROM twist_instance WHERE twist_id = (SELECT id FROM twist WHERE name = 'Linear') ORDER BY created_at DESC LIMIT 1;"
   ```
   Expected: `draft = t`.
3. Dismiss channel selection without saving. Re-query: the draft row is **gone** (deleted).
4. Repeat, this time pick a channel and Save. Re-query: `draft = f` and `SELECT count(*) FROM channel WHERE twist_instance_id = '<id>' AND enabled = true;` ≥ 1. The connection appears in Active connections.
5. Try to add Linear again with the same account: now correctly blocked with "already connected" (because it's genuinely active).

- [ ] **Step 4: Update user-facing docs**

Add a bullet to the top section of `docs/updates.md` in plain language, e.g.: "Connecting an account no longer leaves a stuck connection if you close setup partway — you can always start over."

- [ ] **Step 5: Run the finalize checklist**

Invoke the `/finalize` skill: lint changed packages (`workers/api`, `apps/plot`), confirm error-capture in new catch blocks (the `deleteDraft` catch logs only — an expected/handled cleanup failure, so no `captureException` needed; the OAuth catch paths already capture), confirm no removed/renamed public API breaks old clients (the summary endpoint shape is unchanged; `activateDraft` already accepts `channels`).

- [ ] **Step 6: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs(updates): note connection-setup no longer leaves stuck connections"
```

---

## Self-Review notes

- **Spec coverage:** Reported bug (invisible blocking orphan) → Task 1 (dedup) + Task 4 Step 1 (archive). User's architectural request ("keep draft until activated, or use connections as the true signal") → Task 3 (keep draft) + Task 1 (unified active definition). Summary consistency → Task 2.
- **Why both Task 1 and Task 3:** Task 1 unblocks anyone already holding an orphan (existing `draft=false` rows) and is low-risk/backend-only; Task 3 stops new orphans at the source and restores `draft` semantics. Task 1 ships value even if Task 3 is deferred.
- **Tradeoff to be aware of (Task 1):** excluding zero-enabled-channel connections from the dedup means a user who deliberately disabled every channel on a real connection could connect the same account a second time. This is acceptable and matches the existing Active-list definition (`enabled_count > 0`); the alternative (orphans silently block forever) is worse.
- **Open follow-up (not in this plan):** a one-time production sweep to archive pre-existing `is_source`, `draft=false`, zero-enabled-channel instances. Not required for correctness once Task 1 lands (they no longer block), so deferred. Flag to the user before any prod data change.
- **`enabled_count == 0` Flutter filter (`twist.dart:392`):** left in place as defense-in-depth; it is now redundant with the deferred-draft flow but harmless. Not removed to keep this change minimal.
