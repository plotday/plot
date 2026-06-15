# Two-Way Sync for Todoist, Jira, and Asana — Design

Status: approved (brainstorming) — 2026-06-14
Scope owner: Kris Braun
Reference connector: `public/connectors/linear`

## Goal

Bring the **Todoist**, **Jira**, and **Asana** connectors to full two-way (bidirectional)
sync parity with the Linear connector. Linear is the gold standard and the pattern to
follow throughout. Notion is explicitly **out of scope** (its source only exists on an
unmerged `notion-source` branch — it would be a from-scratch merge, not a completion).

"Two-way sync" means every change a user makes in Plot on a connector-owned thread is
written back to the external service, across four surfaces, plus reactions where the
platform supports them:

1. **Create item** — make a new external task/issue from a Plot thread.
2. **Update item** — write title / assignee / status changes back.
3. **Comment** — post a Plot note back as an external comment.
4. **Edit** — push a local note edit (comment body and/or item description) back.
5. **React** — per-user emoji reaction write-back via `onNoteReactionChanged` (Asana only;
   see Reactions).

## Scope decisions (confirmed with Kris)

- **Depth:** maximum — core write-back parity + webhook hardening + file attachments
  where the API allows.
- **Status model:** **expand** each connector beyond the current 2-state Open/Done to a
  richer per-provider model, surfaced as dynamic per-channel `linkTypes` exactly as Linear
  surfaces per-team workflow states.
- **Reactions:** implement only where the platform has a real API. That is **Asana only**
  (a single like/heart), via `onNoteReactionChanged`. **Jira** has no public reactions API;
  **Todoist** reactions are read-only/undocumented — both get **no** reaction support.

## Current state vs. Linear (audit summary)

| Surface | Todoist | Jira | Asana |
| --- | --- | --- | --- |
| `handleReplies = true` | ✅ | ✅ | ❌ missing |
| write scopes + `access` copy | ✅ | ✅ | ✅ |
| Create item (`compose` + `onCreateLink`) | ❌ | ❌ | ❌ |
| Update (`onLinkUpdated`) | ⚠️ status only | ❌ `updateIssue()` exists but **never wired** | ⚠️ wired, assignee **broken** |
| Comment create (`onNoteCreated` + baseline) | ✅ | ✅ | ❌ helper exists, not wired, no baseline |
| Comment/desc edit (`onNoteUpdated`) | ⚠️ comment only | ⚠️ comment only | ❌ missing |
| Inbound webhook | ✅ | ✅ no sig verify | ✅ secret-storage bug |
| Reactions | n/a | n/a | ❌ |

The universal gap is **item creation** — none of the three have it. Asana is furthest
behind; Jira already has working write-back logic that is simply not hooked up.

## Shared patterns (apply to all three, copied from Linear)

- **Dynamic per-channel statuses in `getChannels()`** — fetch each project's real states /
  sections and emit them as per-channel `linkTypes` with `statuses[]` + a `compose.status`
  default. Inbound sync maps the external state to the matching status id; a category
  fallback (`unstarted`/`completed`/etc.) covers the static twist-level `linkTypes`.
- **`compose` block + `onCreateLink(draft)`** — the `compose` block makes the "Create new
  X" picker entry appear; `onCreateLink` creates the external item and returns a
  `NewLinkWithNotes` (never calls `saveLink` itself). Bind the opening note to the item
  description via `originatingNote: { key: "description", externalContent }` so description
  edits round-trip.
- **`onLinkUpdated(link)`** — write title + assignee + status. Assignee uses an
  email→external-user-id lookup cached under `<provider>_user:<email>` (Linear pattern),
  because `link.assignee.id` is a Plot contact id, not the provider's user id. Best-effort:
  a failed write is reconciled on the next sync-in (external is source of truth).
- **`onNoteCreated` / `onNoteUpdated` return `NoteWriteBackResult`** whose `externalContent`
  **exactly equals what that connector's sync-in path emits** for the note (the
  baseline-hash contract). Match the sync-in transform precisely (plain-text for Todoist,
  ADF round-trip for Jira) so the next sync-in doesn't clobber Plot's content.
- **File attachments** — inbound: emit `ActionType.fileRef` actions + implement
  `downloadAttachment(ref)`; outbound: upload files attached to a note where the API
  supports it.
- **Sync metadata** — every saved link carries `link.channelId` and
  `meta.syncProvider` / `meta.syncableId` so bulk archive-on-disable keeps working.
- **No SDK changes.** All required types (`CreateLinkDraft`, `NoteWriteBackResult`,
  `originatingNote`, `compose`, `supportsFileAttachments`, `ReactionCapabilities`,
  `onNoteReactionChanged`, `ActionType.fileRef/file`, `downloadAttachment`) already exist
  and are exercised by Linear / Slack. Therefore **no changeset** (changesets are only for
  `twister/`). If a genuine SDK gap appears mid-build, it becomes a separate twister change
  with its own changeset — flagged, not silently added.

## Per-connector work

### Todoist (`public/connectors/todoist`)

Closest to done — already has comment create/edit with baselines, webhook + HMAC, correct
`source`. Remaining:

- **Status expansion:** expose each project's **sections** as statuses (plus Open/Done).
  Inbound maps `section_id` → status and `is_completed` → done; write-back updates
  `section_id` via task update and close/reopen for done.
- **`api.ts`:** add `createTask`, `updateTask` (title, `responsible_uid` assignee,
  `section_id`, etc.), `listSections`, and file upload (`/uploads` → comment `attachment`).
- **`onCreateLink`** — create a task; return link + `originatingNote` description baseline.
- **`onLinkUpdated`** — extend beyond close/reopen to also write title + assignee (via the
  project collaborators list, email→`responsible_uid`) + section.
- **`onNoteUpdated`** — add a `note.key === "description"` path to edit the task content.
- **Webhook:** handle `note:updated` (comment edits inbound); backfill existing comments on
  initial sync (currently only go-forward comments arrive via webhook).
- **File attachments:** inbound attachment → `fileRef` + `downloadAttachment`; outbound
  upload on comment via `/uploads`. (Best-effort — confirm the uploads endpoint during
  implementation; document if it can't be done cleanly.)

### Jira (`public/connectors/jira`)

Has comment write-back; its status/assignee write-back is **dead code**. Remaining:

- **Wire `onLinkUpdated`** — the single biggest fix. Add the method and call the existing
  `updateIssue()`. Improve it: resolve the target status to a real **transition**
  (map by target status id/name from `getTransitions`, not a hardcoded English-name
  heuristic) and resolve assignee via `user/search?query=<email>` → `accountId` (cached).
- **Status expansion:** fetch per-project statuses (createmeta / `project/{id}/statuses`),
  map `statusCategory` (`new`/`indeterminate`/`done`) → `StatusIcon`. Inbound uses the real
  status instead of `resolutiondate ? "done" : "open"`.
- **`compose` + `onCreateLink`** — resolve the project's default issue type (createmeta);
  create the issue; return link + description baseline.
- **`onNoteUpdated`** — add a description-edit path (issue `fields.description` as ADF).
- **ADF baseline symmetry** — make `convertTextToADF` / `extractTextFromADF` round-trip
  exactly so `externalContent` matches sync-in output (no per-sync clobber).
- **Webhook signature verification** — verify inbound webhooks (today they're accepted
  unverified). Use the registration secret / callback-token mechanism available to dynamic
  webhooks; document the exact method chosen.
- **File attachments:** inbound issue attachments → `fileRef` + `downloadAttachment`;
  outbound upload to the issue (multipart, `X-Atlassian-Token: no-check`) referenced from
  the note.

### Asana (`public/connectors/asana`)

Furthest behind — effectively read-only with a broken partial write path. Remaining:

- **`handleReplies = true`** — currently missing, which kills all reply/note/reaction
  dispatch. This is a prerequisite for everything else.
- **Status expansion:** expose project **sections** as statuses (plus Done via the
  `completed` boolean). Inbound maps `memberships[].section` → status; write-back moves the
  task to the target section (`sections.addTask`) and sets `completed`.
- **Fix assignee mapping** — replace the broken `link.assignee.id` with an email→Asana user
  GID lookup (workspace users / typeahead), cached. Fix `onLinkUpdated`.
- **`onNoteCreated`** — add the real method (wire the existing `addIssueComment`), return a
  `NoteWriteBackResult` whose `externalContent` is the plain text Asana stores on the story.
- **`onNoteUpdated`** — **description only** (`task.html_notes`/`notes`). Asana stories
  (comments) are immutable via the API, so comment-edit write-back is **not possible** and
  is documented as an explicit gap.
- **`compose` + `onCreateLink`** — create a task; return link + description baseline.
- **Fix webhook secret bug** — store the real `X-Hook-Secret` from the handshake and use it
  as the HMAC key (today it incorrectly uses the webhook GID).
- **File attachments:** inbound task attachments → `fileRef` + `downloadAttachment`;
  outbound upload to the task (multipart) referenced from the note.

## Reactions (Asana only)

Asana's only reaction is the single **like/heart** (`liked` boolean on tasks and stories).
It is per-user and writable for the authenticated user — exactly the semantics
`onNoteReactionChanged` expects. Implement it like Slack/ms-teams, **not** via
`onNoteUpdated`:

- **Capability:** `readonly reactionCapabilities = { mode: "fixed", allowed: ["👍"] }` so
  Plot only offers the one emoji Asana can store.
- **Outbound:** `onNoteReactionChanged(note, thread, actor, emoji, added)` → `PUT` `liked`
  on the target story (`stories/{gid}`); a reaction on the description note likes the task
  (`tasks/{gid}`). Only toggles the acting user's own like (Asana limitation).
- **Inbound:** during sync, read the story's `likes[]` array (each `{gid, user}`) and emit
  `NewNote.reactions = { "👍": [<liker actors>] }` — proper per-user, like Slack. No
  reliable like webhook exists, so inbound likes refresh on the next sync of the task, not
  in real time (documented).
- **Loop prevention:** ignore reactions whose actor is the twist itself.

**Jira** and **Todoist:** no reaction support (no usable API), so no
`onNoteReactionChanged` and no `reactionCapabilities`.

## Constraints / non-goals (documented, not fought)

- Asana comments/stories cannot be edited via API → `onNoteUpdated` handles **description
  only** for Asana.
- Asana likes have no dedicated webhook → inbound likes are eventually-consistent (refresh
  on next sync).
- Todoist comment file attachments depend on the `/uploads` endpoint → best-effort; if it
  can't be done cleanly, inbound-only + documented gap.
- Jira/Todoist reactions, and Notion entirely → out of scope.
- **No status-history migration.** Expanding the status model changes how inbound sync
  labels statuses; existing synced threads re-label on their next sync-in (external is
  source of truth). This is acceptable and expected.

## Verification

- Per connector: `pnpm build` + `pnpm exec tsc --noEmit` + `plot lint` all clean; repo-root
  `pnpm install` clean.
- Code review of each connector diff against the Linear pattern and the connector
  `AGENTS.md` checklist.
- **Live E2E is limited** — exercising the real round-trips needs connected
  Todoist / Atlassian / Asana OAuth accounts, which only Kris has. Static gates + review are
  the gate; live verification (and any `run-app` surfacing of the new "Create new X" compose
  entries) is flagged as a follow-up requiring real connections. No deploys (local only).

## Mechanics

- **Workspace:** git worktree `connector-two-way-sync`; connectors live in the `public/`
  submodule, on branch `feat/connector-two-way-sync` (off `7065d2e`, on `origin/main`).
- **Deliverable:** a **public-submodule PR** (3 connectors) + a submodule-ref bump commit in
  core. No twister change ⇒ no changeset.
- **Docs:** add a user-facing bullet to `docs/updates.md` (create Jira/Asana/Todoist items
  from Plot; two-way status, comment, and — for Asana — reaction sync) and refresh
  `docs/features.md` if warranted, per `/finalize`.
- The three connectors are independent ⇒ implement in parallel, verifying each in isolation.

## Open implementation questions (resolve during build, not blocking design)

- Jira dynamic-webhook signature mechanism — confirm whether a registration secret or the
  callback-token URL is the right verification handle.
- Todoist `/uploads` + comment `attachment` shape — confirm the exact request and whether
  Workers `fetch` multipart works without extra polyfills.
- Asana section-as-status for projects with **no** sections — fall back to Open/Done so
  section-less projects still work.
