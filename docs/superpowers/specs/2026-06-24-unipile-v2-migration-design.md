# Unipile v1 → v2 Migration — Design

**Date:** 2026-06-24
**Status:** Approved (brainstorming) — pending spec review
**Branch:** `unipile-v2-migration`

## Problem

Plot integrates [Unipile](https://developer.unipile.com) to power the LinkedIn,
Instagram, and WhatsApp connectors (messaging, hosted auth, profile lookups,
LinkedIn invitations/relations). Unipile has released API v2, which is a breaking
redesign of the v1 API we currently call. We need to migrate our integration to
v2.

Reference: <https://developer.unipile.com/v2.0/docs/migration-introduction> and
the per-domain migration pages (auth-and-accounts, messaging-api, webhooks,
linkedin-api, users-api).

## Decisions (settled during brainstorming)

1. **Hard cutover, replace v1 in place.** No dual-path/feature-flag and no
   v2-for-new-connections-only. We migrate the single client and its callers to
   v2 directly, producing the smallest diff. Rationale: we intend to *complete*
   the migration, not run both versions indefinitely; a flag would double the
   client surface and branch the webhook handler and auth bridge for no lasting
   benefit.
2. **Require users to reconnect.** We do **not** build an account-ID mapping or
   data-migration layer. Existing connections store v1 Unipile account IDs;
   after the production cutover (new v2 API key) those IDs no longer resolve, so
   affected connections must surface as **needs-reauth** and users re-authorize
   through the v2 hosted flow. This removes all ID-continuity work.
3. **Scope = code + tests + live local verification, plus an ops runbook. No
   production deploy.** Per repo rule "Only work locally. Never deploy." We
   migrate all code, get `pnpm lint` and the vitest suite green, **and verify the
   migrated client against the real Unipile v2 API on the local dev worker**
   before any production cutover (see "Live verification (local)" below). We
   update the webhook bootstrap script for v2 and document the production cutover
   as a runbook. We do **not** rotate production secrets, run the Unipile
   dashboard account-migration tool, recreate production webhooks, or deploy to
   production.

## Key facts about v2 (from the migration docs + Node SDK)

- **Host stays per-tenant DSN.** The Node SDK initializes as
  `new UnipileClient('https://{YOUR_DSN}', '{ACCESS_TOKEN}')` and v1 used
  `https://{DSN}/api/v1`. So `UNIPILE_DSN` and `UNIPILE_API_KEY` (sent as
  `X-API-KEY`) both remain. The migration intro's "api.unipile.com/v2" was a
  summary simplification, not the per-tenant reality.
- **Version prefix changes** from `/api/v1` to the v2 prefix (exact segment —
  `/api/v2` vs `/v2` — to be confirmed against the live reference during
  implementation; it is a single constant in the client).
- **`account_id` moves into the URL path.** Messaging/users routes become
  `/{prefix}/:account_id/…` instead of passing `account_id` as a query/body
  param.
- **Schema renames** across chats, messages, attendees/users, accounts (see
  §"Schema & normalize" below). IDs are now provider IDs; Unipile-generated IDs
  carry prefixes (`acc_` accounts, `we_` webhooks).
- **Pagination** moves from `cursor` to `offset`/`limit`.
- **Attachments** are sent as base64 JSON (`filename`, `content_type`, `data`),
  not multipart; `voice_message`/`video_message` params removed.
- **Webhooks** become a single unified endpoint that receives all event types;
  event names use dot-notation; payloads are lighter (IDs only, not full
  objects).

## Blast radius

All changes are inside the **API worker** (`workers/api`). The connectors
(`connectors/linkedin|instagram|whatsapp`) and the public `libs/unipile/`
abstraction are **untouched** — they consume only normalized Plot shapes, which
do not change.

| File | Change |
|---|---|
| `src/twist/tools/unipile/client.ts` | **Core.** v2 base prefix; rewrite every endpoint path; thread `accountId` into the URL path; `cursor` → `offset`/`limit`; base64-JSON attachments |
| `src/twist/tools/unipile/types.ts` | v2 wire schemas (field renames, `acc_`/`we_` IDs) |
| `src/twist/tools/unipile/normalize.ts` | Update field mappings (`provider_id`→`id`, `timestamp`→`last_message_timestamp`, `reactions`→`reactions_counter`, attendees→users, etc.) |
| `src/app/hook-messaging.ts` | New dot-notation event names; **fetch-by-ID** for lighter payloads; verify-header/signature |
| `scripts/bootstrap-unipile-webhooks.ts` | 3 source-specific webhooks → **1 unified** `/{prefix}/webhooks/endpoints` |
| `src/app/authBridge.ts` | Hosted auth `POST /{prefix}/auth/link`; profile fetch `GET /{prefix}/:account_id/users/me` |
| `src/twist/tools/unipile/*.test.ts`, normalize/messaging/instagram/whatsapp/account-cleanup tests | Update mocked URLs/shapes to v2 (TDD: tests first) |

## Endpoint remap (only the routes we call)

`account_id` moves from query/body into the path; messaging routes become
`/{prefix}/:account_id/…`. v1 → v2:

**Accounts / auth**
- `POST /hosted/accounts/link` → `POST /{prefix}/auth/link`
- `GET /accounts/:id`, `DELETE /accounts/:id` → `GET`/`DELETE /{prefix}/accounts/:id`
- `GET /accounts` (cursor) → `GET /{prefix}/accounts` (offset/limit)
- profile: `GET /users/me?account_id=` → `GET /{prefix}/:account_id/users/me`

**Webhooks**
- `GET`/`POST /webhooks` → `GET`/`POST /{prefix}/webhooks/endpoints`
- `DELETE /webhooks/:id` → `DELETE /{prefix}/webhooks/endpoints/:id`

**Messaging**
- `GET /chats?account_id=` → `GET /{prefix}/:account_id/chats`
- `GET /chats/:id` → `GET /{prefix}/:account_id/chats/:id`
- `GET /chats/:id/messages` → `GET /{prefix}/:account_id/chats/:id/messages`
- `POST /chats/:id/messages` → `POST /{prefix}/:account_id/chats/:id/messages/send`
- `POST /chats` (start chat, multipart) → `POST /{prefix}/:account_id/chats/send` (uses `users_ids`, base64 attachments)
- `PATCH /chats/:id` (accept/decline request, set read) → `PATCH /{prefix}/:account_id/chats/:id`
- attachment download → exact v2 path **TBD from live reference**

**Users / LinkedIn**
- `GET /users/:identifier` (resolve recipient) → `GET /{prefix}/:account_id/users/:identifier`
- `GET /users/:providerId` (attendee profile) → `GET /{prefix}/:account_id/users/:providerId`
- `GET /users/relations` → relations under `/{prefix}/:account_id/users/…` (**exact path TBD**)
- `GET /users/invite/received`, `POST /users/invite/received/:id` (accept/ignore) → v2 relation-request paths (**exact paths TBD**)
- write-reaction `POST /messages/:id/reactions`, clear-reaction → v2 reaction path under the chat/message route (**exact path TBD**)

## The one real behavioral change: webhook fetch-by-ID

v2 webhook payloads are **lighter** — `message.new` carries IDs
(`account_id`, `chat_id`, `message_id`) rather than the full message and chat
objects. Our `hook-messaging.ts` currently reads message content directly off
the payload. Under v2 the handler must **fetch the message by ID**
(`GET /{prefix}/:account_id/chats/:chat_id/messages/:message_id`) before building
the Plot note/link.

**Event-name remap** (v1 family → v2 dot-notation), mapped to our existing
internal `dispatch` values:
- account connected/created → `account.add`
- account reconnected → `account.reconnect`
- account disconnected/errored/credentials → `account.status.disconnected` / `account.status.errored` (→ our `account.needs_reauth`)
- new message → `message.new` (→ our `messaging.new_message`)
- LinkedIn invitation received → LinkedIn relation/invite event (→ our `users.invitation.received`)
- new relation → (→ our `users.new_relation`)

**Bootstrap** collapses from three source-specific webhooks to **one** unified
endpoint at `/{prefix}/webhooks/endpoints`, subscribing to all needed event
types.

**Webhook auth.** Today we verify inbound webhooks by a custom
`X-Plot-Webhook-Token` header that we attach when registering the webhook, and
compare in constant time against `UNIPILE_WEBHOOK_SECRET`. We keep this model
**if** v2 webhook endpoints still allow attaching custom headers. **Fallback:**
if v2 does not support custom headers, switch verification to Unipile's own
signature/secret mechanism. Exact mechanism confirmed against the live reference
during implementation.

## Schema & normalize changes

`normalize.ts` and `types.ts` updated for v2 field renames:

- **Chat:** `provider_id` → `id`, `timestamp` → `last_message_timestamp`,
  `archived` → `is_archived`, `subject` → `name`/`description`.
- **Message:** `provider_id` → `id`, `seen` → `is_seen`,
  `sender_attendee_id` → `sender_id`, `reactions` → `reactions_counter`.
- **Attendees → users:** `attendees_ids` → `users_ids`; chat participants may now
  be embedded in the chat object rather than fetched via a separate
  `/chats/:id/attendees` call (**TBD from live reference** — affects whether
  `getChat`/`normalizeChat` still makes a second request).
- **User/profile:** `headline` → `description`, `summary` → `bio`,
  `profile_picture_url` → `public_picture_url`; provider-specific fields nest
  under `specifics`.
- **Account:** `type` → `provider`; removed fields (`connection_params`,
  `source`, `signatures`, `groups`, `full_fetch`, `fetch_progress`,
  `last_fetched_at`); `acc_` ID prefix.

The goal is that `normalize*()` continues to emit the **same Plot shapes**
(`ChatThread`, `ChatMessage`, `ChatProfile`, …) so connectors and `libs/unipile`
need no changes.

## Testing strategy

Test-driven, per the existing test layout:

- Update each `src/twist/tools/unipile/*.test.ts` to assert v2 URLs and v2 wire
  shapes **first** (they currently assert exact v1 URLs like
  `…/api/v1/chats?account_id=…`), watch them fail, then change the
  implementation until green.
- Add coverage for the new webhook fetch-by-ID path in `hook-messaging.ts`
  (no test exists today).
- Local bar: `pnpm lint` clean in `workers/api` + the full vitest suite green.
- **Final gate: live verification** against the real v2 API on the local dev
  worker (tunnel for webhooks) — see "Live verification (local)". Unit tests
  prove our request/response handling against *assumed* v2 shapes; live
  verification proves the assumptions.

## Live verification (local)

Before any production cutover we exercise the migrated client against the **real
Unipile v2 API** on the local dev worker. This is how the known-unknowns below
get resolved empirically (not just from docs), and how we confirm send/receive,
reactions, read-state, hosted auth, and webhook delivery actually work on v2.

**Prerequisite (user-provided):** a working v2 API key + tenant DSN in local
`.dev.vars` for `workers/api` (`UNIPILE_API_KEY`, `UNIPILE_DSN`,
`UNIPILE_WEBHOOK_SECRET`). Created in the Unipile dashboard; not something this
task can self-provision.

**Setup:**
1. Run the API worker locally: `pnpm --filter @plotday/api dev` (localhost:8787).
2. Start the Cloudflare tunnel: `pnpm tunnel:start` → public
   `https://api-kris.plot.day` routing to the local worker.
3. Register the v2 unified webhook endpoint (via the updated
   `bootstrap-unipile-webhooks.ts`) pointing `request_url` at
   `https://api-kris.plot.day/hook/messaging`.

**Verification passes (against a real test account):**
- Hosted auth: connect a LinkedIn/Instagram/WhatsApp account through the v2
  hosted flow; confirm `authBridge.ts` profile fetch and the `account.add`
  webhook.
- Inbound: send a message to the connected account from another device; confirm
  the `message.new` webhook arrives over the tunnel and the **fetch-by-ID** path
  builds the Plot note correctly.
- Outbound: send a message, add/clear a reaction, mark a chat read; confirm via
  the v2 API and the connected account.
- Backfill: list chats/messages with offset/limit pagination.
- Reconnect/needs-reauth surfacing on a disconnected account.

The tunnel is local-only and uses `UNIPILE_WEBHOOK_SECRET` (or the v2 signature)
for verification — no production webhook or secret is touched.

## Known-unknowns — resolved empirically during live verification

These do not change the *shape* of the work (each is a localized constant or one
function), so they are deliberately deferred rather than blocking the design.
Each is pinned by reading the live v2 API reference as that endpoint is
implemented **and confirmed against the live API during local verification**:

1. Exact v2 path prefix (`/api/v2` vs `/v2`).
2. Whether chat **attendees/participants** are embedded in the chat object or
   require a separate fetch (affects `getChat`/`normalizeChat`).
3. Exact v2 paths for: attachment download, write/clear message reaction,
   LinkedIn invitations (list/accept/ignore), and relations listing.
4. Whether v2 webhook endpoints support attaching custom headers (drives the
   webhook-auth approach; fallback is signature/secret verification).

## Production cutover runbook (documented, executed by the user — not in this task)

1. Create a v2 API key in Unipile dashboard; store in 1Password
   (`Production` + `Development`) under the `UNIPILE_API_KEY` reference.
2. Confirm/refresh `UNIPILE_DSN` (v2 tenant DSN) and `UNIPILE_WEBHOOK_SECRET`.
3. `pnpm get-env` to refresh local `.dev.vars`.
4. Run `scripts/bootstrap-unipile-webhooks.ts` against v2 to register the unified
   webhook endpoint.
5. `bash scripts/sync-github-secrets` to refresh the CI bundle
   (`WORKER_CONFIGS_JSON`).
6. Deploy the API worker (CI on merge).
7. Existing connections fail to resolve their v1 account IDs and surface as
   needs-reauth; users reconnect via the v2 hosted flow. Optionally run the
   Unipile dashboard migration tool first if account preservation is later
   desired (out of scope here).

## Out of scope

- Account-ID mapping / data migration (we require reconnect).
- LinkedIn recruiter / Sales Navigator / jobs / search endpoints — not called by
  Plot today.
- Email and Calendar Unipile APIs — Plot uses other connectors for those.
- Any production deploy or secret rotation (runbook only).

## Implementation status — 2026-06-24

**Done & verified.** The full code migration landed in the API worker (plus
`libs/unipile` + the three connectors for the reaction-`chatId` thread). `tsc` +
eslint are clean across all five packages and 42 unit tests pass. Every REST
shape below was verified **directly against the live v2 API** using the dev mock
account (`acc_01kvwz2rk0e8k81mgrp27mye6t`, provider `mock`):

- Base `https://api.unipile.com`, `/v2` prefix, `X-API-KEY`; no DSN. `UNIPILE_DSN`
  removed; `UNIPILE_API_KEY` → `op://$ENV/Unipile/v2/api key`.
- List envelope `{object,data,has_more}` + `?limit&offset`. Accounts (`user_id`
  identity, `provider`, `status`), `users/me`, `users/:id`, chats (group
  `participants[].user` + 1:1 `user`), messages.
- Send echoes `{object:"MessageSent",message_id}`; startChat echoes
  `{object:"ChatStarted",chat_id,message_id}` → wrappers synthesize the message.
- Reactions: `POST /v2/:acc/chats/:chat/messages/:id/reactions` body `{reaction}`
  (chat-scoped). Add → `MessageReactionAdded`; clear via empty `{reaction:""}` ✓.
- Hosted auth: `POST /v2/auth/link` (route exists, requires `expires_on`).
- Webhooks: one unified endpoint `POST /v2/webhooks/endpoints` with
  `{name,url,trigger_events}`; returns a per-endpoint signing `secret` (`wes_…`).
  Confirmed-valid `trigger_events`: `message.new`, `account.add`,
  `account.reconnect`, `account.status.disconnected`, `account.status.errored`,
  `relation.new`, `relation.request.accept`. **v2 has no "invitation received"
  event** — received invitations are pulled via `listReceivedInvitations`.

**Remaining — user-gated live verification (needs a real connected account).**
The mock provider can't exercise the hosted-auth UI or push real webhooks, so
these final checks require connecting a real LinkedIn/Instagram/WhatsApp account
and run the worker + tunnel:

1. `pnpm --filter @plotday/api dev` + `pnpm tunnel:start`; set `API_ROOT` to the
   tunnel URL and run `tsx scripts/bootstrap-unipile-webhooks.ts development`.
2. Connect a real account via the hosted flow → confirm `account.add` arrives and
   `authBridge` resolves the profile name.
3. Send a message to that account from another device → confirm `message.new`
   over the tunnel builds the Plot note; then test outbound send / reaction /
   read-state and a `relation.new`.
4. **Webhook auth (one open LIVE-CONFIRM):** v2 returns a per-endpoint signing
   secret and may not forward our custom `X-Plot-Webhook-Token`. The receiver now
   logs incoming header *names* on every delivery — check the first real
   delivery's log: if our header is present, the existing constant-time check
   stands; if not, switch `hook-messaging.ts` to verify the Unipile signature
   against the endpoint's `wes_` secret.
