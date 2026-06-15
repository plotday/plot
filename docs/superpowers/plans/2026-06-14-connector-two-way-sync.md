# Two-Way Sync for Todoist / Jira / Asana — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Todoist, Jira, and Asana connectors to Linear-level two-way sync —
create / update / comment / edit write-back, expanded per-provider status models, Asana like
reactions via `onNoteReactionChanged`, file attachments, and inbound webhook fixes.

**Architecture:** Each connector is an independent package under `public/connectors/<name>`
that extends `Connector` and persists via `integrations.saveLink()`. Linear
(`public/connectors/linear/src/linear.ts`) is the reference implementation for every surface.
The three connectors share no code, so they are implemented as three independent per-connector
passes (each touches only its own `src/*.ts` + a new test file) and can run in parallel.

**Tech Stack:** TypeScript, Cloudflare Workers runtime, `@plotday/twister` SDK, vitest. Todoist
uses raw `fetch` (REST v2 + Sync v9); Jira uses `jira.js` v4.0.2 (`Version3Client`); Asana uses
`asana` v2.0.6 (`asana.Client` wrapper, typed by `@types/asana@0.18.17`).

**Spec:** `docs/superpowers/specs/2026-06-14-connector-two-way-sync-design.md`

---

## Testing strategy (read first — deliberate domain adaptation)

Connectors are SDK glue running in a Workers runtime; their write-back methods can only be
fully exercised against live OAuth accounts. So this plan applies TDD where it has real value
and gates the rest on the compiler + lint + review:

- **TDD (vitest, test-first)** for **pure functions**: status/category↔icon mapping, ADF
  round-trip symmetry, section→status mapping, like/emoji mapping, email→id map building,
  webhook HMAC verification. These are the bug-prone parts and they're unit-testable.
- **Compiler + lint + review** for **SDK-wiring methods** (`onCreateLink`, `onLinkUpdated`,
  `onNoteCreated/Updated`, `onNoteReactionChanged`, webhook handlers, attachment upload):
  verified by `pnpm build` (tsc, 0 errors) + `pnpm exec tsc --noEmit` + `plot lint`, and
  reviewed against the Linear pattern and the connector `AGENTS.md` checklist. Live E2E is a
  flagged follow-up requiring Kris's connected accounts.

**Per-connector definition of done:** `pnpm build` exits 0, `plot lint` clean, all vitest tests
pass, and every checklist item in `public/connectors/AGENTS.md` "Bidirectional sync" is
satisfied or has a documented gap.

**Verification commands (run from `public/`):**

```bash
# build + typecheck one connector
( cd connectors/<name> && pnpm build && pnpm exec tsc --noEmit )
# lint
( cd connectors/<name> && pnpm lint )
# tests
( cd connectors/<name> && pnpm test )
```

---

## File map

| Connector | Files modified | Files created |
| --- | --- | --- |
| Todoist | `src/todoist.ts`, `src/api.ts`, `package.json`, `README.md` | `src/todoist.test.ts`, `vitest.config.ts` |
| Jira | `src/jira.ts`, `package.json`, `README.md` | `src/jira-adf.ts` (extract ADF helpers), `src/jira.test.ts`, `vitest.config.ts` |
| Asana | `src/asana.ts`, `package.json`, `README.md` | `src/asana.test.ts`, `vitest.config.ts` |
| Core | `docs/updates.md`, `docs/features.md` (worktree root, not submodule) | — |

`src/jira-adf.ts` is a new small module so the ADF transform pair (`textToADF` / `adfToText`)
can be unit-tested in isolation and kept symmetric — `jira.ts` has grown to ~1000 lines and the
transform is the one piece that must round-trip exactly.

---

## Verified SDK reference (use these exact signatures)

### Todoist — raw `fetch` via the existing `request<T>(token, path, init)` helper in `api.ts`

`request()` routes `/sync/*` paths to `https://api.todoist.com/sync/v9`, everything else to
`https://api.todoist.com/rest/v2`; injects `Authorization: Bearer`; throws
`Todoist API error <status>: <text>`; returns parsed JSON (or `undefined` on 204).

- Create: `POST /tasks` body `{content, description?, project_id?, section_id?, due_string?, priority?, labels?, assignee_id?}` → `TodoistTask`.
- Update: `POST /tasks/{id}` same fields incl. `section_id`, `assignee_id` (REST v2 supports
  `section_id` directly — no Sync `item_move` needed). Assignee field is **`assignee_id`** in
  REST v2 (not `responsible_uid`).
- Sections: `GET /sections?project_id={id}` → `TodoistSection[] = {id, project_id, order, name}`.
- Upload (multipart, bypass `request()`): `POST https://api.todoist.com/sync/v9/uploads/add`,
  `FormData` fields `file` (Blob) + `file_name` → `{file_url, file_type, ...}`.
- Comment + attachment: `POST /comments` body `{task_id, content, attachment?:{file_name,file_type,file_url,resource_type:"file"}}`.
- Collaborators (existing `listCollaborators`): `{id, name, email}` — build email→`assignee_id` map.

### Jira — `jira.js` v4.0.2 `Version3Client` (`client.*`)

- Create: `client.issues.createIssue({ fields: { summary, project:{id}, issuetype:{id|name}, description?: ADF, assignee?: {id: accountId} } })` → `{id, key, self}`.
- Issue types (default for create): `client.issues.getCreateIssueMetaIssueTypes({ projectIdOrKey })` → `{issueTypes:[{id,name,subtask}]}`.
- Project statuses: `client.projects.getAllStatuses({ projectIdOrKey })` → `IssueTypeWithStatus[] = [{name, statuses:[{id,name,statusCategory:{key:"new"|"indeterminate"|"done"}}]}]`.
- Transitions: `client.issues.getTransitions({ issueIdOrKey })` → `{transitions:[{id,name,to:{id,name,statusCategory:{key}}}]}`; apply `client.issues.doTransition({ issueIdOrKey, transition:{id} })`.
- Edit fields: `client.issues.editIssue({ issueIdOrKey, fields:{ summary?, description?: ADF, assignee?: {id: accountId} | null } })`.
- User search: `client.userSearch.findUsers({ query: email })` → `User[]` with `{accountId, emailAddress?, displayName}`.
- Comment update (existing): `client.issueComments.updateComment({ issueIdOrKey, id, body: ADF })` → `Comment` (`body` is ADF).
- Attachment add: `client.issueAttachments.addAttachment({ issueIdOrKey, attachment:{ filename, file: Blob|Buffer, mimeType? } })` → `Attachment[]` (`{id, filename, content (URL), mimeType}`).
- Attachment list: read `client.issues.getIssue({ issueIdOrKey, fields:["attachment"] })` → `fields.attachment[] = {id, filename, mimeType, content (download URL), size}`.
- Attachment download: `client.issueAttachments.getAttachmentContent({ id })` → `Buffer`. (For
  `downloadAttachment` prefer redirecting to the `content` URL with auth, mirroring Linear's
  redirect approach; document the auth-header constraint.)

### Asana — `asana` v2.0.6 (`asana.Client.create().useAccessToken(token)`), typed by `@types/asana@0.18.17` (`node_modules/.pnpm/@types+asana@0.18.17/.../index.d.ts`)

- Create: `client.tasks.createInWorkspace(workspaceGid, { name, html_notes?, assignee?, completed?, projects:[gid], memberships?:[{project, section}] })` → `Tasks.Type`. (Need the
  project's workspace gid — cache it per channel during `getChannels`/sync.)
- Update: `client.tasks.updateTask(taskGid, { name?, html_notes?, assignee?: gid|null, completed?, liked? })` → `Tasks.Type`. **Arg order: gid first, data second.**
- Read task (incl. section + likes): `client.tasks.getTask(taskGid, { opt_fields: "name,completed,assignee.email,assignee.name,memberships.project.gid,memberships.section.gid,memberships.section.name,liked,num_likes,likes.user.gid,likes.user.name" })`.
- Sections: list `client.sections.findByProject(projectGid)` → `[{gid,name}]`; move
  `client.sections.addTask(sectionGid, { task: taskGid })`.
- Comment create: `client.tasks.addComment(taskGid, { text })` → `Stories.Type` (`{gid, text, html_text, created_by, created_at, liked, num_likes, likes}`).
- Comment edit: **not possible** — `Stories` has no update method (immutable). Documented gap.
- **Story like (no typed method):** `client.dispatcher.put("/stories/" + storyGid, { liked: <bool> })`.
- **Task like:** `client.tasks.updateTask(taskGid, { liked: <bool> })`.
- Read who liked: the `likes` array (`[{gid, user:{gid,name}}]`) + `num_likes` + `liked` (opt_fields above).
- Users (email→gid): `client.users.findByWorkspace(workspaceGid, { opt_fields: "email,name" })` → filter by email. Cache the map.
- Attachments list/read: `client.attachments.findByTask(taskGid)` → `[{gid,name,download_url}]`; `client.attachments.findById(gid, { opt_fields: "name,download_url" })`.
- **Attachment upload (no typed method):** raw multipart `fetch("https://app.asana.com/api/1.0/attachments", { method:"POST", headers:{Authorization:`Bearer ${token}`}, body: FormData[parent=taskGid, file=Blob] })`.

---

## Phase 0: Shared test infrastructure (do once per connector, before its phase)

### Task 0.x: Add vitest to `<connector>` (todoist, jira, asana)

**Files:**
- Create: `connectors/<name>/vitest.config.ts`
- Modify: `connectors/<name>/package.json`

- [ ] **Step 1: Create `vitest.config.ts`** (identical to slack's):

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
```

- [ ] **Step 2: Add the `test` script + `vitest` devDep to `package.json`.** Add
  `"test": "vitest run"` and `"test:watch": "vitest"` to `scripts`, and
  `"vitest": "^3.2.4"` to `devDependencies` (match the version slack uses — check
  `connectors/slack/package.json`).

- [ ] **Step 3: Install + smoke-test.** From `public/`:

```bash
pnpm install
( cd connectors/<name> && pnpm test )   # expect: "No test files found" (exit 0) until tests exist
```

- [ ] **Step 4: Commit.**

```bash
git add connectors/<name>/vitest.config.ts connectors/<name>/package.json
git commit -m "test(<name>): add vitest harness"
```

---

## Phase 1: Todoist

Order within the phase: api.ts additions → status expansion (pure, TDD) → onCreateLink →
onLinkUpdated → onNoteUpdated description → webhook note:updated + comment backfill →
attachments. Anchor lines below are from the audit (~); re-locate before editing.

### Task 1.1: Extend `api.ts` with create/update/sections/upload

**Files:** Modify `connectors/todoist/src/api.ts`

- [ ] **Step 1:** Add the `TodoistSection`, `TodoistCommentAttachment` types and extend
  `TodoistTask`/`TodoistComment` if needed (add `section_id` to task type if absent).

- [ ] **Step 2:** Add `createTask`, `updateTask`, `listSections`, `uploadFile`, and extend
  `createComment` with an optional `attachment` arg — all in the existing `request<T>()` style
  (see the Verified SDK reference; `uploadFile` bypasses `request()` for multipart). Match the
  existing file's conditional-field-inclusion style.

- [ ] **Step 3:** Verify: `( cd connectors/todoist && pnpm exec tsc --noEmit )` → 0 errors.

- [ ] **Step 4:** Commit `feat(todoist): api.ts create/update/sections/upload helpers`.

### Task 1.2: Section-as-status model (TDD)

**Files:** Modify `connectors/todoist/src/todoist.ts`; Test `connectors/todoist/src/todoist.test.ts`

Status set per channel = the project's sections (each section is a status whose `status` id is
the section id, `icon: "todo"`) **plus** a terminal `done` (icon `done`, `done:true`) and an
`open` fallback (icon `todo`) for tasks with no section. A completed task → `done`; otherwise →
its `section_id` (or `open`).

- [ ] **Step 1: Write failing test** for a pure `mapTaskStatus(task, sections)` helper:

```typescript
import { describe, it, expect } from "vitest";
import { mapTaskStatus } from "./todoist";

describe("mapTaskStatus", () => {
  it("returns 'done' for completed tasks regardless of section", () => {
    expect(mapTaskStatus({ is_completed: true, section_id: "123" } as any, [])).toBe("done");
  });
  it("returns the section id for an open task in a section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: "123" } as any, [])).toBe("123");
  });
  it("returns 'open' for an open task with no section", () => {
    expect(mapTaskStatus({ is_completed: false, section_id: null } as any, [])).toBe("open");
  });
});
```

- [ ] **Step 2:** Run `( cd connectors/todoist && pnpm test )` → FAIL (mapTaskStatus undefined).

- [ ] **Step 3:** Implement and `export` `mapTaskStatus` in `todoist.ts`. Wire it into the
  inbound conversion (replace the current `is_completed ? "done" : "open"` mapping).

- [ ] **Step 4:** In `getChannels`, for each project fetch `listSections` and build the
  per-channel `linkTypes[0].statuses` = `[{status:"open",label:"Open",icon:"todo"}, ...sections
  as {status: section.id, label: section.name, icon:"todo"}, {status:"done",label:"Done",
  done:true,icon:"done"}]`, with `compose: { status: "open" }`. Mirror Linear `getChannels`
  (linear.ts:200-250) — dynamic per-channel statuses + repeated `sharingModel`.

- [ ] **Step 5:** Run tests → PASS; `pnpm build` → 0 errors.

- [ ] **Step 6:** Commit `feat(todoist): expose sections as statuses`.

### Task 1.3: `compose` + `onCreateLink`

**Files:** Modify `connectors/todoist/src/todoist.ts`

- [ ] **Step 1:** Add `compose: { status: "open" }` to the static twist-level `linkTypes[0]`.
- [ ] **Step 2:** Implement `onCreateLink(draft)` mirroring Linear (linear.ts:710-776):
  resolve `draft.channelId` → project; `createTask(token, draft.title, { project_id, description: draft.noteContent ?? undefined, section_id: <draft.status unless "open"/"done"> })`;
  return `NewLinkWithNotes` with `source: "todoist:task:" + task.id`, `meta:{taskId,projectId,syncProvider:"todoist"}`, `sourceUrl: task.url`, and
  `originatingNote: { key:"description", externalContent: task.description ?? undefined }`.
  Do NOT call `saveLink`.
- [ ] **Step 3:** Build → 0 errors. Commit `feat(todoist): create tasks from Plot (onCreateLink)`.

### Task 1.4: Extend `onLinkUpdated` (title + assignee + section)

**Files:** Modify `connectors/todoist/src/todoist.ts` (current onLinkUpdated ~512-525)

- [ ] **Step 1:** Add a cached email→`assignee_id` resolver: `listCollaborators(token, projectId)`
  → `Map`, cached under store key `todoist_user:<projectId>:<email>` (mirror Linear's
  `linear_user:<email>` cache, linear.ts:806-817).
- [ ] **Step 2:** Extend `onLinkUpdated` to call `updateTask(token, taskId, { content: link.title ?? undefined, assignee_id: <resolved|null>, section_id: <link.status unless open/done> })`
  and still close/reopen for the `done` terminal. Best-effort try/catch with `console.error`
  (mirror Linear onLinkUpdated:300-316).
- [ ] **Step 3:** Build → 0 errors. Commit `feat(todoist): write title/assignee/section back`.

### Task 1.5: `onNoteUpdated` description edit

**Files:** Modify `connectors/todoist/src/todoist.ts` (current onNoteUpdated ~559-576)

- [ ] **Step 1:** Make the description note editable: in inbound conversion give the description
  note `key: "description"` (confirm it already does; if it's read-only, keep the key).
- [ ] **Step 2:** Add a branch to `onNoteUpdated`: `if (note.key === "description") { updateTask(token, taskId, { description: markdownToPlainText(note.content ?? "") }); return { externalContent: <plain text> }; }` — `externalContent` must equal what sync-in emits
  for the description note (run the same `markdownToPlainText`/passthrough the inbound path
  uses; inspect the inbound description note to match exactly).
- [ ] **Step 3:** Build → 0 errors. Commit `feat(todoist): edit task description from Plot`.

### Task 1.6: Webhook `note:updated` + initial comment backfill

**Files:** Modify `connectors/todoist/src/todoist.ts` (webhook ~274-387, syncBatch ~205-269)

- [ ] **Step 1:** Add a `note:updated` case to the webhook switch that upserts the edited comment
  note (same shape as the existing `note:added` handler, `key: "comment-" + id`).
- [ ] **Step 2:** In `syncBatch`, after building the task link, fetch the task's existing comments
  (`GET /comments?task_id={id}`) and include them as `comment-<id>` notes so history backfills
  on initial sync (today only go-forward comments arrive via webhook). Respect `initialSync`
  (omit `unread`/`archived` appropriately).
- [ ] **Step 3:** Build → 0 errors. Commit `feat(todoist): sync comment edits + backfill comment history`.

### Task 1.7: File attachments

**Files:** Modify `connectors/todoist/src/todoist.ts`

- [ ] **Step 1:** Inbound — when a comment has an `attachment` with a `file_url`, emit an
  `ActionType.fileRef` action (cache `todoist:att:<id> → projectId`-style mapping is unnecessary
  since the url is direct; instead emit an `ActionType.external` link to the file, OR a `fileRef`
  + implement `downloadAttachment` that redirects to the stored url). Choose the redirect-to-url
  approach mirroring Linear's `downloadAttachment` (linear.ts:1204-1221); store url under
  `todoist:att-url:<ref>`.
- [ ] **Step 2:** Outbound — in `onNoteCreated`, for each `ActionType.file` action: read the file
  via `this.tools.files.read(action.fileId)`, `uploadFile(token, blob, fileName)`, then pass the
  returned `file_url` as the comment `attachment`. Mirror Linear's `addIssueComment` file loop
  (linear.ts:909-980). Add `files: build(Files)` to `build()` and
  `supportsFileAttachments: true` to the linkType.
- [ ] **Step 3:** Build → 0 errors. Commit `feat(todoist): comment file attachments (in + out)`.
- [ ] **Step 4:** Run full connector gate: `pnpm build && pnpm exec tsc --noEmit && pnpm lint && pnpm test`. All clean. Update `README.md` two-way-sync notes if present.

---

## Phase 2: Jira

Order: wire onLinkUpdated (highest value) → ADF module (pure, TDD) → status expansion (pure,
TDD) → onCreateLink → onNoteUpdated description → webhook signature verification → attachments.

### Task 2.1: Extract + symmetrize ADF transforms (TDD)

**Files:** Create `connectors/jira/src/jira-adf.ts`; Test `connectors/jira/src/jira.test.ts`;
Modify `connectors/jira/src/jira.ts` (move `convertTextToADF`/`extractTextFromADF` out, ~589-614,
~794-811)

The baseline contract: `adfToText(textToADF(s)) === s.trim()` for representative inputs, so
`externalContent` (post-write `adfToText(stored)`) matches sync-in (`adfToText(incoming)`).

- [ ] **Step 1: Write failing tests** for the pair:

```typescript
import { describe, it, expect } from "vitest";
import { textToADF, adfToText } from "./jira-adf";

describe("ADF round-trip", () => {
  for (const s of ["hello", "para one\n\npara two", "line", "a\n\nb\n\nc"]) {
    it(`round-trips ${JSON.stringify(s)}`, () => {
      expect(adfToText(textToADF(s))).toBe(s.trim());
    });
  }
  it("textToADF makes one paragraph per blank-line block", () => {
    expect(textToADF("a\n\nb").content).toHaveLength(2);
  });
});
```

- [ ] **Step 2:** Run → FAIL (module missing).
- [ ] **Step 3:** Implement `textToADF`/`adfToText` in `jira-adf.ts` so they round-trip exactly
  (paragraphs joined by `\n\n`, `adfToText` trims; ensure `adfToText` joins paragraphs with
  `\n\n`, not a trailing `\n` per paragraph — fix the current asymmetry). Re-export from
  `jira.ts` and replace the inline copies so all call sites use the shared pair.
- [ ] **Step 4:** Run tests → PASS; build → 0 errors.
- [ ] **Step 5:** Commit `refactor(jira): extract symmetric ADF transform with round-trip tests`.

### Task 2.2: Wire `onLinkUpdated` + status-aware transitions + assignee lookup

**Files:** Modify `connectors/jira/src/jira.ts` (orphaned `updateIssue` ~619-690)

- [ ] **Step 1:** Add `async onLinkUpdated(link: Link): Promise<void>` that try/catches a call to
  the existing `updateIssue(link)` (mirror Linear onLinkUpdated:300-316). This alone resurrects
  dead code.
- [ ] **Step 2:** Improve `updateIssue`:
  - Title/description/assignee via `client.issues.editIssue({ issueIdOrKey, fields })`. Assignee:
    resolve `link.assignee.email` → `accountId` via `client.userSearch.findUsers({query:email})`,
    cached under `jira_user:<email>` (mirror Linear:806-817); `null` to unassign.
  - Status: fetch `client.issues.getTransitions`, pick the transition whose
    `to.id === link.status` (status ids now come from the expanded model — Task 2.3); fall back
    to `to.statusCategory.key` match for category statuses. Apply via `doTransition`. Replace the
    English-name heuristic.
- [ ] **Step 3:** Build → 0 errors. Commit `fix(jira): wire onLinkUpdated; status via transition id + assignee by email`.

### Task 2.3: Expand status model (TDD for the mapping)

**Files:** Modify `connectors/jira/src/jira.ts`; Test `connectors/jira/src/jira.test.ts`

- [ ] **Step 1: Failing test** for `statusCategoryToIcon(key)`:

```typescript
import { statusCategoryToIcon } from "./jira";
it("maps status categories to icons", () => {
  expect(statusCategoryToIcon("new")).toBe("todo");
  expect(statusCategoryToIcon("indeterminate")).toBe("inProgress");
  expect(statusCategoryToIcon("done")).toBe("done");
});
```

- [ ] **Step 2:** Run → FAIL. Implement+export `statusCategoryToIcon` (default `"todo"`).
- [ ] **Step 3:** In `getChannels`, for each project call `client.projects.getAllStatuses`,
  flatten/dedupe statuses across issue types into per-channel `statuses[]` (`status: status.id`,
  `label: status.name`, `icon: statusCategoryToIcon(statusCategory.key)`, `done:true` when
  category is `done`), with `compose: { status: <first "new" status id> }`. Mirror Linear's
  per-channel dynamic linkTypes.
- [ ] **Step 4:** Inbound (`convertIssueToLink` ~462-584): set `status` to the issue's real
  `fields.status.id` instead of `resolutiondate ? "done" : "open"`.
- [ ] **Step 5:** Tests PASS; build 0 errors. Commit `feat(jira): per-project workflow statuses`.

### Task 2.4: `compose` + `onCreateLink`

**Files:** Modify `connectors/jira/src/jira.ts`

- [ ] **Step 1:** Add `compose` to the static linkType (`{ status: "new" }` symbolic; resolved in
  `onCreateLink`).
- [ ] **Step 2:** Implement `onCreateLink(draft)`: resolve project default issue type via
  `getCreateIssueMetaIssueTypes` (prefer a non-subtask named "Task", else first non-subtask);
  `createIssue({ fields:{ summary: draft.title, project:{id:draft.channelId}, issuetype:{id}, description: draft.noteContent ? textToADF(draft.noteContent) : undefined }})`; fetch the created
  issue for `key`/`self`; return `NewLinkWithNotes` with `source: "jira:" + cloudId + ":issue:" + id`,
  `meta:{issueKey,projectId,syncProvider:"atlassian"}`, and `originatingNote:{key:"description",
  externalContent: draft.noteContent ? adfToText(textToADF(draft.noteContent)) : undefined}`.
- [ ] **Step 3:** Build 0 errors. Commit `feat(jira): create issues from Plot (onCreateLink)`.

### Task 2.5: `onNoteUpdated` description edit

**Files:** Modify `connectors/jira/src/jira.ts` (onNoteUpdated ~712-745)

- [ ] **Step 1:** Add a `note.key === "description"` branch: `editIssue({ issueIdOrKey, fields:{description: textToADF(body)} })`, then `return { externalContent: adfToText(textToADF(body)) }`
  (must equal sync-in's description text — confirm the inbound description note runs
  `adfToText(fields.description)`; match it).
- [ ] **Step 2:** Build 0 errors. Commit `feat(jira): edit issue description from Plot`.

### Task 2.6: Webhook signature verification

**Files:** Modify `connectors/jira/src/jira.ts` (setupJiraWebhook ~204-268, onWebhook ~816-830)

Jira dynamic webhooks don't HMAC-sign by default. The robust handle: the connector already
registers a per-resource callback URL via `this.tools.network.createWebhook({}, this.onWebhook,
projectId)` whose token path is unguessable. Harden by (a) storing a random secret at
registration and including it as a query param on the registered URL, then (b) rejecting inbound
requests whose secret doesn't match.

- [ ] **Step 1:** In `setupJiraWebhook`, generate a random secret (`crypto.randomUUID()`), store
  under `webhook_secret_<projectId>`, and append `?secret=<s>` to the webhook URL registered with
  Jira.
- [ ] **Step 2:** In `onWebhook`, read the secret from the request query and compare to the
  stored value (constant-time compare); drop on mismatch. Document this approach (token-path +
  shared secret) in a comment, noting Jira provides no HMAC for dynamic webhooks.
- [ ] **Step 3:** Build 0 errors. Commit `feat(jira): verify inbound webhook via registration secret`.

### Task 2.7: File attachments

**Files:** Modify `connectors/jira/src/jira.ts`

- [ ] **Step 1:** Inbound — in `convertIssueToLink`, request `fields:["attachment"]` (or read
  `issue.fields.attachment`) and emit an `ActionType.fileRef` per attachment; cache
  `jira:att-project:<attId> → projectId`. Implement `downloadAttachment(ref)` →
  `getAttachmentContent({id:ref})` or redirect to the attachment `content` URL (mirror Linear
  1204-1221; note the URL needs auth — if redirect can't carry auth, stream the Buffer instead).
- [ ] **Step 2:** Outbound — in `addIssueComment`/`onNoteCreated`, for each `ActionType.file`:
  `this.tools.files.read(fileId)` → `client.issueAttachments.addAttachment({issueIdOrKey, attachment:{filename, file: blob, mimeType}})`. Add `files: build(Files)` and
  `supportsFileAttachments: true`.
- [ ] **Step 3:** Build 0 errors. Commit `feat(jira): issue file attachments (in + out)`.
- [ ] **Step 4:** Full gate: `pnpm build && pnpm exec tsc --noEmit && pnpm lint && pnpm test`.

---

## Phase 3: Asana (most rework)

Order: handleReplies → assignee fix + onLinkUpdated → onNoteCreated baseline → status (sections,
TDD) → onCreateLink → onNoteUpdated description → reactions (TDD inbound + onNoteReactionChanged)
→ webhook secret fix → attachments.

### Task 3.1: Enable reply dispatch + workspace caching

**Files:** Modify `connectors/asana/src/asana.ts`

- [ ] **Step 1:** Add `static readonly handleReplies = true;` (next to PROVIDER/SCOPES ~48-50).
  Without it, `onNoteCreated`/`onNoteUpdated`/`onNoteReactionChanged` never dispatch.
- [ ] **Step 2:** Ensure the project's workspace gid is cached per channel (needed by
  `createInWorkspace` and `users.findByWorkspace`). In `getChannels`/sync, store
  `asana_workspace:<projectId>`.
- [ ] **Step 3:** Build 0 errors. Commit `feat(asana): enable reply dispatch + cache workspace`.

### Task 3.2: Fix assignee mapping + `onLinkUpdated`

**Files:** Modify `connectors/asana/src/asana.ts` (updateIssue ~440-468)

- [ ] **Step 1:** Add cached email→gid resolver via `client.users.findByWorkspace(workspaceGid,
  {opt_fields:"email,name"})`, cached under `asana_user:<workspaceId>:<email>`.
- [ ] **Step 2:** Rewrite the assignee line in `updateIssue` from the broken
  `link.assignee?.id` to the resolved gid (or `null` to unassign). Keep `name`/`completed`.
- [ ] **Step 3:** Ensure an `onLinkUpdated` method exists and calls `updateIssue` in try/catch
  (mirror Linear:300-316) — confirm it's wired (audit said the helper exists but verify the
  lifecycle method is present).
- [ ] **Step 4:** Build 0 errors. Commit `fix(asana): resolve assignee by email; wire onLinkUpdated`.

### Task 3.3: `onNoteCreated` with baseline

**Files:** Modify `connectors/asana/src/asana.ts` (addIssueComment ~476-497)

- [ ] **Step 1:** Add `async onNoteCreated(note, thread): Promise<NoteWriteBackResult | void>`
  that calls `addIssueComment(thread.meta ?? {}, note.content ?? "", <file actions>)`.
- [ ] **Step 2:** Change `addIssueComment` to return `NoteWriteBackResult`:
  `client.tasks.addComment(taskGid, { text: body })` → return `{ key: "story-" + story.gid,
  externalContent: story.text ?? body }`. `externalContent` must equal what the inbound story
  path emits for this note (Asana stores plain `text`; confirm inbound emits `story.text` and
  match it). Mirror Linear onNoteCreated:855-980.
- [ ] **Step 3:** Build 0 errors. Commit `feat(asana): post comments from Plot with sync baseline`.

### Task 3.4: Section-as-status model (TDD)

**Files:** Modify `connectors/asana/src/asana.ts`; Test `connectors/asana/src/asana.test.ts`

Status set = project sections (status id = section gid) + terminal `done` (the `completed`
boolean) + `open` fallback. Inbound: `completed` → `done`; else the task's section gid within
this project (from `memberships`); else `open`.

- [ ] **Step 1: Failing test** for `mapTaskStatus(task, projectGid)`:

```typescript
import { mapTaskStatus } from "./asana";
it("done when completed", () => {
  expect(mapTaskStatus({ completed: true, memberships: [] } as any, "P")).toBe("done");
});
it("section gid when in a section of this project", () => {
  expect(mapTaskStatus(
    { completed: false, memberships: [{ project: { gid: "P" }, section: { gid: "S1" } }] } as any,
    "P",
  )).toBe("S1");
});
it("open when no section", () => {
  expect(mapTaskStatus({ completed: false, memberships: [] } as any, "P")).toBe("open");
});
```

- [ ] **Step 2:** Run → FAIL. Implement+export `mapTaskStatus`.
- [ ] **Step 3:** In `getChannels`, `client.sections.findByProject(projectGid)` → per-channel
  `statuses` (`open` + each section `{status: gid, label: name, icon:"todo"}` + `done`), with
  `compose:{status:"open"}`. Add `memberships.section.gid/name` to the task `opt_fields`
  everywhere tasks are fetched (sync + webhook), and use `mapTaskStatus` for inbound `status`.
- [ ] **Step 4:** Write-back section in `updateIssue`: when `link.status` is a section gid, call
  `client.sections.addTask(sectionGid, { task: taskGid })`; when `done`, set `completed:true`.
- [ ] **Step 5:** Tests PASS; build 0 errors. Commit `feat(asana): sections as statuses (in + out)`.

### Task 3.5: `compose` + `onCreateLink`

**Files:** Modify `connectors/asana/src/asana.ts`

- [ ] **Step 1:** Add `compose:{status:"open"}` to the linkType.
- [ ] **Step 2:** Implement `onCreateLink(draft)`:
  `client.tasks.createInWorkspace(workspaceGid, { name: draft.title, html_notes: <draft.noteContent as HTML or notes>, projects:[draft.channelId], memberships: <section if draft.status is a gid> })`; return `NewLinkWithNotes` with `source:"asana:task:"+task.gid`,
  `meta:{taskGid, projectId:draft.channelId, syncProvider:"asana"}`, and
  `originatingNote:{key:"description", externalContent: <task notes as stored>}`. Note Asana
  `html_notes` must be valid Asana-flavored HTML — if `draft.noteContent` is markdown/plain,
  use `notes` (plain) to avoid 400s; document the choice.
- [ ] **Step 3:** Build 0 errors. Commit `feat(asana): create tasks from Plot (onCreateLink)`.

### Task 3.6: `onNoteUpdated` (description only)

**Files:** Modify `connectors/asana/src/asana.ts`

- [ ] **Step 1:** Implement `onNoteUpdated`: only `note.key === "description"` →
  `client.tasks.updateTask(taskGid, { html_notes|notes: body })`, return `{externalContent: <stored notes>}`. For `story-*` keys, return void (comments immutable) — add a code comment
  citing the Asana API limitation.
- [ ] **Step 2:** Build 0 errors. Commit `feat(asana): edit task description from Plot (stories immutable)`.

### Task 3.7: Like reactions — inbound (TDD) + `onNoteReactionChanged`

**Files:** Modify `connectors/asana/src/asana.ts`; Test `connectors/asana/src/asana.test.ts`

Model Asana's single like as the `👍` reaction (`reactionCapabilities = { mode:"fixed",
allowed:["👍"] }`). Like a story for `story-*` notes, like the task for the `description` note.

- [ ] **Step 1: Failing test** for a pure `buildLikeReactions(likes)` → `NewReactions`:

```typescript
import { buildLikeReactions, LIKE_EMOJI } from "./asana";
it("maps likes[] to per-user reactions under the like emoji", () => {
  const r = buildLikeReactions([{ gid: "x", user: { gid: "u1", name: "A" } }] as any);
  expect(Object.keys(r)).toEqual([LIKE_EMOJI]);
  expect(r[LIKE_EMOJI]).toHaveLength(1);
  expect(r[LIKE_EMOJI][0].source?.accountId).toBe("u1");
});
it("returns empty object for no likes", () => {
  expect(buildLikeReactions([])).toEqual({});
});
```

- [ ] **Step 2:** Run → FAIL. Implement+export `LIKE_EMOJI = "👍"` and `buildLikeReactions`
  (each `like.user` → `NewActor` with `source:{accountId:user.gid}`, `name`).
- [ ] **Step 3:** Inbound: when building story/task notes, attach `reactions: buildLikeReactions(likes)` (fetch `likes.user.gid/name` + `num_likes` + `liked` via opt_fields). Set
  `readonly reactionCapabilities = { mode:"fixed", allowed:[LIKE_EMOJI] }` on the class.
- [ ] **Step 4:** Outbound: implement `async onNoteReactionChanged(note, thread, actor, emoji, added)`:
  ignore if `actor.type === ActorType.Twist`; for `note.key === "description"` →
  `client.tasks.updateTask(taskGid, { liked: added })`; for `note.key` matching `story-(.+)` →
  `client.dispatcher.put("/stories/" + gid, { liked: added })`. try/catch with `console.warn`
  (mirror Slack onNoteReactionChanged / ms-teams).
- [ ] **Step 5:** Tests PASS; build 0 errors. Commit `feat(asana): like reactions via onNoteReactionChanged + inbound likes`.

### Task 3.8: Fix webhook secret + verification (TDD the HMAC)

**Files:** Modify `connectors/asana/src/asana.ts` (handshake ~547, verify ~503-535, onWebhook ~540)

Today the HMAC uses the webhook GID, not the real `X-Hook-Secret`. Asana sends the secret once,
in the handshake response header; it must be captured and stored.

- [ ] **Step 1: Failing test** for `verifyAsanaSignature(sig, rawBody, secret)` with a known
  HMAC-SHA256 vector (compute the expected hex for a fixed body+secret and assert true; assert a
  wrong sig is false). Make the function pure/exported.
- [ ] **Step 2:** Run → FAIL/adjust. Keep the existing crypto.subtle HMAC body; just ensure it's
  exported and tested.
- [ ] **Step 3:** Fix storage: in webhook setup, capture the `X-Hook-Secret` from the creation
  response/handshake and store it under `webhook_secret_<projectId>`; use THAT (not the GID) in
  `onWebhook`. Confirm how `this.tools.network.createWebhook` surfaces the handshake — if the
  handshake is handled by the platform, read the secret from the create response; document the
  exact source.
- [ ] **Step 4:** Tests PASS; build 0 errors. Commit `fix(asana): store and verify real webhook X-Hook-Secret`.

### Task 3.9: File attachments

**Files:** Modify `connectors/asana/src/asana.ts`

- [ ] **Step 1:** Inbound — `client.attachments.findByTask(taskGid)` → emit `ActionType.fileRef`
  per attachment; implement `downloadAttachment(ref)` → `client.attachments.findById(ref,
  {opt_fields:"download_url"})` and redirect to `download_url`.
- [ ] **Step 2:** Outbound — in `addIssueComment` file loop, upload each file via raw multipart
  `fetch("https://app.asana.com/api/1.0/attachments", {method:"POST", headers:{Authorization}, body: FormData[parent=taskGid, file]})` (the typed SDK has no upload). Add `files: build(Files)`,
  `supportsFileAttachments: true`. (Asana attaches to the task, not the comment — document that
  the file lands on the task.)
- [ ] **Step 3:** Build 0 errors. Commit `feat(asana): task file attachments (in + out)`.
- [ ] **Step 4:** Full gate: `pnpm build && pnpm exec tsc --noEmit && pnpm lint && pnpm test`.

---

## Phase 4: Finalize

### Task 4.1: Repo-wide gate

- [ ] From `public/`: `pnpm install` clean; `( for c in todoist jira asana; do (cd connectors/$c && pnpm build && pnpm exec tsc --noEmit && pnpm lint && pnpm test) || echo "FAIL $c"; done )` — all clean.
- [ ] Confirm **no changeset** was added (no `public/.changeset/*` for connector pkgs). Run `( cd public && pnpm validate-changesets )`.

### Task 4.2: Docs (core repo, worktree root — NOT submodule)

- [ ] Add a `docs/updates.md` bullet under `## Next release` (e.g. a new `### Connected apps`
  section): plain-language — you can now create Todoist tasks, Jira issues, and Asana tasks from
  Plot; status, assignee, comments, and edits sync both ways; Asana likes sync as reactions.
- [ ] Update `docs/features.md` if the connector capabilities are described there.

### Task 4.3: Commit submodule pointer + open PRs

- [ ] In `public/`: ensure all connector commits are on `feat/connector-two-way-sync`; push;
  open the **public-submodule PR** (3 connectors).
- [ ] In the worktree core branch: `git add public docs/` and commit the submodule-ref bump +
  docs. (Do not deploy. Live E2E with real OAuth accounts is a flagged follow-up for Kris.)

---

## Self-review (completed by author)

- **Spec coverage:** every spec surface maps to a task — create (1.3/2.4/3.5), update
  (1.4/2.2/3.2+3.4), comment (todoist existing/2.x/3.3), edit (1.5/2.5/3.6), attachments
  (1.7/2.7/3.9), status expansion (1.2/2.3/3.4), Asana reactions (3.7), webhook hardening
  (1.6/2.6/3.8), handleReplies (3.1). Constraints documented in-task (Asana comment immutability
  3.6, Asana file-on-task 3.9, Jira no-HMAC 2.6).
- **Placeholders:** none — every task names exact files, the verified SDK call, and a build/test
  gate. Where exact field-shape confirmation is needed (e.g. matching inbound `externalContent`),
  the task says to inspect the specific inbound function and match it, which is the correct
  instruction, not a placeholder.
- **Type/name consistency:** shared helper names are stable across tasks (`mapTaskStatus`,
  `textToADF`/`adfToText`, `statusCategoryToIcon`, `buildLikeReactions`, `LIKE_EMOJI`, the
  `<provider>_user:<email>` cache keys).
- **Open items deferred to build (non-blocking):** exact `X-Hook-Secret` source for Asana,
  Asana `html_notes` vs `notes` for create, Jira attachment redirect-vs-stream auth. Each is
  called out in its task.
