# Trello Connector — Design

**Date:** 2026-06-25
**Status:** Approved (brainstorming) — pending spec review
**Author:** Kris Braun (with Claude)

> **v2 (2026-06-25):** Checklist sync redesigned from a read-only markdown note into a
> **generic "structured items as notes" model** with two-way completion + assignment.
> This adds a third part — a platform/SDK foundation (note section/position fields + actor
> external-account enrichment) that other products (Google Tasks subtasks, Todoist, etc.)
> can reuse. See **Part 3**.

## Summary

Add a **bidirectional Trello connector** so users can sync Trello boards/cards into
Plot as threads, see comments/members/attachments/checklists, and write changes back
(move cards between lists, post comments, create cards). Trello is already listed as an
upcoming connection (`available: false`) in both `apps/site/app/data/connections.ts` and
`workers/api/src/app/connections.ts`.

Trello does **not** use OAuth 2.0. Its REST API authenticates with an **API key + a
user-authorized token** obtained from the `trello.com/1/authorize` flow, which returns
the token in the URL **fragment** (`#token=…`) — an implicit-grant-style flow with no
code exchange and no refresh. Atlassian owns Trello but Trello is **not** covered by the
Atlassian OAuth 2.0 (3LO) provider we already have for Jira (`audience: api.atlassian.com`
tokens cannot call `api.trello.com`). Therefore this work has three parts:

1. **A new native auth provider `AuthProvider.Trello`** in the runtime (`workers/api`) +
   the twister enum (`public/twister`). This is the novel/risky part.
2. **The connector** in `public/connectors/trello/`, modeled on the canonical
   `connectors/linear/` bidirectional ProjectConnector.
3. **A generic platform/SDK foundation** for syncing *structured items* (checklists today,
   any product's subtask/checklist items later) as Plot **notes** with two-way completion +
   assignment. See **Part 3**.

## Goals

- Sync Trello **boards → channels**, **cards → links of type `card`**, **lists → per-board
  dynamic statuses**.
- Full **bidirectional** sync: move card between lists (status), archive card, post/edit
  comments, create new cards from Plot.
- v1 entity coverage: card title, description, list-status, members (→ contacts),
  comments (↔ notes), **attachments**, **checklists** (two-way: completion, assignment,
  rename — see Part 3).
- Real-time updates via **per-board Trello webhooks** with **HMAC-SHA1 signature
  verification** (`X-Trello-Webhook`).
- A genuine "Connect" UX (redirect → authorize on trello.com → done), not manual
  key-pasting.
- A **reusable structured-items model**: the note schema + actor-enrichment additions are
  designed so future connectors (Google Tasks subtasks, Todoist sub-tasks, Notion to-dos,
  GitHub task-lists) get two-way checklist sync for free.

## Non-goals (explicitly out of v1)

- **Due dates** and **labels** sync (deferred — can be added later).
- OAuth 1.0a (we use the simpler token-authorize flow).
- Token refresh logic (Trello tokens use `expiration=never`).
- **Grouped/ordered/collapsed checklist UI in the app** — the data model lands now; the
  app renders checklist-item notes as a (degraded) flat list until Layer 3 ships. See
  Part 3.
- **Creating / deleting checklist items from Plot** — deferred until the app has the UI to
  do so (v1 write-back covers completion, assignment, and rename of existing items).
- **First-class sub-issues** (Jira sub-tasks, Linear sub-issues) — out of scope of the
  structured-items model by design; those remain their own threads.

## Decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Auth | Native `AuthProvider.Trello` (token-authorize flow) | User wants real "Connect" UX, not Options key-paste. Can't reuse Atlassian OAuth. |
| Scope | Full bidirectional | Matches Linear/Jira canonical pattern; most useful. |
| Done detection | List-name heuristic + card archive | Trello has no native "done"; name match `/done\|complete\|closed\|shipped\|finished/i`, plus `closed:true` → Plot archived. |
| Extra entities | Attachments + Checklists | (Due dates + labels deferred.) |
| Webhook security | HMAC-SHA1 in v1 | App secret reaches the connector safely (see Security). |
| Checklist item = | a Plot **note** (keyed `checkitem-{id}`) | Notes are the only primitive that already carries per-actor assignment + completion (`note_tag` Todo/Done), keyed upsert, sync, and `onNoteUpdated` write-back. |
| Checklist grouping/order | **new generic note fields** (`section_*`, `item_position`) | Captures structure now; app renders grouped/ordered later with no data migration. Degraded interim = flat list. |
| Outbound assignment | **platform enrichment** of dispatched actors (no connector lookup call) | Symmetric with inbound `NewContact.source.accountId`; reusable by every bidirectional connector; kills the email-cache hack. |
| Checklist completion | **item-level collapse**: any `Done` ⇔ Trello complete; attribute to assignee, else owner | Trello completion is one bit; Plot `Done` is per-actor. Defined collapse keeps it faithful. |
| Capability gating | derive from **section-presence** (client render-gate), v1 | No reactions/attachments/links on checklist-item notes; no schema column needed; degradable. |

---

## Part 1 — Native `AuthProvider.Trello`

### 1.1 The flow

```
Client → GET /auth?provider=trello
  runtime builds:
  https://trello.com/1/authorize
    ?key={AUTH_TRELLO_ID}
    &response_type=token
    &scope=read,write
    &expiration=never
    &name=Plot
    &return_url={API_ROOT}/auth/bridge       ← forced bridge
  → user authorizes on trello.com
  → Trello redirects to the bridge with the token in the FRAGMENT: …/auth/bridge#token=ABC
  → bridge HTML (server-rendered) runs JS, reads location.hash, extracts `token`,
    relays it to the server as a query param
  → HandleOauthCallback (token-fragment branch): no code exchange; calls
    GET https://api.trello.com/1/members/me?key=…&token=… to fetch the account label,
    then invokes the connector onAuth callback exactly like the OAuth path.
```

### 1.2 Runtime changes

**`public/twister/src/tools/integrations.ts`**
- Add `Trello = "trello"` to the `AuthProvider` enum. **Requires a changeset**
  (`public/.changeset/<name>.md`, `@plotday/twister: minor`, `Added: …`).

**`workers/api/src/provider.ts`**
- Extend `ProviderConfig.authMode` from `"oauth" | "hosted"` to
  `"oauth" | "hosted" | "token-fragment"`.
- Add a `trello` entry to `PROVIDER_CONFIGS`:
  ```ts
  trello: {
    name: "Trello",
    authMode: "token-fragment",
    authUrl: "https://trello.com/1/authorize",
    // no tokenUrl — no code exchange
    requiresHttpsRedirect: true,            // force the bridge
    extractAccountLabel: (d) => (d as TrelloProviderData).fullName
      ?? (d as TrelloProviderData).username ?? null,
    extractMetadata: (d) => ({ memberId: (d as TrelloProviderData).memberId }),
  }
  ```
- `TrelloProviderData = { memberId: string; username: string | null; fullName: string | null }`.
- The standard `parseTokenResponse(response)` signature has **no `env` access**, but the
  account-label fetch needs the API key. So the `members/me` call is made **inline in the
  token-fragment branch of `HandleOauthCallback`** (which has `env`), producing
  `TrelloProviderData`, rather than via `config.parseTokenResponse`. Helper:
  `parseTrelloToken(token, env)` → `GET https://api.trello.com/1/members/me?key=${env.AUTH_TRELLO_ID}&token=${token}` → `{ memberId: id, username, fullName }`.
- `extractUserId` (the switch) → return `memberId` for `case "trello"`.

**`workers/api/src/twist/tools/integrations.ts`**
- `GenerateAuthUrl`: branch on `config.authMode === "token-fragment"` → skip PKCE, emit
  `response_type=token`, `scope`, `expiration=never`, `name=Plot`, `return_url=<bridge>`
  (instead of `response_type=code` + PKCE). Still stash `AuthState` for the callback.
- `HandleOauthCallback`: branch on `token-fragment` → take the relayed token from the
  query param (placed there by the bridge), skip `exchangeCodeForTokens`, run
  `parseTrelloToken`, then invoke the connector onAuth callback with
  `{ access_token: token, provider: "trello", scopes: ["read","write"], … }` — identical
  persistence path to OAuth.
- **Inject `key` + `secret` into the AuthToken at read time** (Security below): when
  building the `AuthToken` for `provider === "trello"` in `integrations.get()`, merge
  `{ key: env.AUTH_TRELLO_ID, secret: env.AUTH_TRELLO_SECRET }` into the `provider`
  metadata map (read fresh from `env`, **not** persisted in the DO store).

**`workers/api/src/app/authBridge.ts`**
- The bridge already renders an HTML page that deep-links back to the client. Extend it so
  that for `token-fragment` providers it reads `location.hash`, parses `token=…`, and
  forwards it to `HandleOauthCallback` (e.g. a client-side `fetch`/redirect that places the
  token in a query param). The fragment is otherwise invisible to the server.

**`workers/api/src/env.ts`**
- Add to `Bindings`: `AUTH_TRELLO_ID: string` (the API key) and `AUTH_TRELLO_SECRET: string`
  (the app secret, used for webhook HMAC).

**`workers/api/package.json`**
- Add `AUTH_TRELLO_ID AUTH_TRELLO_SECRET` to `config.deploy_vars`.

### 1.3 Security — why handing the secret to the connector is safe

- **Tokens are not in Postgres.** `contact_external_account` stores only
  `provider`, `account_id`, timestamps. The access token + provider metadata live in the
  connector's **Durable Object Store** (`StoredTokenData`), read by `integrations.get()`
  and shaped into `AuthToken` server-side.
- **No `user.*` view exposes `access_token` or provider metadata**, so nothing
  token-related syncs to Flutter clients (`extractAccountLabel` output is the only
  client-facing field).
- The Trello **API key** is not actually secret (it appears in every authorize URL), so
  exposing it via `token.provider.key` is harmless.
- The Trello **app secret** is sensitive; we inject it from `env` at `integrations.get()`
  time so it reaches only the sandboxed connector code at sync time and is **never
  persisted** in the DO store nor serialized anywhere client-facing.

### 1.4 Provisioning (human-gated)

Cannot be end-to-end tested locally until a Trello app key exists (same situation as the
Atlassian work). Steps:
1. Create a Trello Power-Up / API key + secret at `trello.com/power-ups/admin`.
2. Store key + secret in 1Password (`Development` and `Production`).
3. Add `op://$ENV/Trello/...` refs to root `.env` / `.env.production`.
4. `pnpm get-env` (local) and **`bash scripts/sync-github-secrets`** (CI bundles).
5. Register the bridge return URL with the Trello app if required.

---

## Part 2 — The connector (`public/connectors/trello/`)

### 2.1 Files

```
public/connectors/trello/
  src/
    index.ts          # export { default, Trello } from "./trello";
    trello.ts         # Trello extends Connector<Trello>
    trello-api.ts     # thin REST client (auth params, request shaping, HMAC verify)
    trello.test.ts
    trello-api.test.ts
  package.json        # name @plotday/connector-trello, plotTwistId (plot create --connector)
  tsconfig.json
  README.md
  LICENSE
```

### 2.2 Class shape

```ts
export class Trello extends Connector<Trello> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Trello;
  readonly scopes = ["read", "write"];
  // linkTypes declared with a base "card" type; per-board statuses are attached
  // dynamically in getChannels (see 2.3). compose block opts card creation in.

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.trello.com/*"] }),
    };
  }
}
```

`getApi(channelId)` reads the token via `this.tools.integrations.get(channelId)` and
constructs requests with `?key={token.provider.key}&token={token.token}`. HMAC verification
uses `token.provider.secret`.

### 2.3 Channels & dynamic statuses

- **`getChannels`** → `GET /members/me/boards?filter=open&fields=id,name`. One `Channel`
  per board (`id = boardId`, `title = board name`).
- For each board, fetch its lists (`GET /boards/{id}/lists?fields=id,name&filter=open`) and
  attach a per-channel `LinkTypeConfig` whose `statuses[]` are the board's lists in order:
  - `status = listId`, `label = list name`.
  - `done: true` on any list whose name matches `/done|complete|closed|shipped|finished/i`;
    if none match, none are `done`.
  - `compose: { status: <first non-done list id>, targets: "channels" }`.

  This mirrors Linear's per-team workflow-state pattern (status values are provider IDs,
  resolved by the connector).

### 2.4 Sync

- **`onChannelEnabled`** (idempotent; handles `context.recovering`): `runTask` for
  (a) webhook setup and (b) initial backfill — as **separate** tasks, never inline.
- **`startBatchSync`/`syncBatch`**: paginated `GET /boards/{id}/cards` with
  `members=true`, `attachments=true`, `checklists=all`, `actions=commentCard`,
  `actions_limit=…`, page via `before`/card id. Save each card via
  `integrations.saveLink()`. Propagate `initialSync` through every batch; set
  `unread:false, archived:false` only on the initial pass. Call
  `integrations.channelSyncCompleted(channelId)` from the final batch.
- **`onWebhook(req, boardId)`**: verify HMAC (`base64(HMAC-SHA1(secret, body + callbackURL))`
  vs `X-Trello-Webhook`), then **re-fetch the changed card** and re-transform (don't trust
  webhook payload titles — avoids placeholder-title clobber on upsert). Incremental
  (`initialSync = false`).

### 2.5 Data model & conventions

- **`source`**: `trello:card:{cardId}` — Trello card id is an immutable 24-hex, globally
  unique → safe upsert + cross-user dedup key. `link.channelId = boardId`;
  `link.meta = { syncProvider: "trello", boardId, idList }`.
- **Status**: current `card.idList`. `card.closed === true` → Plot **archived** thread;
  archiving in Plot → `PUT /cards/{id}?closed=true` (write-back).
- **Notes**:
  - `key: "description"` — card `desc` (Trello markdown → `contentType: "markdown"`).
  - `key: "comment-{actionId}"` — each `commentCard` action; `created` = action date;
    author = action member → `NewContact`.
  - `key: "checkitem-{checkItemId}"` — one **structured-item note per checklist item**
    (two-way completion + assignment). Full model in **Part 3**.
  - `key: "attachment-{attachmentId}"` — one note per attachment (name + URL).
- **Contacts**: card members + comment authors → `NewContact` with
  `source.accountId = trello member id`, `name`, `avatar`.
- **Bidirectional**:
  - `onLinkUpdated(link)` → map `link.status` (listId) to `PUT /cards/{id}?idList=…`;
    map archived → `closed=true`.
  - `onNoteCreated(note, thread)` → `POST /cards/{id}/actions/comments`; return
    `NoteWriteBackResult { key: "comment-"+id, externalContent: <what sync-in emits> }`.
  - `onNoteUpdated(note, thread)` for `comment-*` keys → `PUT /actions/{id}/text`; return
    `{ externalContent }` refreshed from the response.
  - `onCreateLink(draft)` → `POST /cards` with `idList = draft.status` (resolve default),
    `name = draft.title`, `desc = draft.noteContent`. Return the `NewLinkWithNotes`; do
    **not** call `saveLink()`.
  - Loop prevention lives in any consuming twist (`note.author.type === ActorType.Twist`).

### 2.6 `package.json` availability flips

Flip `available: true` in:
- `apps/site/app/data/connections.ts:249`
- `workers/api/src/app/connections.ts` (the Trello entry, ~line 147)

---

## Part 3 — Checklist sync as structured note-items (generic foundation)

**Goal:** a reusable model where a *checklist item* (and any future product's
subtask/checklist item) is a Plot **note** with two-way **completion** and **assignment**,
plus the metadata the app needs to *later* render a grouped/ordered/collapsed checklist.
The data model lands now; the polished UI is deferred (degraded interim = flat note list).

### 3.1 Why "item = note" (verified)

A note is the only primitive that already carries everything an assignable, completable
checklist item needs, on existing rails:
- **Per-actor assignment + completion**: `note_tag (actor_id, note_id, tag_id)`, `Tag.Todo=1`
  (assigned-to) / `Tag.Done=3` (completed-by). A note can have many independent assignees.
- **Keyed idempotent upsert**: `note.key = "checkitem-{checkItemId}"` (immutable Trello id).
- **Sync + write-back dispatch**: `onNoteUpdated` fires on **tag changes** (user edits only,
  connector-owned thread; twist writes are skipped → loop-safe).
- **Interactive in read mode today**: a `Todo`/`Done`-tagged note already renders a tappable
  checkmark (`note.dart:1282`) — so even before Layer 3, checking an item works and syncs.

What does **not** exist and must be added: a way to (a) order/group items, (b) gate
capabilities, and (c) resolve a Plot assignee back to an external member without a lookup
call. Those are the Layer-1 additions below.

### 3.2 Layer 1 — platform/SDK foundation (build first; reusable)

**A. New generic note fields** (additive expand-migration; follows safe-add-column):
| Field | Type | Meaning |
|---|---|---|
| `section_key` | `text` null | Stable id of the group within the thread (Trello checklist id). `NULL` = ordinary note (comment/description). |
| `section_label` | `text` null | Display name of the group ("QA tasks"). |
| `section_position` | `text`/`numeric` null | Order of the group among the thread's groups. |
| `item_position` | `text`/`numeric` null | Order of the item within its group. |

- Expose all four in the `user.note` view; bump note `seq` on change (so they sync).
- Mirror in Twister `Note` / `NewNote` (**changeset**) and in the Drift `note.dart` entity
  (safe-add-column, version bump). The client compiles and **ignores** them initially —
  that's the degraded interim, and it's clean because the data is fully captured.
- **Capability gating is derived from `section_key IS NOT NULL`** (a "sectioned item" hides
  reactions/attachments/links/replies) — no separate `kind` column in v1. An explicit
  discriminator can be added later, additively, if a grouped note ever needs full
  capabilities. (Restriction itself is a **client render-gate**; in v1 those affordances
  still show on checklist-item notes — harmless, local-only, ignored by the connector.)

**B. Actor external-account enrichment (closes the outbound-assignment gap).** Today a
connector receiving `onNoteUpdated` gets bare actor UUIDs in `note.tags` and has **no API**
to map them back to a Trello member id (`contact_external_account` isn't exposed; existing
connectors hack it via email caches). Decision: **the platform enriches the dispatched
payload — no connector lookup call.**
- Add optional `source?: { accountId: string } | null` to the Twister `Actor` type
  (symmetric with `NewContact.source` used inbound). **Changeset.**
- When the runtime builds a dispatch payload for a connector (`onNoteUpdated`,
  `onNoteCreated`, `onLinkUpdated`, …), it populates each `Actor.source.accountId` from
  `contact_external_account` for **that connector's** `twist_instance_id`/provider, in a
  single **batched** join (no N+1) — in `buildNoteAndThread` / the actor-hydration path of
  `workers/api/src/twist/tools/integrations.ts`.
- The connector then reads the assignee's `source.accountId` directly off the dispatched
  note's tag actors. (Surfacing detail for the plan: `note.tags` is `{tagId: ActorId[]}`
  today; the enriched actor objects are exposed either by upgrading the dispatched tag
  representation to carry `Actor` objects or via a companion `note.taggedActors` map — pick
  the backward-compatible option.)
- **Reusable:** every bidirectional connector that writes back a Plot assignee benefits;
  this is the principled replacement for the per-connector email cache.

### 3.3 Layer 2 — the Trello connector mapping

- **Sync-in** (`transformCheckItem`, within the card's `syncBatch`): for each checklist's
  `checkItems`, emit a `NewNote`:
  - `key: "checkitem-{checkItemId}"`, `content: item.name` (plain text).
  - `section_key: checklistId`, `section_label: checklistName`,
    `section_position: checklist.pos`, `item_position: item.pos`.
  - **Assignment (inbound)**: if `item.idMember`, `tags: { [Tag.Todo]: [{ source: {
    accountId: idMember }, name }] }` — the runtime resolves the contact via
    `source.accountId` (verified path: `thread-helpers.ts processNewActorArray`).
  - **Completion (inbound, item-level collapse)**: if `item.state === "complete"`, mark
    `Tag.Done` for the assignee (`idMember`); if **unassigned**, attribute `Done` to the
    **connection owner's contact** so the checkbox reflects "complete".
- **Write-back** (`onNoteUpdated(note, thread)` for `checkitem-*` keys): reconcile the full
  note against Trello (`note` has no per-field diff):
  - `Done` present for any actor ⇒ `PUT /cards/{idCard}/checkItem/{id}?state=complete`;
    all `Done` cleared ⇒ `state=incomplete`. (**item-level collapse rule**.)
  - `Todo` actor set changed ⇒ map via the enriched `actor.source.accountId` →
    `PUT …/checkItem/{id}?idMember={memberId}`. Trello is single-assignee (`idMember`); if
    Plot has multiple `Todo` actors, write the first/primary. If an assignee has no Trello
    member id (not a board member), skip with a `deliveryError`.
  - `content` changed ⇒ `PUT …/checkItem/{id}?name=…` (rename).
  - Loop-safe: write-backs set `updated_by = twist`, so the resulting webhook re-sync does
    not re-dispatch.
- **Create/delete from Plot**: deferred (no app UI yet); `onNoteCreated` for a
  `checkitem-*` shaped note is a v-next hook.

### 3.4 Layer 3 — app (deferred, incremental, no data migration)

Reads `section_*` / `item_position` to render checklist-item notes **grouped by section,
ordered by position, collapsible**, with a native checkbox + assignee avatar; and **gates**
reactions/attachments/links/replies for sectioned notes. Lights up data already flowing from
Layer 2 — ships independently whenever it's prioritized.

### 3.5 Generality boundary

This model fits **lightweight checklist/subtask items** — `{name, done, assignee, position,
section}` with no independent lifecycle (Trello checklists, Google Tasks subtasks, Todoist
sub-tasks, Notion to-dos, GitHub task-lists). It is **not** for **first-class sub-issues**
(Jira sub-tasks, Linear sub-issues) with their own status workflow/comments — those stay
their own threads/links.

### 3.6 Risks / open items for the plan

- **Scale**: a board of 100 cards × 20 items = 2 000 item-notes per syncing user (× tags).
  Skip empty checklists; consider a per-card item ceiling. Notes are high-churn but built
  for volume — confirm during testing.
- **Enriched-tags surfacing**: choose the backward-compatible shape for exposing
  `Actor.source` on `note.tags` (upgrade tag actors vs. companion map).
- **Owner attribution** for unassigned-complete items: confirm "connection owner's contact"
  is resolvable in the connector at sync time (it is the auth actor).
- **Migration ordering**: Layer 1 schema + Twister + Drift land before the connector emits
  `section_*`; until then, item-notes would carry null sections (still valid, just flat).

### 3.7 Plan 4 decisions (Layer 2 — resolving §3.6, approved 2026-06-26)

Layer 1 shipped in **Plan 3** (note `section_*`/`item_position` columns + `user.note` view,
Twister `Note`/`NewNote` fields, `Actor.source`, and dispatch-time `tagActors` enrichment).
Plan 4 is **Layer 2 only** — the Trello connector mapping in `public/connectors/trello/`. The
following resolve the §3.6 open items and the §3.3 surfacing choices:

- **Enriched-tags surfacing → companion map (resolved in Plan 3).** Connectors read the
  assignee's external id off `note.tagActors[actorId].source.accountId` (a `Record<ActorId,
  Actor>` populated by the runtime on dispatch). `note.tags` stays `{tagId: ActorId[]}` —
  backward compatible. No connector lookup call.
- **Position type → fractional-index `text` (resolved in Plan 3).** `section_position` /
  `item_position` are `text`. The connector stringifies Trello's float `pos`
  (`String(checklist.pos)` / `String(item.pos)`) on sync-in.
- **Owner attribution for unassigned-complete → fetch + cache `GET /members/me`.** When an
  item is `state==="complete"` but has no `idMember`, attribute `Tag.Done` to the connection
  owner so the Plot checkbox reflects "complete". The connector resolves the owner's Trello
  member id via `GET /members/me`, cached in connector state (`this.set('me_member_id', …)`)
  to avoid a per-card call.
- **Deletion → webhook-action driven.** `onWebhook` branches on `action.type`:
  `deleteCheckItem` archives the single `checkitem-{id}` note; `removeChecklistFromCard`
  re-fetches the card and archives every `checkitem-*` note whose checklist is gone. Note
  archival uses `integrations.saveNote({ thread: { source: "trello:card:{id}" }, key:
  "checkitem-{id}", archived: true })`. **Tradeoff (accepted):** deletions that occur while
  webhooks are down are not caught up (no full-card delete-reconciliation in v1).
- **Write-back API.** Sync-in rides the existing `saveLink(transformCard(...))` (atomic with
  the card). Completion/assignment/rename write-back is a new `updateCheckItem` on `TrelloApi`
  (`PUT /cards/{idCard}/checkItem/{id}` with `state` / `idMember` / `name`). Trello is
  **single-assignee**: with multiple Plot `Tag.Todo` actors, write the first/primary; an
  assignee with no Trello member id is skipped with a `deliveryError` (does not block the
  completion/rename fields). Loop-safe: write-backs are `updated_by=twist`.
- **Deferred to v-next (unchanged from §3.3):** create/delete a checkItem *from Plot*
  (`onNoteCreated` for a `checkitem-*` note) and the Layer-3 app UI (Plan 5).

---

## Sync baseline (note round-trip) — required

Trello stores comments as plain text. Returning a bare key from `onNoteCreated` would let
the next sync-in clobber Plot's markdown. Therefore the write-back must return
`externalContent` exactly equal to what the sync-in `buildCommentNote` path emits for that
comment (inspect that function and return its output). Same for `onNoteUpdated`.

## Testing

- **Unit (local, no provisioning):**
  - `trello-api`: request shaping (`?key=&token=`), HMAC-SHA1 verify helper.
  - `trello.ts` transforms: card → link, list → status, done-heuristic, archived mapping,
    comment/attachment notes, `initialSync` initial-vs-incremental, `source` format, contact
    creation.
  - `trello.ts` **structured-items** (Part 3): `checkItem → NewNote` (`section_*` +
    `item_position` + inbound `Tag.Todo` via `source.accountId` + item-level `Done`
    collapse, including the unassigned→owner attribution); `onNoteUpdated` reconciliation
    (Done⇔state, assignee via enriched `actor.source.accountId`, rename, skip-with-
    `deliveryError` for non-member assignees).
  - Runtime: `GenerateAuthUrl` token-fragment URL shape; bridge fragment extraction;
    `HandleOauthCallback` token-fragment branch builds the right onAuth payload.
  - Runtime **enrichment** (Part 3): dispatched `Actor.source.accountId` is populated from
    `contact_external_account` (scoped to the connector's instance), batched, and `null`
    when the actor has no external account for that provider.
  - DB: `user.note` view exposes `section_*`/`item_position`; note `seq` bumps on their
    change (sync); `pnpm diff-schema-migrations` clean; `types.ts` regenerated.
- **End-to-end (needs provisioning):** real connect → board enable → backfill → webhook →
  write-back. Gated on the Trello app key.

## Rollout / finalization

- **`public/` PR (merges first)** — Twister changeset covers **all three** type additions:
  `AuthProvider.Trello` enum, the `NewNote`/`Note` `section_*`/`item_position` fields, and
  `Actor.source`. Plus the connector package (`public/connectors/trello/`).
- **main-repo PR (second)** — `workers/api` runtime (Trello auth provider + dispatch
  enrichment), the **note schema migration** (`section_*`/`item_position` columns +
  `user.note` view + seq bump) with regenerated `libs/db/src/types.ts`, the **Drift**
  `note.dart` columns (safe-add-column + version bump), env wiring, `connections.ts` flips,
  and the submodule gitlink bump.
- `pnpm lint` in `public/twister`, `workers/api`, and `public/connectors/trello`;
  `pnpm --filter @plotday/db run lint` for the migration/types.
- New `catch` blocks for unexpected errors → `captureException` / `tracker.captureException`.
- `pnpm updates:new` fragment (user-facing: "Connect Trello to track cards in Plot").
- Connector deploy via `plot deploy` (reads `plotTwistId`); not npm, no connector changeset.

## Open implementation details (for the plan, not blockers)

- Exact injection point for `key`/`secret` in `integrations.get()` (main path + the
  sub-connector fallback path both build `AuthToken`).
- Bridge relay mechanism for the fragment token (client-side `fetch` to a callback endpoint
  vs redirect with the token moved to a query param) — choose the lowest-risk option that
  keeps the token out of server logs.
- Trello `return_url` domain registration requirements for the app.
- Pagination strategy for boards with very large card counts (batch ceiling ~1000
  requests/execution).
- **Enriched-tags surfacing shape** (Part 3 §3.6): backward-compatible exposure of
  `Actor.source` on the dispatched `note.tags`.
- **`section_position`/`item_position` type**: `numeric` (mirror Trello's float `pos`) vs a
  fractional-index `text` (stable inserts) — pick during Layer 1.
