# Trello Connector — Design

**Date:** 2026-06-25
**Status:** Approved (brainstorming) — pending spec review
**Author:** Kris Braun (with Claude)

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
tokens cannot call `api.trello.com`). Therefore this work has two parts:

1. **A new native auth provider `AuthProvider.Trello`** in the runtime (`workers/api`) +
   the twister enum (`public/twister`). This is the novel/risky part.
2. **The connector** in `public/connectors/trello/`, modeled on the canonical
   `connectors/linear/` bidirectional ProjectConnector.

## Goals

- Sync Trello **boards → channels**, **cards → links of type `card`**, **lists → per-board
  dynamic statuses**.
- Full **bidirectional** sync: move card between lists (status), archive card, post/edit
  comments, create new cards from Plot.
- v1 entity coverage: card title, description, list-status, members (→ contacts),
  comments (↔ notes), **attachments**, **checklists**.
- Real-time updates via **per-board Trello webhooks** with **HMAC-SHA1 signature
  verification** (`X-Trello-Webhook`).
- A genuine "Connect" UX (redirect → authorize on trello.com → done), not manual
  key-pasting.

## Non-goals (explicitly out of v1)

- **Due dates** and **labels** sync (deferred — can be added later).
- OAuth 1.0a (we use the simpler token-authorize flow).
- Checklist write-back / editing from Plot (checklists render read-only in v1).
- Token refresh logic (Trello tokens use `expiration=never`).

## Decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Auth | Native `AuthProvider.Trello` (token-authorize flow) | User wants real "Connect" UX, not Options key-paste. Can't reuse Atlassian OAuth. |
| Scope | Full bidirectional | Matches Linear/Jira canonical pattern; most useful. |
| Done detection | List-name heuristic + card archive | Trello has no native "done"; name match `/done\|complete\|closed\|shipped\|finished/i`, plus `closed:true` → Plot archived. |
| Extra entities | Attachments + Checklists | (Due dates + labels deferred.) |
| Webhook security | HMAC-SHA1 in v1 | App secret reaches the connector safely (see Security). |

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
  - `key: "checklists"` — a single structured note rendering all checklists + items
    (read-only v1).
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

## Sync baseline (note round-trip) — required

Trello stores comments as plain text. Returning a bare key from `onNoteCreated` would let
the next sync-in clobber Plot's markdown. Therefore the write-back must return
`externalContent` exactly equal to what the sync-in `buildCommentNote` path emits for that
comment (inspect that function and return its output). Same for `onNoteUpdated`.

## Testing

- **Unit (local, no provisioning):**
  - `trello-api`: request shaping (`?key=&token=`), HMAC-SHA1 verify helper.
  - `trello.ts` transforms: card → link, list → status, done-heuristic, archived mapping,
    comment/checklist/attachment notes, `initialSync` initial-vs-incremental, `source`
    format, contact creation.
  - Runtime: `GenerateAuthUrl` token-fragment URL shape; bridge fragment extraction;
    `HandleOauthCallback` token-fragment branch builds the right onAuth payload.
- **End-to-end (needs provisioning):** real connect → board enable → backfill → webhook →
  write-back. Gated on the Trello app key.

## Rollout / finalization

- Two PRs: **`public/`** (twister enum + changeset + connector) merges **first**; then the
  **main repo** PR (`workers/api` runtime + env + `connections.ts` flips + submodule
  gitlink bump).
- `pnpm lint` in `public/twister`, `workers/api`, and `public/connectors/trello`.
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
