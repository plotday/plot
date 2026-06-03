# WhatsApp + Instagram premium connectors (Unipile) — Design

- **Date:** 2026-06-02
- **Branch:** `whatsapp-instagram-connectors` (off local `main`)
- **Status:** Approved design — ready for implementation plan
- **Author:** Kris Braun (with Claude)

## 1. Summary

Add two new **premium** (Unipile-backed, per-connection cost) connectors —
**WhatsApp** and **Instagram** — built in the core repo alongside the existing
LinkedIn connector, with **full two-way sync** (inbound message sync + outbound
reply/compose) and **compose** (start a brand-new conversation from Plot).

Because LinkedIn is **not yet deployed to production**, we take the opportunity
to **refactor the LinkedIn connector and the shared Unipile tooling onto a
single shared messaging core** that all three connectors ride, and to **clear
the existing LinkedIn TODOs / latent bugs** discovered while designing this.

## 2. Goals & non-goals

**Goals**

- WhatsApp + Instagram connectors with two-way sync and compose, modeled on
  LinkedIn but shaped to each platform.
- A shared Unipile **messaging core** so the chat/message/send/react/read/compose
  logic lives in one place; LinkedIn, WhatsApp, and Instagram are thin
  provider-specific layers over it.
- Webhook-driven sync with a one-time backfill — **no recurring poll, no
  reconciliation sweep**.
- Fix LinkedIn's latent issues uncovered here (dead compose declaration,
  unverified `startChat` endpoint, hardcoded reauth provider, reaction-clear).

**Non-goals (this pass)**

- A reconciliation/safety-net poll (explicitly dropped; can be added later if
  live testing shows webhook gaps).
- LinkedIn relations *refresh* loop (periodic re-crawl) — dropped as
  reconciliation; one-time relations backfill is kept.
- Posts/feed, stories, calls, or any non-messaging surface of these platforms.
- Deploying anything. All work is local; live verification is manual (see §12).

## 3. Decisions (from brainstorming)

1. **Connector shape: platform-shaped.** Mirror LinkedIn's architecture but match
   what each platform supports. WhatsApp: 1:1 + named groups + compose (no
   invitations, no relations backfill). Instagram: 1:1 + group DMs + **message
   requests** (pending DMs surfaced as a `pending` status) + compose. Neither
   does a LinkedIn-style relations backfill.
1a. **Link-type model (see §6a).** A link type represents a *kind of
   conversation a user filters/composes by*, not a participant count. The real
   axis is **conversation (DM, 1:1 or ad-hoc multi-person) vs. named group**.
   Counts: **LinkedIn = 1** (`conversation`, covers 1:1 and multi-person — no
   named-group entity), **WhatsApp = 2** (`conversation` 1:1 + `group`),
   **Instagram = 2** (`conversation` 1:1 + `group`). Compose folds into
   `conversation` (no separate `dm` type); `group` is sync + reply only in v1.
2. **Reactions: open Unicode.** Both declare
   `reactionCapabilities = { mode: "open-unicode", customEmoji: "none" }` (the
   platforms accept any emoji, unlike LinkedIn's fixed 7).
3. **Compose: allow new recipients.** Users can compose to existing contacts
   **and** to someone not yet in Plot — by phone number (WhatsApp) or @username
   (Instagram). Implemented via `compose.targets: "addresses"`.
4. **Verification: live testing by the user.** Code is delivered compiling,
   type-checking, linting, and unit-tested; the user connects real WhatsApp /
   Instagram accounts locally (API worker + Cloudflare tunnel) to verify
   two-way sync + compose and confirm the docs-unverified endpoint shapes.
5. **LinkedIn is refactorable** (not yet in production) — unify it onto the
   shared core and fix its TODOs in this session.

## 4. Background: how the Unipile stack works today

- **Connector package** `connectors/linkedin/` (private; `plotTwistId`,
  `private: true`) extends `Connector` from `@plotday/twister`. Declares
  `provider`, `linkTypes`, `reactionCapabilities`; implements `getChannels`,
  `onChannelEnabled/Disabled`, sync callbacks, `onWebhookEvent`, `onCreateLink`,
  `onNoteCreated`, `onNoteUpdated`, `onLinkUpdated`, `onThreadRead`,
  `downloadAttachment`.
- **Abstract tool** `libs/unipile/src/linkedin.ts` (`LinkedInMessaging extends
  ITool`) defines the provider-flavored interface the connector calls; types in
  `libs/unipile/src/types.ts` are intentionally Plot-flavored.
- **Concrete tool** `workers/api/src/twist/tools/unipile/linkedin.ts`
  (`LinkedInMessaging extends Tool`) implements the interface over
  `UnipileClient`; `normalize.ts` maps Unipile shapes → Plot shapes.
- **HTTP client** `workers/api/src/twist/tools/unipile/client.ts`
  (`UnipileClient`) is the only Unipile-aware file; already provider-agnostic and
  already lists `LINKEDIN | WHATSAPP | INSTAGRAM` in `createHostedAuthLink`.
- **Factory** `workers/api/src/twist/tools/factory.ts` maps tool IDs → classes in
  `getToolClass()` + constructs them in `createTool()`.
- **Auth + webhooks are almost entirely provider-agnostic:**
  - `provider.ts` `PROVIDER_CONFIGS` is the allowlist (gatekeeper); hosted-auth
    mapping `{ linkedin→LINKEDIN, whatsapp→WHATSAPP, instagram→INSTAGRAM }`
    already exists in `integrations.ts` (`GenerateHostedAuthUrl` `sourceMap`).
  - `authBridge.ts` `/auth/hosted/success` derives the provider from stored auth
    state (not hardcoded) and stores `auth_token:${provider}:${actor}` /
    `channel_config:${provider}:${channel}`.
  - `hook-messaging.ts` `POST /hook/messaging` routes by `account_id` →
    `channel.twist_instance_id` → connector `onWebhookEvent` callback; event
    kinds derived in `classifyEvent`.
  - Webhook bootstrap (`scripts/bootstrap-unipile-webhooks.ts`) registers
    workspace-level `messaging` / `account_status` / `users` webhooks — covers
    all providers; no change needed.
  - Env: `UNIPILE_API_KEY`, `UNIPILE_DSN`, `UNIPILE_WEBHOOK_SECRET` — shared
    across all providers.

## 5. Architecture: shared Unipile messaging core

Refactor the LinkedIn-specific tooling into a provider-neutral core with thin
per-provider layers. **LinkedIn moves onto the core in the same pass.**

```
libs/unipile/src/
  messaging.ts   NEW  Abstract `UnipileMessaging extends ITool` with the common
                      methods (listChats, getChat, listMessages, sendMessage,
                      downloadAttachment, setChatRead, setMessageReaction,
                      clearMessageReaction, startChat, getProfile) + provider-
                      neutral types: ChatThread, ChatMessage, ChatProfile,
                      ChatAttachment, ChatMessageReaction, *Page.
  linkedin.ts    MOD  `LinkedInMessaging extends UnipileMessaging` adding
                      LinkedIn-only methods: listReceivedInvitations,
                      listRelations, acceptInvitation, ignoreInvitation; keeps
                      LinkedIn-only types (Invitation, Relation/Profile extras).
  whatsapp.ts    NEW  `WhatsAppMessaging extends UnipileMessaging` (+ phone→JID
                      attendee resolution helper).
  instagram.ts   NEW  `InstagramMessaging extends UnipileMessaging` (+ message-
                      request listing + @username→provider-id resolution helper).
  types.ts       MOD  Generalize/rename LinkedIn* shared types → neutral names;
                      keep LinkedIn-only types here or in linkedin.ts.
  index.ts       MOD  Export messaging + all three provider modules.

workers/api/src/twist/tools/unipile/
  messaging.ts   NEW  Concrete `UnipileMessaging extends Tool` over UnipileClient,
                      parameterized by `provider` (assertAccount + token keys use
                      this.provider — removes hardcoded "linkedin").
  linkedin.ts    MOD  `LinkedInMessaging extends UnipileMessaging` (provider
                      "linkedin") + invitation/relation methods.
  whatsapp.ts    NEW  `WhatsAppMessaging extends UnipileMessaging` (provider
                      "whatsapp") + phone resolution.
  instagram.ts   NEW  `InstagramMessaging extends UnipileMessaging` (provider
                      "instagram") + message-request + username resolution.
  normalize.ts   MOD  Generic normalizers (renamed) + LinkedIn invitation/relation
                      normalizers.
  client.ts      MOD  Fix startChat (POST /chats); add IG message-request list
                      params + attendee-resolution endpoints as needed.

connectors/
  linkedin/      MOD  Refactor onto shared core + apply fixes (see §9).
  whatsapp/      NEW  Connector package (private, new plotTwistId).
  instagram/     NEW  Connector package (private, new plotTwistId).
```

Three concrete tool IDs (`LinkedInMessaging`, `WhatsAppMessaging`,
`InstagramMessaging`) are registered in `factory.ts`; the abstract
`UnipileMessaging` base is never registered directly. Each connector's
`build()` requests its own tool: `build(WhatsAppMessaging)`, etc. The shared
base reads `this.provider` for `assertAccount` and token lookups.

**Design principle:** each unit has one clear purpose and a well-defined
interface — `UnipileClient` knows HTTP; `UnipileMessaging` (concrete) maps
Plot↔Unipile and enforces auth; the abstract tool is the contract the connector
sees; the connector owns product behavior (link types, statuses, sync shape).

## 6. Sync model — webhook-driven, no poll (all three)

Unipile documents that messages are *"buffered and retried in case of errors …
no need to build a complex polling system, just subscribe to the webhook."*
Accordingly:

- **`onChannelEnabled`:** store the webhook callback **first**, then run a
  **one-time backfill** of existing chats/messages (LinkedIn also backfills
  invitations and runs its one-time relations crawl). Set `unread: false`,
  `archived: false` on backfilled items.
- **Steady state:** driven entirely by the `messaging.new_message` webhook (plus
  LinkedIn's `users.invitation.received` / `users.new_relation`). On a new-message
  event, fetch the chat and rebuild/upsert the link with the new note(s).
- **No recurring `syncBatch` poll. No reconciliation sweep.** The
  onChannelEnabled→webhook race is closed by storing the callback before backfill
  (and backfill covers anything that arrived during enable).
- If live testing reveals dropped webhooks or unsynced reaction/read/edit changes,
  a low-frequency jittered reconciliation sweep can be added later — out of scope
  now.

## 6a. Link-type model

A link type drives the Plot filter chip, the compose ("Create new …") entry, and
per-type icons/labels/statuses. It should map to a *kind of conversation a user
perceives*, not the participant count. A 1:1 chat and an ad-hoc multi-person chat
are the **same kind** — "a conversation with a set of people sharing one
persistent thread." A **named group** (a standalone, named, persistent room that
outlives any message) is a **different kind**. So the axis is
**conversation vs. named group**, and the per-platform count follows from whether
that platform has named groups:

| Platform | `conversation` (composable) | `group` |
|---|---|---|
| **LinkedIn** | 1:1 **and** multi-person · `pending`(invite)/`inbox`/`archived`/`ignored` | — (no named-group entity) |
| **WhatsApp** | 1:1 · `inbox`/`archived` | named group · `inbox`/`archived` · reply-only |
| **Instagram** | 1:1 + requests · `pending`/`inbox`/`archived`/`ignored` | group DM · `inbox`/`archived` · reply-only |

- **LinkedIn collapses 3 → 1.** Today's `conversation` + `group` + `dm` become one
  composable `conversation`. LinkedIn messaging has no named-group entity (a chat
  is just its participant set), so 1:1 and multi-person share one type; the
  connection-request (invitation) is the `pending` status on that type.
- **Compose folds into `conversation`** (eliminates the standalone `dm` type).
  This also **fixes a latent duplicate-thread bug**: today's `dm` compose returns
  a **chat-keyed** link (`<provider>:chat:<id>`) while synced 1:1s are
  **person-keyed** (`<provider>:person:<id>`), so composing to someone you already
  talk to would spawn a second thread. With one composable `conversation`, a 1:1
  compose returns a **person-keyed** link that converges with the synced thread;
  group/multi-person compose stays chat-keyed.
- **`group` is sync + reply only in v1** — creating a named group *from* Plot
  (compose into `group`) is out of scope.

## 7. WhatsApp connector

- **Provider string:** `"whatsapp"`. `singleChannel = true`. One channel per
  connected account (channel id = Unipile account id).
- **Link types (2):**
  - `conversation` (1:1): statuses `inbox`, `archived` (done). **Composable:**
    `compose: { targets: "addresses", status: "inbox" }`.
  - `group` (named WhatsApp group): statuses `inbox`, `archived` (done). Sync +
    reply only (no compose in v1).
- **Reactions:** `{ mode: "open-unicode", customEmoji: "none" }`.
- **No invitations, no relations backfill.** Contacts derive from chat
  participants during sync.
- **Compose:** existing contacts pre-resolved into `draft.recipients`; a typed
  phone number resolves to a WhatsApp JID `"<digits>@s.whatsapp.net"` for
  `attendees_ids` (confirm whether Unipile accepts a raw phone or needs
  pre-resolution — §13). A 1:1 compose returns a **person-keyed** link so it
  converges with the synced conversation thread.

## 8. Instagram connector

- **Provider string:** `"instagram"`. `singleChannel = true`.
- **Link types (2):**
  - `conversation` (1:1): statuses `pending` (message request), `inbox`,
    `archived` (done), `ignored` (done). **Composable:**
    `compose: { targets: "addresses", status: "inbox" }`.
  - `group` (group DM): statuses `inbox`, `archived` (done). Sync + reply only
    (no compose in v1).
- **Message requests:** Instagram DMs from non-followers arrive in a requests
  folder; surface them as the `conversation` `pending` status. Accepting/ignoring
  maps to the platform action via `onLinkUpdated` (analogous to LinkedIn
  invitations but driven by chat folder/state, not a separate invitation object).
  Exact representation (chat `folder`/attribute or list param) confirmed in impl
  (§13).
- **Reactions:** `{ mode: "open-unicode", customEmoji: "none" }`.
- **Compose:** existing contacts pre-resolved; a typed **@username** resolves to a
  provider id via Unipile's Users endpoint (§13).

## 9. LinkedIn refactor + TODO punch-list

1. **`startChat` endpoint fix.** Current `UnipileClient.startChat` POSTs
   `/messages` with `attendees_ids` and is TODO-flagged "unverified." The verified
   Unipile endpoint is **`POST /chats`** (multipart form: `account_id`,
   `attendees_ids[]`, `text`, optional `title` for groups, optional
   `attachments`). Rewrite to `POST /chats`; this single call backs compose for
   all three connectors.
2. **Collapse to one composable `conversation` type + fix dead compose.** LinkedIn
   currently declares three link types (`conversation` 1:1+invitations, `group`,
   `dm`) and the `dm` type opts into compose via the obsolete top-level
   `targets`/`createDefault` — but the runtime only reads `compose.targets`
   (`integrations.ts:2019`), so "Create new message" never wires up (the stale
   form compiles because excess props are assignment-compatible, but is
   runtime-dead). Per §6a, **merge all three into a single composable
   `conversation`** (1:1 + multi-person; `pending`=invitation) with
   `compose: { targets: "contacts", status: "inbox" }` (LinkedIn DMs are
   closed-roster → `contacts`, not `addresses`). A 1:1 compose returns a
   **person-keyed** link so it converges with the synced conversation instead of
   spawning a duplicate (the chat-keyed `dm` bug).
3. **Reaction clear.** `clearMessageReaction` currently blind-`DELETE`s a mirror
   path and swallows 404/405. Confirm the real clear mechanism (empty-value POST
   vs DELETE) and implement it properly; keep a tolerant fallback only if docs are
   ambiguous.
4. **Drop the 30-min `syncBatch` poll** and the **relations *refresh* loop**
   (reconciliation). Keep the one-time relations backfill (needed to populate
   compose contacts); new relations arrive via the `users.new_relation` webhook.
5. **Fix hardcoded reauth provider.** `hook-messaging.ts handleAccountNeedsReauth`
   filters `twist_instance_connection.provider = "linkedin"`. Derive the provider
   from the channel's connector so reauth-stamping works for WhatsApp/Instagram
   (and remains correct for LinkedIn).
6. **Token/config keys.** Move `channel_config:linkedin:` / `auth_token:linkedin:`
   key construction into the shared concrete `UnipileMessaging` keyed on
   `this.provider` (so all three providers resolve their own credentials).

## 10. Server wiring changes

- `workers/api/src/provider.ts` — add `PROVIDER_CONFIGS` entries for `"whatsapp"`
  and `"instagram"` (`authMode: "hosted"`, hosted-account label extractor) mirroring
  the `"linkedin"` entry. (The `sourceMap` in `integrations.ts` already maps both.)
- `workers/api/src/twist/tools/factory.ts` — register `WhatsAppMessaging` and
  `InstagramMessaging` in `getToolClass()` and `createTool()` (and the return-type
  union), constructed like `LinkedInMessaging`.
- `workers/api/src/app/hook-messaging.ts` — provider-derivation fix (§9.5).
- `apps/site/app/data/connections.ts` — add WhatsApp + Instagram entries
  (`category: "Communication"`, `available: true`, `premium: true`) with verified
  ~1:1 icons (logo + dark variant per the connector-icon guidelines).
- New `plotTwistId` UUIDs for each connector package.
- Webhook bootstrap: no change (workspace-level, all sources).

## 11. Data model: link types, statuses, meta

- **Links** carry `meta.syncProvider` (`"whatsapp"` / `"instagram"` /
  `"linkedin"`), `meta.channelId`, `meta.chatId`, and (group) participants via
  `accessContacts`. 1:1 conversations are person-keyed
  (`source: "<provider>:person:<id>"`) with a secondary `<provider>:chat:<id>`
  source so chat- and person-keyed updates converge.
- **Notes** keyed `message-<unipileMessageId>`; reactions aggregated into Plot's
  `emoji → NewActor[]`; attachments as `fileRef` actions with
  `ref: "<messageId>:<attachmentId>"`; message→channel cached for
  `downloadAttachment`.
- **Status writes only on initial backfill** (`...(initialSync ? {status} : {})`),
  so webhook-driven incremental updates never re-promote a user-archived/ignored
  thread.

## 12. Testing & verification

- **Local (automated):** `tsc`/`pnpm lint` clean across `@plotday/unipile`,
  `@plotday/connector-{linkedin,whatsapp,instagram}`, and `@plotday/api`. Unit
  tests (Vitest, mirroring `normalize.test.ts` / `client.test.ts`) for: provider
  normalizers; compose recipient resolution (phone→JID, username→id, existing
  contacts); reaction reconciliation (open-unicode); message-request status
  mapping (Instagram).
- **Live (user):** run the API worker locally + Cloudflare tunnel
  (`api-kris.plot.day`) so Unipile webhooks reach localhost; connect real
  WhatsApp + Instagram accounts via hosted auth with Unipile creds in
  `.dev.vars`. Verify: inbound sync (1:1, group, IG requests), reply, compose to
  existing + new recipient, reactions both directions, read-state, attachments.
  Confirm the §13 open items against live responses. (Mechanics of running the
  connectors locally — normally `plot deploy` — to be settled at that step, given
  the never-deploy rule.)

## 13. Open items to confirm during implementation / live testing

- Reaction **clear** mechanism (empty-value POST vs DELETE) per provider.
- Instagram **message-request** representation (chat `folder`/attribute, or a
  list-chats filter param) and the accept/ignore action.
- Instagram **@username → provider-id** resolution endpoint.
- WhatsApp: whether `attendees_ids` accepts a raw phone/constructed JID directly
  or requires a resolution step first.
- Group-chat attendee/title fields per provider (vs LinkedIn's shape).

## 14. Risks

- Several Unipile WhatsApp/Instagram endpoint shapes are undocumented or
  unverified; live testing is the gate. Mitigated by isolating all HTTP in
  `UnipileClient` and all mapping in `normalize.ts`, so corrections are localized.
- Refactoring the (undeployed) LinkedIn connector risks regressing its behavior;
  mitigated by keeping LinkedIn's product behavior identical apart from the §9
  fixes, and by the shared-core unit tests.
- Multi-agent shared checkout: work is isolated in this worktree (separate index),
  so the shared-index commit race does not apply here.

## 15. File-by-file change inventory (for the plan)

**New:** `connectors/whatsapp/**`, `connectors/instagram/**`,
`libs/unipile/src/{messaging,whatsapp,instagram}.ts`,
`workers/api/src/twist/tools/unipile/{messaging,whatsapp,instagram}.ts`, unit
tests.

**Modified:** `libs/unipile/src/{linkedin,types,index}.ts`,
`workers/api/src/twist/tools/unipile/{linkedin,normalize,client}.ts`,
`workers/api/src/twist/tools/factory.ts`, `workers/api/src/provider.ts`,
`workers/api/src/app/hook-messaging.ts`, `apps/site/app/data/connections.ts`,
`connectors/linkedin/src/linkedin.ts`, `docs/updates.md` + `docs/features.md`
(user-facing: two new premium connections).
