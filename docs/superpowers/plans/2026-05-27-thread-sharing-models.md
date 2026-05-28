# Thread Sharing Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit thread/channel/message sharing-model support across Twister, the API, and the Flutter app — replacing the AvatarGroup with a channel title for channel-mode, surfacing per-note divergence badges in message-mode, and extending the sharing modal to manage a "Dropped" recipients list.

**Architecture:** A new `sharingModel: "thread" | "channel" | "message"` field on `LinkTypeConfig` (defaults to `"thread"` for backward compat) is the single source of truth. Connectors declare it; the Flutter client resolves it from the thread's primary (earliest) link and branches header / badge / modal rendering accordingly. The API enforces an always-explicit `note.access_contacts` invariant for message-mode threads, which unlocks per-viewer participant derivation and the "Dropped" section.

**Tech Stack:** TypeScript (Twister + Cloudflare Workers API), Dart/Flutter (apps/plot), Drift/SQLite (local), PostgreSQL (server), Vitest (API tests). No new dependencies. Flutter verification uses the project's `run-app` skill (no widget test harness in repo).

**Spec:** `docs/superpowers/specs/2026-05-27-thread-sharing-models-design.md`

---

## Preconditions and execution order

- **Phase 6 (Flutter modal extensions)** assumes the in-flight role-aware modal plan at `/Users/kris.braun/.claude/plans/rethink-the-modal-used-abundant-wand.md` has been merged. If it hasn't, do Phases 1–5 first and pause before Phase 6.
- Phases are sequential: each phase depends on the previous one. Phases 4, 5, and 6 each produce shippable user-visible work and can be paused at phase boundaries.
- **Dropped-user suppression assumed-supported.** The spec relies on existing visibility filters: notes excluded by `access_contacts` should not appear to the dropped user, should not bump their `thread_unread`, and should not generate push notifications. The Plot Thread Visibility Rules in `AGENTS.md` indicate the relevant filters live in `user.thread_unread` and notification queries. After Phase 4 lands, manually verify by logging in as a dropped user and confirming no unread/push fires for excluded notes. If suppression *isn't* working, file it as a separate plan — fixing visibility filters is its own surgery and out of scope here.

## File map

| File | Phase | Action |
|---|---|---|
| `public/twister/src/tools/integrations.ts` | 1 | Modify — add `sharingModel` field to `LinkTypeConfig` |
| `public/.changeset/thread-sharing-model.md` | 1 | Create — Twister changeset |
| `apps/plot/lib/store/link.dart` | 2 | Modify — add `sharingModel` to Flutter `LinkTypeConfig` + `fromJson` |
| `public/connectors/slack/src/slack.ts` | 3 | Modify — declare `sharingModel` on both link types |
| `public/connectors/linear/src/linear.ts` | 3 | Modify — declare `sharingModel: "channel"` |
| `public/connectors/gmail/src/gmail.ts` | 3 | Modify — declare `sharingModel: "message"` |
| `public/connectors/google-calendar/src/google-calendar.ts` | 3 | Modify — declare `sharingModel: "thread"` |
| `public/connectors/{airtable,asana,attio,fellow,github,google-chat,google-drive,google-tasks,granola,jira,ms-teams,todoist}/src/*.ts` | 3 | Modify — declare `sharingModel` per connector audit (see Task 6b) |
| `public/connectors/{apple-calendar,outlook-calendar}/src/*.ts` | 3 | Modify — declare `sharingModel: "thread"` |
| `connectors/linkedin/src/linkedin.ts` | 3 | Modify — declare `sharingModel` on private LinkedIn connector (not in `public/`) |
| `workers/api/src/app/sync/notes.ts` | 4 | Modify — enforce always-explicit `access_contacts` in message-mode |
| `workers/api/src/app/sync/notes.test.ts` | 4 | Create — invariant tests |
| `workers/api/src/twist/sharing.ts` | 4 | Create — `reconcileThreadContacts` 50% heuristic, applied platform-wide for any message-mode link type |
| `workers/api/src/twist/sharing.test.ts` | 4 | Create — heuristic unit tests |
| `workers/api/src/twist/tools/integrations.ts` (or `plot.createLink` path) | 4 | Modify — call `reconcileThreadContacts` on inbound `saveLink` when the resolved sharing model is `"message"` |
| `apps/plot/lib/store/thread.dart` | 5 | Modify — add `sharingModel` resolver and per-viewer participants helper |
| `apps/plot/lib/widget/thread.dart` | 5 | Modify — branch header rendering on sharing model |
| `apps/plot/lib/widget/note_badge.dart` | 5 | Create — divergence badge widget |
| `apps/plot/lib/widget/note.dart` | 5 | Modify — insert badge above body in message-mode |
| `apps/plot/lib/command/thread.dart` | 6 | Modify — Dropped section, drop-vs-remove, BCC auto-drop |

---

# Phase 1: Twister contract

### Task 1: Add `sharingModel` to `LinkTypeConfig`

**Files:**
- Modify: `public/twister/src/tools/integrations.ts:30-122`

- [ ] **Step 1: Add the field**

Open `public/twister/src/tools/integrations.ts`. After the `supportsContactChanges` field (around line 121), before the closing `};` of `LinkTypeConfig`, add:

```typescript
  /**
   * Declares how sharing on threads of this link type is scoped:
   *
   * - `"thread"` (default): one roster shared across all notes in the
   *   thread. Native Plot threads, Slack DMs, calendar events.
   * - `"channel"`: visibility is the external channel's membership;
   *   the per-thread `contacts` array is ignored for sharing UI.
   *   Slack channels, Linear projects.
   * - `"message"`: each note carries its own recipient set via
   *   `note.access_contacts`; the thread roster is the union across
   *   all messages. Email.
   *
   * Omit to default to `"thread"`. When set to `"message"`, every
   * note this connector ingests must populate `access_contacts`
   * explicitly (never NULL).
   */
  sharingModel?: "thread" | "channel" | "message";
```

- [ ] **Step 2: Build Twister**

```bash
cd /Users/kris.braun/code/plot/public/twister && pnpm build
```
Expected: clean build, no TS errors.

- [ ] **Step 3: Refresh workspace links**

```bash
cd /Users/kris.braun/code/plot && pnpm install
```

- [ ] **Step 4: Verify the type surfaced**

```bash
cd /Users/kris.braun/code/plot && grep -A2 "sharingModel" public/twister/dist/tools/integrations.d.ts | head -10
```
Expected: the `sharingModel` field appears in the built `.d.ts`.

- [ ] **Step 5: Add the Twister changeset**

Create `public/.changeset/thread-sharing-model.md` with:

```markdown
---
"@plotday/twister": minor
---

Added: `sharingModel` field on `LinkTypeConfig` to declare per-link-type sharing scope (`"thread"`, `"channel"`, or `"message"`). Defaults to `"thread"` when omitted. Connectors use `"channel"` for membership-based containers (Slack channels, Linear projects) and `"message"` for per-recipient threads (email).
```

- [ ] **Step 6: Validate the changeset**

```bash
cd /Users/kris.braun/code/plot/public && pnpm validate-changesets
```
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot/public && git add twister/src/tools/integrations.ts .changeset/thread-sharing-model.md && git commit -m "twister: add sharingModel to LinkTypeConfig"
cd /Users/kris.braun/code/plot && git add public && git commit -m "Bump twister submodule (sharingModel field)"
```

---

# Phase 2: Flutter type alignment

### Task 2: Mirror `sharingModel` in Flutter `LinkTypeConfig`

**Files:**
- Modify: `apps/plot/lib/store/link.dart:6-83`

- [ ] **Step 1: Add the enum**

Open `apps/plot/lib/store/link.dart`. At the top of the file (after `typedef LinkId = Uuid;` around line 3), add:

```dart
/// How sharing on threads of this link type is scoped. Mirrors
/// `LinkTypeConfig.sharingModel` in Twister.
enum SharingModel {
  /// One roster shared across all notes (default). Native threads,
  /// Slack DMs, calendar events.
  thread,
  /// Visibility is the external channel's membership; per-thread
  /// contacts are ignored for sharing UI. Slack channels, Linear.
  channel,
  /// Each note carries its own recipient set via access_contacts;
  /// thread roster is the union across messages. Email.
  message;

  static SharingModel fromJson(String? value) => switch (value) {
        'channel' => SharingModel.channel,
        'message' => SharingModel.message,
        _ => SharingModel.thread,
      };
}
```

- [ ] **Step 2: Add the field to `LinkTypeConfig`**

In the same file, in the `LinkTypeConfig` class (around line 6), after `supportsContactChanges`:

```dart
  /// How sharing on threads of this link type is scoped. See
  /// [SharingModel]. Defaults to thread.
  final SharingModel sharingModel;
```

Update the constructor (around line 30):

```dart
  const LinkTypeConfig({
    required this.type,
    required this.label,
    this.noteLabel,
    this.logo,
    this.logoDark,
    this.logoMono,
    this.statuses,
    this.supportsAssignee = false,
    this.compose,
    this.contactRoles,
    this.supportsContactChanges = false,
    this.sharingModel = SharingModel.thread,
  });
```

- [ ] **Step 3: Parse the field in `fromJson`**

In the same file, in `LinkTypeConfig.fromJson` (around line 44), inside the returned `LinkTypeConfig(...)` literal, after `supportsContactChanges:`:

```dart
      sharingModel: SharingModel.fromJson(
        json['sharingModel'] as String? ?? json['sharing_model'] as String?,
      ),
```

- [ ] **Step 4: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/store/link.dart
```
Expected: no new errors. (Pre-existing warnings are fine.)

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/store/link.dart && git commit -m "flutter: mirror sharingModel on LinkTypeConfig"
```

---

# Phase 3: Connector declarations

Each task adds the explicit `sharingModel` field to one connector. The shape is identical across connectors; only the value differs.

### Task 3: Declare `sharingModel` on Slack (channel + dm)

**Files:**
- Modify: `public/connectors/slack/src/slack.ts:98-131`

- [ ] **Step 1: Add `sharingModel: "channel"` to the `thread` link type**

In `public/connectors/slack/src/slack.ts`, in the `thread` entry of `linkTypes` (around line 99), after `noteLabel: "Message",` (line 102):

```typescript
      sharingModel: "channel" as const,
```

- [ ] **Step 2: Add `sharingModel: "thread"` to the `dm` link type**

In the same file, in the `dm` entry of `linkTypes` (around line 115), after `noteLabel: "Message",` (line 118):

```typescript
      sharingModel: "thread" as const,
```

- [ ] **Step 3: Type-check**

```bash
cd /Users/kris.braun/code/plot/public/connectors/slack && pnpm exec tsc --noEmit
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot/public && git add connectors/slack/src/slack.ts && git commit -m "slack: declare sharingModel (channel for threads, thread for DMs)"
```

### Task 4: Declare `sharingModel: "channel"` on Linear

**Files:**
- Modify: `public/connectors/linear/src/linear.ts:71-89`

- [ ] **Step 1: Add the field**

In the `linkTypes` entry of `public/connectors/linear/src/linear.ts`, after the existing `label` or `noteLabel` field (look around line 74), add:

```typescript
      sharingModel: "channel" as const,
```

- [ ] **Step 2: Type-check**

```bash
cd /Users/kris.braun/code/plot/public/connectors/linear && pnpm exec tsc --noEmit
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot/public && git add connectors/linear/src/linear.ts && git commit -m "linear: declare sharingModel: channel"
```

### Task 5: Declare `sharingModel: "message"` on Gmail

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts:116-145`

- [ ] **Step 1: Add the field**

In the `email` entry of `linkTypes` in `public/connectors/gmail/src/gmail.ts` (around line 117), after `noteLabel: "Reply",` (line 120):

```typescript
      sharingModel: "message" as const,
```

- [ ] **Step 2: Type-check**

```bash
cd /Users/kris.braun/code/plot/public/connectors/gmail && pnpm exec tsc --noEmit
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot/public && git add connectors/gmail/src/gmail.ts && git commit -m "gmail: declare sharingModel: message"
```

### Task 6: Declare `sharingModel: "thread"` on Google Calendar (explicit)

**Files:**
- Modify: `public/connectors/google-calendar/src/google-calendar.ts:152-170`

- [ ] **Step 1: Add the field**

In the `event` entry of `linkTypes` in `public/connectors/google-calendar/src/google-calendar.ts`, after `noteLabel` (look around line 155), add:

```typescript
      sharingModel: "thread" as const,
```

Note: this matches the default, but explicit declaration documents intent and protects against the default changing later.

- [ ] **Step 2: Type-check**

```bash
cd /Users/kris.braun/code/plot/public/connectors/google-calendar && pnpm exec tsc --noEmit
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot/public && git add connectors/google-calendar/src/google-calendar.ts && git commit -m "google-calendar: declare sharingModel: thread"
```

- [ ] **Step 4: Bump the submodule reference in the parent repo**

```bash
cd /Users/kris.braun/code/plot && git add public && git commit -m "Bump twister submodule (connector sharing-model declarations)"
```

### Task 6b: Declare `sharingModel` on every remaining connector

**Files:**
- Modify: each connector's main source file under `public/connectors/*/src/` (and `connectors/linkedin/src/linkedin.ts` in the parent repo — see Step C below).

Tasks 3–6 cover Slack, Linear, Gmail, and Google Calendar — the connectors used as canonical examples for each sharing model. This task adds the field to every other connector currently in the repo so the default-to-`"thread"` fallback never has to do real work in production. Connectors without source (e.g. `public/connectors/notion`, `public/connectors/linkedin-messaging` — dist-only stubs) are skipped; ditto `public/connectors/posthog` and `public/connectors/google-contacts`, which don't declare `linkTypes`.

The audit below was derived by reading each connector's `linkTypes` array and inferring the model from the external system's roster semantics. Treat it as the proposal; connector authors can override if they have better knowledge of how their external system scopes visibility.

**Audit:**

| Connector | Link type(s) | `sharingModel` |
|---|---|---|
| `public/connectors/airtable/src/airtable.ts` | `task` | `"channel"` (task in a base) |
| `public/connectors/apple-calendar/src/apple-calendar.ts` | `event` | `"thread"` (event roster = attendees) |
| `public/connectors/asana/src/asana.ts` | `task` | `"channel"` (task in a project) |
| `public/connectors/attio/src/attio.ts` | `deal`, `person`, `company` | `"channel"` (record in a workspace) |
| `public/connectors/fellow/src/fellow.ts` | `meeting` | `"thread"` (meeting roster = attendees) |
| `public/connectors/github/src/github.ts` | `pull_request`, `issue` | `"channel"` (PR/issue in a repo) |
| `public/connectors/google-chat/src/google-chat.ts` | `thread` | `"channel"` (chat space membership) |
| `public/connectors/google-chat/src/google-chat.ts` | `dm` | `"thread"` (per-DM roster) |
| `public/connectors/google-drive/src/google-drive.ts` | `doc`, `sheet`, `slide`, `form`, `document` | `"channel"` (doc sharing = roster) |
| `public/connectors/google-tasks/src/google-tasks.ts` | `task` | `"channel"` (task in a list) |
| `public/connectors/granola/src/granola.ts` | `meeting` | `"thread"` (meeting roster = attendees) |
| `public/connectors/jira/src/jira.ts` | `issue` | `"channel"` (issue in a project) |
| `public/connectors/ms-teams/src/ms-teams.ts` | `thread` | `"channel"` (Teams channel) |
| `public/connectors/ms-teams/src/ms-teams.ts` | `dm` | `"thread"` (per-DM roster) |
| `public/connectors/outlook-calendar/src/outlook-calendar.ts` | `event` | `"thread"` (event roster = attendees) |
| `public/connectors/todoist/src/todoist.ts` | `task` | `"channel"` (task in a project) |
| `connectors/linkedin/src/linkedin.ts` (private, parent repo) | `conversation` | `"thread"` (DM roster) |
| `connectors/linkedin/src/linkedin.ts` (private, parent repo) | `group` | `"channel"` (LinkedIn group membership) |
| `connectors/linkedin/src/linkedin.ts` (private, parent repo) | `dm` | `"thread"` (compose target = DM roster) |

- [ ] **Step A: Edit every public connector above**

For each connector in the table whose path starts with `public/connectors/`, open the file and add the appropriate `sharingModel: "..." as const,` line inside each matching `linkTypes` entry (right after `noteLabel` or `label`, matching the position used in Tasks 3–6).

Sanity-check after each file: `cd /Users/kris.braun/code/plot/public/connectors/<name> && pnpm exec tsc --noEmit` should be clean.

- [ ] **Step B: Commit the public-submodule edits**

```bash
cd /Users/kris.braun/code/plot/public && \
  git add connectors/airtable/src/airtable.ts \
          connectors/apple-calendar/src/apple-calendar.ts \
          connectors/asana/src/asana.ts \
          connectors/attio/src/attio.ts \
          connectors/fellow/src/fellow.ts \
          connectors/github/src/github.ts \
          connectors/google-chat/src/google-chat.ts \
          connectors/google-drive/src/google-drive.ts \
          connectors/google-tasks/src/google-tasks.ts \
          connectors/granola/src/granola.ts \
          connectors/jira/src/jira.ts \
          connectors/ms-teams/src/ms-teams.ts \
          connectors/outlook-calendar/src/outlook-calendar.ts \
          connectors/todoist/src/todoist.ts && \
  git commit -m "connectors: declare sharingModel across the remaining connector audit"
```

- [ ] **Step C: Edit the private LinkedIn connector (parent repo)**

`connectors/linkedin/src/linkedin.ts` lives in the **parent repo**, not in the `public/` submodule. The three link types (`conversation`, `group`, `dm`) get the models listed in the audit table above. Add the `sharingModel: "..." as const,` line in each entry, then:

```bash
cd /Users/kris.braun/code/plot/connectors/linkedin && pnpm exec tsc --noEmit
```
Expected: clean.

Commit lands in the parent repo (Step D below).

- [ ] **Step D: Bump the submodule reference and commit the private LinkedIn edit**

```bash
cd /Users/kris.braun/code/plot && \
  git add public connectors/linkedin/src/linkedin.ts && \
  git commit -m "Declare sharingModel on remaining connectors (incl. private LinkedIn)"
```

- [ ] **Step E: Smoke-check the audit**

```bash
cd /Users/kris.braun/code/plot && \
  rg -l "readonly linkTypes" public/connectors/*/src/*.ts connectors/*/src/*.ts | \
  while read f; do
    if ! grep -q "sharingModel" "$f"; then
      echo "MISSING: $f"
    fi
  done
```
Expected: empty output (every connector with `readonly linkTypes` now declares `sharingModel` on at least one link type). If anything prints, either add the model or document why the connector should keep the default.

---

# Phase 4: API invariants

### Task 7: Enforce always-explicit `access_contacts` for message-mode on `POST /sync/notes`

**Files:**
- Modify: `workers/api/src/app/sync/notes.ts:171-210`
- Test: `workers/api/src/app/sync/notes.test.ts` (create)

The send path currently passes `access_contacts` through verbatim, including `null`. For message-mode threads, `null` must be replaced with the current `thread.contacts` array so the historical participant set and per-viewer derivation remain coherent.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/app/sync/notes.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { resolveAccessContactsForSend } from "./notes";

describe("resolveAccessContactsForSend", () => {
  it("returns body.access_contacts unchanged when sharing model is thread", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "thread",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("returns body.access_contacts unchanged when sharing model is channel", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "channel",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("falls back to thread.contacts when body is null in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1", "c2"]);
  });

  it("preserves explicit body.access_contacts in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: ["c1"],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1"]);
  });

  it("preserves an explicit empty array (author-only) in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: [],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm vitest run src/app/sync/notes.test.ts
```
Expected: FAIL with "resolveAccessContactsForSend is not exported".

- [ ] **Step 3: Add the helper and wire it into the handler**

In `workers/api/src/app/sync/notes.ts`, near the top of the module (after the imports), add:

```typescript
export type SharingModel = "thread" | "channel" | "message";

export function resolveAccessContactsForSend(args: {
  bodyAccessContacts: string[] | null | undefined;
  sharingModel: SharingModel;
  threadContacts: string[];
}): string[] | null {
  const { bodyAccessContacts, sharingModel, threadContacts } = args;
  if (sharingModel !== "message") {
    return Array.isArray(bodyAccessContacts) ? bodyAccessContacts : null;
  }
  // Message-mode invariant: never store NULL access_contacts.
  if (Array.isArray(bodyAccessContacts)) return bodyAccessContacts;
  return [...threadContacts];
}
```

Then, in the `POST /sync/notes` handler (around line 186), replace the existing `p_access_contacts:` assignment with a resolver-driven version. Insert the resolution before the `rpcUser` call:

```typescript
  const result = await withUserDb(c.var.db, c.var.user.id, async (trx) => {
    await assertThreadAccess(trx, c.var.user.id, body.thread_id);

    // Resolve sharing model + current thread.contacts so the message-mode
    // invariant (always-explicit access_contacts) can be enforced.
    const threadRow = await trx
      .selectFrom("thread")
      .innerJoin("link", "link.thread_id", "thread.id")
      .innerJoin("twist_instance", "twist_instance.id", "link.twist_instance_id")
      .select(["thread.contacts", "twist_instance.link_types", "link.type"])
      .where("thread.id", "=", body.thread_id)
      .orderBy("link.created_at", "asc")
      .executeTakeFirst();

    const sharingModel: SharingModel = (() => {
      if (!threadRow?.link_types) return "thread";
      const types = threadRow.link_types as Array<{ type: string; sharingModel?: SharingModel }>;
      const matched = types.find((t) => t.type === threadRow.type);
      return matched?.sharingModel ?? "thread";
    })();

    const resolvedAccessContacts = resolveAccessContactsForSend({
      bodyAccessContacts: body.access_contacts ?? null,
      sharingModel,
      threadContacts: (threadRow?.contacts ?? []) as string[],
    });

    return rpcUser(trx, "upsert_note", {
      user_id: c.var.user.id,
      p_id: body.id || null,
      p_author_id: body.author_id,
      p_created_by: body.created_by || c.var.user.id,
      p_updated_by: body.updated_by || 0,
      p_archived_at: body.archived_at || null,
      p_thread_id: body.thread_id,
      p_draft: body.draft || false,
      p_access_contacts: (resolvedAccessContacts
        ? `{${resolvedAccessContacts.join(",")}}`
        : null) as any,
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

(Replace only the `result = await withUserDb(...)` block. The handler tail after `result` stays unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm vitest run src/app/sync/notes.test.ts
```
Expected: all 5 tests PASS.

- [ ] **Step 5: Lint**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm lint
```
Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot && git add workers/api/src/app/sync/notes.ts workers/api/src/app/sync/notes.test.ts && git commit -m "api: enforce always-explicit access_contacts for message-mode threads"
```

### Task 8: Add the 50% removal heuristic in the API runtime (platform-wide)

**Files:**
- Create: `workers/api/src/twist/sharing.ts`
- Create: `workers/api/src/twist/sharing.test.ts`
- Modify: `workers/api/src/twist/tools/integrations.ts` (the `saveLink` path that ultimately writes `thread.contacts` — likely inside `plot.createLink`, or wherever the previous thread row is read before upsert)

The 50% heuristic interprets recipient changes on inbound messages and decides whether the change is a real edit to the thread default or a one-off subset reply. It is **not** specific to Gmail — every connector that declares `sharingModel: "message"` should get the same treatment. Putting it in the API runtime means one implementation, one place to tune the threshold, and connectors stay dumb: they just pass the incoming message's recipient set as the link's `contacts` field, and the API decides what `thread.contacts` becomes.

This task replaces an earlier draft that put the helper in `public/connectors/gmail/src/gmail-sharing.ts`. Do not create that file; if you find it on disk from a prior attempt, delete it before starting.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/sharing.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { reconcileThreadContacts } from "./sharing";

describe("reconcileThreadContacts (50% removal heuristic)", () => {
  it("adds new recipients always", () => {
    expect(
      reconcileThreadContacts({
        previous: ["a", "b"],
        incoming: ["a", "b", "c"],
      }),
    ).toEqual(["a", "b", "c"]);
  });

  it("removes recipients when <=50% of previous were dropped", () => {
    // 1 of 3 dropped = 33% → real removal
    expect(
      reconcileThreadContacts({
        previous: ["a", "b", "c"],
        incoming: ["a", "b"],
      }),
    ).toEqual(["a", "b"]);
  });

  it("treats 50% removal as a real removal (2-person edge)", () => {
    // 1 of 2 dropped = 50% → real removal
    expect(
      reconcileThreadContacts({
        previous: ["a", "b"],
        incoming: ["a"],
      }),
    ).toEqual(["a"]);
  });

  it("ignores removal when >50% of previous were dropped (private subset reply)", () => {
    // 8 of 10 dropped = 80% → keep default
    expect(
      reconcileThreadContacts({
        previous: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
        incoming: ["a", "b"],
      }),
    ).toEqual(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]);
  });

  it("still adds newcomers even when most others were dropped", () => {
    // 8 dropped, but "z" is new → add "z", keep originals
    expect(
      reconcileThreadContacts({
        previous: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
        incoming: ["a", "b", "z"],
      }).sort(),
    ).toEqual([
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "z",
    ]);
  });

  it("is a no-op when previous and incoming are identical", () => {
    expect(
      reconcileThreadContacts({
        previous: ["a", "b", "c"],
        incoming: ["a", "b", "c"],
      }).sort(),
    ).toEqual(["a", "b", "c"]);
  });

  it("handles empty previous (first message)", () => {
    expect(
      reconcileThreadContacts({
        previous: [],
        incoming: ["a", "b"],
      }).sort(),
    ).toEqual(["a", "b"]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm vitest run src/twist/sharing.test.ts
```
Expected: FAIL with "reconcileThreadContacts not found".

- [ ] **Step 3: Implement the heuristic**

Create `workers/api/src/twist/sharing.ts`:

```typescript
/**
 * Heuristic for reconciling a message-mode thread's `thread.contacts`
 * against the recipient set of an incoming message. See the "Heuristic"
 * section of docs/superpowers/specs/2026-05-27-thread-sharing-models-design.md.
 *
 * The threshold is intentionally a platform-level concern: it is the same
 * across every connector that declares `sharingModel: "message"`, lives in
 * one place so it can be tuned with real data, and keeps connectors simple
 * (they just hand the API the new message's recipients verbatim).
 *
 * - Added recipients: always merged into the result.
 * - Removed recipients: dropped from the result only when <=50% of the
 *   previous recipients are missing from the incoming set. Larger
 *   subsets are treated as private replies and leave the thread default
 *   untouched.
 */
export const MESSAGE_REMOVAL_THRESHOLD = 0.5;

export function reconcileThreadContacts(args: {
  previous: string[];
  incoming: string[];
}): string[] {
  const { previous, incoming } = args;
  const incomingSet = new Set(incoming);
  const previousSet = new Set(previous);

  const additions = incoming.filter((c) => !previousSet.has(c));
  const removed = previous.filter((c) => !incomingSet.has(c));

  const removalRatio =
    previous.length === 0 ? 0 : removed.length / previous.length;
  const treatAsRealRemoval = removalRatio <= MESSAGE_REMOVAL_THRESHOLD;

  const kept = treatAsRealRemoval
    ? previous.filter((c) => incomingSet.has(c))
    : previous;

  // Dedupe while preserving stable order: kept first (preserving
  // previous order), then additions (preserving incoming order).
  const out: string[] = [];
  const seen = new Set<string>();
  for (const c of [...kept, ...additions]) {
    if (!seen.has(c)) {
      out.push(c);
      seen.add(c);
    }
  }
  return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm vitest run src/twist/sharing.test.ts
```
Expected: all 7 tests PASS.

- [ ] **Step 5: Wire the helper into the inbound `saveLink` path**

Locate the spot in the API runtime where an inbound `integrations.saveLink()` call updates an existing thread's `contacts`. Starting points:
- `workers/api/src/twist/tools/integrations.ts` — the `saveLink` method (currently around line 1042) calls `plot.createLink(link)`.
- Trace `plot.createLink` to where it reads any existing thread row by `source` and writes `thread.contacts`. The reconciliation must happen there, conditional on the resolved link type's `sharingModel === "message"`.

Sketch of the inbound flow with the heuristic spliced in:

```typescript
import { reconcileThreadContacts } from "../sharing";

// Inside the inbound link-upsert path, after looking up the existing
// thread row but before writing new contacts:
const sharingModel = resolveSharingModel(twistLinkTypes, link.type);
if (sharingModel === "message" && existingThread) {
  link.contacts = reconcileThreadContacts({
    previous: existingThread.contacts ?? [],
    incoming: link.contacts ?? [],
  });
}
```

`resolveSharingModel` is the same lookup used in Task 7's `POST /sync/notes` handler — it reads the link's twist instance `link_types` JSON and returns the `sharingModel` for the matching link type, defaulting to `"thread"`. Extract that lookup into `workers/api/src/twist/sharing.ts` alongside `reconcileThreadContacts` and reuse it from both call sites.

For "thread" and "channel" sharing models, the API continues to take `link.contacts` verbatim — no change.

If the existing inbound code path doesn't currently touch `thread.contacts` after the first message (i.e. it only writes contacts on initial thread creation), this wiring is a no-op today. Flag that in the commit message and ship the helper anyway so the next time inbound recipient changes are wired through, the heuristic fires automatically.

- [ ] **Step 6: Type-check and lint the API worker**

```bash
cd /Users/kris.braun/code/plot/workers/api && pnpm lint
```
Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot && git add workers/api/src/twist/sharing.ts workers/api/src/twist/sharing.test.ts workers/api/src/twist/tools/integrations.ts && git commit -m "api: add 50% removal heuristic for message-mode thread.contacts reconciliation"
```

---

# Phase 5: Flutter rendering — header + note badges

Flutter widgets in this project have no automated test harness; verification is via the `run-app` skill (manual). Each task ends with a manual-verification step using a thread of the appropriate type.

### Task 9: Resolver — `Thread.sharingModel` and `Thread.visibleContactsFor(viewerId)`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (around the existing `contacts` getter at line 4424)

- [ ] **Step 1: Add the resolver methods to `Thread`**

In `apps/plot/lib/store/thread.dart`, near the `contacts` getter (around line 4424), add:

```dart
  /// Resolved sharing model for this thread, derived from the primary
  /// (earliest-created) link's `LinkTypeConfig.sharingModel`. Threads
  /// with no link default to [SharingModel.thread].
  ///
  /// The store layer caches links per thread, so this is a cheap
  /// in-memory lookup at the call site. Pass the list of links in
  /// rather than re-querying.
  static SharingModel resolveSharingModel(List<Link> links) {
    if (links.isEmpty) return SharingModel.thread;
    final primary = [...links]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final cfg = primary.first.getTypeConfig();
    return cfg?.sharingModel ?? SharingModel.thread;
  }

  /// Per-viewer visible-contacts derivation for message-mode threads.
  /// Returns the union of `access_contacts` across notes the viewer
  /// can see, plus each visible note's author. For non-message-mode
  /// threads, callers should use `thread.contacts` directly.
  ///
  /// `viewerContactIds` should be every contact linked to the viewer
  /// (matches `user.user_contact_ids()` server-side).
  static Set<Uuid> deriveVisibleContacts({
    required List<Note> visibleNotes,
    required Iterable<Uuid> viewerContactIds,
  }) {
    final out = <Uuid>{};
    for (final note in visibleNotes) {
      final authorId = note.authorId;
      if (authorId != null) out.add(authorId);
      final access = note.accessContacts;
      if (access != null) out.addAll(access);
    }
    out.addAll(viewerContactIds);
    return out;
  }
```

Note: the exact getter/method names for `note.authorId`, `note.accessContacts`, and `link.createdAt` may differ slightly — adjust to match the Drift-generated accessors. Grep `apps/plot/lib/store/note.dart` and `link.dart` to confirm.

- [ ] **Step 2: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/store/thread.dart lib/store/note.dart lib/store/link.dart
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/store/thread.dart && git commit -m "flutter: add Thread.resolveSharingModel + deriveVisibleContacts"
```

### Task 10: Channel-mode header — render channel title in place of AvatarGroup

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart:880-950`

- [ ] **Step 1: Branch the header render on sharing model**

In `apps/plot/lib/widget/thread.dart`, around line 914 where `Widget child = shared ? AvatarGroup(...) : SizedBox(...)`, replace the `AvatarGroup` branch with a conditional on the sharing model. The pseudo-shape:

```dart
    final sharingModel = Thread.resolveSharingModel(command.thread.links);

    Widget buildAvatarGroup() => AvatarGroup(
          actors: actors,
          totalCount: command.sharedTotalCount,
          size: avatarSize,
          scheduleContacts: scheduleContacts,
          tooltipBelow: tooltipBelow,
        );

    Widget buildChannelTitle() {
      final channel = command.thread.primaryChannel;
      if (channel == null) {
        // Fallback per spec: render avatars if channel can't be resolved.
        return buildAvatarGroup();
      }
      return Text(
        channel.title,
        style: context.theme.typography.sm.copyWith(
          color: context.colour.muted,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    }

    final Widget child = shared
        ? switch (sharingModel) {
            SharingModel.channel => buildChannelTitle(),
            SharingModel.thread || SharingModel.message => buildAvatarGroup(),
          }
        : SizedBox(
            width: iconSize,
            height: iconSize,
            child: Center(
              child: FaIcon(
                command.icon ?? PlotIcon.shareAdd,
                size: iconSize,
                color: iconColor,
              ),
            ),
          );
```

Note: `command.thread.links` and `command.thread.primaryChannel` may need to be added to the underlying command/thread objects. If `primaryChannel` doesn't exist, derive it inline: find the earliest link with a non-null `channelId`, look up the channel by `(twistInstanceId, channelId)`. Read `apps/plot/lib/store/channel.dart` (if it exists) or grep for `Channel` to find the lookup helper.

- [ ] **Step 2: Per-viewer derivation for message-mode AvatarGroup**

For message-mode, the `actors` list above must be derived per-viewer instead of read from `thread.contacts` directly. Around line 894, modify the actors resolution:

```dart
    final viewerContactIds = command.viewerContactIds; // wire from the bloc
    final Iterable<Uuid> headerContactIds = switch (sharingModel) {
      SharingModel.message => Thread.deriveVisibleContacts(
          visibleNotes: command.thread.notes,
          viewerContactIds: viewerContactIds,
        ),
      _ => command.thread.contacts,
    };

    final contactsKey = headerContactIds.map((u) => u.toString()).join('|');
    final loadedActors = useFuture(
      useMemoized(
        () => command.loadDisplayActorsFor(headerContactIds),
        [contactsKey],
      ),
    ).data;
    final actors = loadedActors ?? command.sharedDisplayActors;
```

If `command.loadDisplayActorsFor(...)` doesn't exist, add an overload of `loadSharedDisplayActors` that takes an explicit contact-id iterable and use it here. The existing `loadSharedDisplayActors()` becomes a thin wrapper.

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/widget/thread.dart
```

- [ ] **Step 4: Manual verification with `run-app`**

Use the `run-app` skill. Then:

- **Slack channel thread** (channel-mode): open the thread. Header shows `#<channel-name>` in place of the AvatarGroup. No avatars, no tap behaviour.
- **Slack DM** (thread-mode): header still shows AvatarGroup of participants. Unchanged.
- **Gmail thread** (message-mode): header shows AvatarGroup of the union of recipients across messages. Unchanged for an active participant.
- **Channel fallback**: pick a thread whose linked channel row is missing or not yet synced — header falls back to the AvatarGroup of `thread.contacts`.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/widget/thread.dart apps/plot/lib/store/thread.dart && git commit -m "flutter: render channel title for channel-mode threads + per-viewer participants for message-mode"
```

### Task 11: `NoteBadge` widget

**Files:**
- Create: `apps/plot/lib/widget/note_badge.dart`

- [ ] **Step 1: Implement the widget**

Create `apps/plot/lib/widget/note_badge.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Small pill badge shown above a note body when the note's audience
/// diverges from the thread superset. See
/// docs/superpowers/specs/2026-05-27-thread-sharing-models-design.md.
///
/// Text is composed by [audienceLabel] in the caller; this widget is
/// purely presentational so it can be unit-checked visually.
class NoteBadge extends StatelessWidget {
  const NoteBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.colour.secondary.withOpacity(0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: context.theme.typography.xs.copyWith(
          color: context.colour.mutedForeground,
        ),
      ),
    );
  }
}
```

If `context.theme.typography.xs` or `context.colour.secondary` don't exist verbatim, grep `apps/plot/lib/widget/` for the closest existing muted-pill pattern (e.g. how shortcut hints are rendered around `list_tile.dart:738`) and match it.

- [ ] **Step 2: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/widget/note_badge.dart
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/widget/note_badge.dart && git commit -m "flutter: add NoteBadge widget"
```

### Task 12: Audience-diff logic for note badges

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (add a top-level or static `noteBadgeLabel` helper)

- [ ] **Step 1: Implement the logic**

In `apps/plot/lib/store/thread.dart`, add a static method to `Thread` (or a top-level function in the same file):

```dart
  /// Compute the badge label for a note in a message-mode thread.
  /// Returns null when the note matches the thread superset (no badge).
  ///
  /// - `noteAudience` = `note.accessContacts ?? {note.authorId}` plus
  ///   the author. The caller is responsible for resolving NULL into
  ///   the effective audience before calling.
  /// - `threadContacts` = current `thread.contacts`.
  /// - `viewerContactIds` = every contact linked to the viewer.
  /// - `nameLookup(contactId)` = display-name resolver.
  static String? noteBadgeLabel({
    required Set<Uuid> noteAudience,
    required Set<Uuid> threadContacts,
    required Set<Uuid> viewerContactIds,
    required String Function(Uuid) nameLookup,
  }) {
    final viewerInAudience = noteAudience.any(viewerContactIds.contains);
    if (!viewerInAudience) return null;

    final others = noteAudience
        .where((c) => !viewerContactIds.contains(c))
        .toSet();
    final subsetOthers = others.intersection(threadContacts);
    final plusOthers = others.difference(threadContacts);

    final isPrivate = others.isEmpty;
    // Subset = the audience is missing at least one thread contact (excluding
    // viewer's own contacts, which the viewer is always counted as).
    final isSubset =
        !threadContacts.difference(viewerContactIds).every(noteAudience.contains);
    final isPlus = plusOthers.isNotEmpty;

    if (isPrivate && !isPlus) return "Private";

    // Format: "A" | "A, B" | "A, B +N"
    String formatNames(Iterable<Uuid> ids) {
      final names = ids.map(nameLookup).toList();
      if (names.length == 1) return names[0];
      if (names.length == 2) return "${names[0]}, ${names[1]}";
      return "${names[0]}, ${names[1]} +${names.length - 2}";
    }

    // "and you" gets a comma when the list has 2+ names (Oxford comma).
    String subsetClause(Set<Uuid> ids) {
      final names = formatNames(ids);
      final needsComma = ids.length >= 2;
      return needsComma ? "$names, and you" : "$names and you";
    }

    if (isSubset && isPlus) {
      return "Just ${subsetClause(subsetOthers)}, plus ${formatNames(plusOthers)}";
    }
    if (isSubset) {
      return "Just ${subsetClause(subsetOthers)}";
    }
    if (isPlus) {
      return "Plus ${formatNames(plusOthers)}";
    }
    return null;
  }
```

- [ ] **Step 2: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/store/thread.dart
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/store/thread.dart && git commit -m "flutter: noteBadgeLabel — divergence label logic for message-mode notes"
```

### Task 13: Insert badge above note body

**Files:**
- Modify: `apps/plot/lib/widget/note.dart:85-250`

- [ ] **Step 1: Compute badge label and render**

In `apps/plot/lib/widget/note.dart`, within the `NoteWidget` render around line 150 where the body Column lives, before the body content (around line 158), insert a conditional badge render. The shape:

```dart
import 'package:plot/widget/note_badge.dart';

// ... inside the build method, before the body content widget:

final sharingModel = Thread.resolveSharingModel(thread.links);
final badgeLabel = sharingModel == SharingModel.message
    ? Thread.noteBadgeLabel(
        noteAudience: {
          if (note.authorId != null) note.authorId!,
          ...?note.accessContacts,
        },
        threadContacts: thread.contacts.toSet(),
        viewerContactIds: viewerContactIds.toSet(),
        nameLookup: (id) => contactsBloc.nameFor(id) ?? "Someone",
      )
    : null;

return Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    if (badgeLabel != null) ...[
      NoteBadge(label: badgeLabel),
      const SizedBox(height: 4),
    ],
    // ...existing reply reference and body content
  ],
);
```

`viewerContactIds` and `contactsBloc.nameFor(...)` are placeholders for whatever the page-level state passes into the note widget. If they aren't already plumbed through, add them to the `NoteWidget` constructor and pass them from the calling page.

- [ ] **Step 2: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/widget/note.dart
```

- [ ] **Step 3: Manual verification with `run-app`**

- **Gmail thread, all-recipients reply**: no badge.
- **Gmail thread, private reply to you**: badge **"Just [Sender] and you"** above the note.
- **Self-authored private note** (drafted with no recipients): badge **"Private"**.
- **Slack channel thread**: no badges anywhere (channel-mode ignores `access_contacts`).
- **Slack DM**: no badges anywhere (thread-mode).

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/widget/note.dart && git commit -m "flutter: render divergence badges above message-mode note bodies"
```

---

# Phase 6: Sharing modal extensions

**Precondition**: the role-aware modal plan at `/Users/kris.braun/.claude/plans/rethink-the-modal-used-abundant-wand.md` should have landed first. The tasks below extend `PickDraftThreadShared` and `ShareThreadActor`, which that plan already touches.

### Task 14: Historical participant query

**Files:**
- Modify: `apps/plot/lib/store/thread.dart`

- [ ] **Step 1: Add helper**

In `apps/plot/lib/store/thread.dart`, add to `Thread`:

```dart
  /// Union of `access_contacts` across all of a thread's notes, plus
  /// each note's author. Used by message-mode sharing modal to populate
  /// the Dropped section and the re-add suggestion source.
  static Set<Uuid> historicalParticipants(List<Note> notes) {
    final out = <Uuid>{};
    for (final note in notes) {
      final author = note.authorId;
      if (author != null) out.add(author);
      final access = note.accessContacts;
      if (access != null) out.addAll(access);
    }
    return out;
  }
```

- [ ] **Step 2: Lint + commit**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/store/thread.dart
cd /Users/kris.braun/code/plot && git add apps/plot/lib/store/thread.dart && git commit -m "flutter: Thread.historicalParticipants helper"
```

### Task 15: Dropped section in `PickDraftThreadShared`

**Files:**
- Modify: `apps/plot/lib/command/thread.dart:2578-2607` (factory) and `:2796-2910` (`_buildSharedCommands`)

- [ ] **Step 1: Add a `_ThreadDroppedGroup` (or extend `_ThreadShareSuggestionsGroup`)**

In `apps/plot/lib/command/thread.dart`, alongside the existing `_ThreadShareSuggestionsGroup` (around line 2910), add a new section that:
1. Is gated on `sharingModel == SharingModel.message`.
2. Computes `dropped = Thread.historicalParticipants(thread.notes) - thread.contacts - viewerContactIds`.
3. Renders each as a `ShareThreadActor` (or a thin wrapper) labelled "Dropped".
4. On tap, re-adds to `thread.contacts` at the connector's default role (existing `ShareThreadActor.run` path).

Sketch:

```dart
class _ThreadDroppedGroup extends CommandGroup {
  _ThreadDroppedGroup({required this.thread, required this.viewerContactIds});

  final Thread thread;
  final Set<Uuid> viewerContactIds;

  @override
  String? get title => "Dropped";

  @override
  List<Command> buildCommands(BuildContext context) {
    final droppedIds = Thread.historicalParticipants(thread.notes)
        .difference(thread.contacts.toSet())
        .difference(viewerContactIds);
    return droppedIds
        .map((id) => ShareThreadActor(
              thread: thread,
              contactId: id,
              // existing role/cycle constructor args from the
              // role-aware modal plan stay unchanged.
            ))
        .toList();
  }
}
```

Then, in `_buildSharedCommands` (around line 2796), branch on `sharingModel`. Only include `_ThreadDroppedGroup` for message-mode threads.

- [ ] **Step 2: Resolve sharing model at the modal open site**

In `apps/plot/lib/page/new_thread.dart` `_openSharedPicker` (the same call site the role-aware modal plan touches, around line 518), pass the resolved `sharingModel` into `PickDraftThreadShared` alongside `contactRoles` / `defaultRoleId`.

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/command/thread.dart lib/page/new_thread.dart
```

- [ ] **Step 4: Manual verification with `run-app`**

- **Gmail thread**: open share modal. Active recipients in Shared list, dropped recipients (anyone who appeared on a previous message but not on the current `thread.contacts`) in the new Dropped section.
- **Slack channel / DM / Calendar**: no Dropped section appears.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/command/thread.dart apps/plot/lib/page/new_thread.dart && git commit -m "flutter: Dropped section in sharing modal for message-mode threads"
```

### Task 16: Drop-instead-of-remove in message-mode

**Files:**
- Modify: `apps/plot/lib/command/thread.dart:3051-3086` (`ShareThreadActor`)

In thread-mode and channel-mode, removing a contact via the Shared row deletes them from `thread.contacts`. In message-mode, removal must still strip the contact from `thread.contacts` *and* clear `contactMeta` (per the role-aware modal plan), but the contact remains discoverable in the Dropped section — which Task 15 already wires up automatically (Dropped derives from notes, so as long as the contact appears on at least one historical note, they show in Dropped after removal).

In practice this means **no behaviour change to `ShareThreadActor.run` itself** — the existing remove path already does the right thing. This task confirms that.

- [ ] **Step 1: Read `ShareThreadActor.run` and confirm**

Read `apps/plot/lib/command/thread.dart:3057-3086`. Confirm that removing a contact:
1. Removes them from `thread.contacts`.
2. Clears their `contactMeta` entry (per the role-aware modal plan).
3. Persists via `onUpdate(thread.copyWith(...))`.

If yes: no edits needed. Move to Step 2.

If the existing remove path *doesn't* clear `contactMeta`, add that — but that's the role-aware modal plan's job, not this one. Flag the gap and defer.

- [ ] **Step 2: Manual verification with `run-app`**

In a Gmail thread, remove a recipient via the sharing modal. Reopen. They should appear under Dropped (because they're still in the thread's note history). Re-add them. They should land back at the connector's default role.

- [ ] **Step 3: Commit (only if any code change was needed)**

If no code changes: skip the commit. Note in the next commit's message: "Task 16 confirmed no-op (drop semantics emerge from Task 15)."

### Task 17: BCC auto-drop after send

**Files:**
- Modify: the send path in Flutter that posts a new message for message-mode threads. Find by grepping for the action/command that fires when the composer's send button is hit — likely in `apps/plot/lib/action/` or `apps/plot/lib/command/`.

- [ ] **Step 1: Locate the send action**

```bash
cd /Users/kris.braun/code/plot/apps/plot && grep -rn "POST.*sync/notes\|/sync/notes" lib/ | head -10
```

The send path likely calls a `Note.upsert(...)` or similar that hits `/sync/notes`. Trace from there back to the action triggered by send. Most likely candidate: an action in `apps/plot/lib/action/` named like `SendNoteAction` or `ReplyAction`.

- [ ] **Step 2: After successful send, mutate `thread.contacts` to drop hidden-role contacts**

In the send action's success path, after the note is persisted:

```dart
final cfg = thread.links.firstOrNull?.getTypeConfig();
if (cfg?.sharingModel == SharingModel.message) {
  final roles = cfg?.contactRoles ?? const [];
  final hiddenRoleIds = roles.where((r) => r.hidden).map((r) => r.id).toSet();
  if (hiddenRoleIds.isNotEmpty) {
    final meta = thread.contactMeta;
    final toDrop = thread.contacts.where((contactId) {
      final role = meta[contactId.toString()]?.role;
      return role != null && hiddenRoleIds.contains(role);
    }).toList();
    if (toDrop.isNotEmpty) {
      final newContacts = thread.contacts
          .where((c) => !toDrop.contains(c))
          .toList();
      final newMeta = Map.of(meta)..removeWhere((k, _) =>
          toDrop.any((id) => id.toString() == k));
      await onUpdate(thread.copyWith(
        contacts: newContacts,
        contactMeta: newMeta,
      ));
    }
  }
}
```

The exact `contactMeta` shape and `copyWith` accessor names come from the role-aware modal plan; match them.

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze
```

- [ ] **Step 4: Manual verification with `run-app`**

In a Gmail thread, compose a new message, add a recipient at BCC, send. After send, reopen the share modal — the BCC recipient should be in Dropped (not Shared). On a non-BCC recipient, nothing changes.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot && git add apps/plot/lib/action apps/plot/lib/command && git commit -m "flutter: auto-drop BCC recipients after sending in message-mode threads"
```

---

# Follow-ups (not in this plan)

These are explicitly out of scope and tracked for later:

1. **Audit remaining connectors** (airtable, apple-calendar, asana, attio, fellow, github, google-chat, google-contacts, google-drive, google-tasks, granola, jira, linkedin-messaging, ms-teams, notion, outlook-calendar, posthog, todoist) and declare explicit `sharingModel` on each. Default `"thread"` covers behaviour, but explicit declaration documents intent.
2. **One-off subset replies** — a way to send one message to a subset of recipients without mutating `thread.contacts`. Today every message-mode reply runs through the 50% heuristic and may shift the default.
3. **Heuristic tuning** — the 50% threshold ships as a starting point. Add telemetry to see how often it fires and whether the cutoff needs adjusting.
4. **Channel detail surface** — tap behaviour on the channel-title header (member list, settings). Today it's a no-op.
5. **Role display in compose chips and thread-header participant tooltip** — called out as out-of-scope in the role-aware modal plan; same here.
