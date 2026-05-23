# LinkedIn (Unipile-backed) Connector — Design

**Date:** 2026-05-22
**Branch:** `linkedin-unipile`
**Status:** Draft, pending implementation plan.

## Goal

Replace the existing Voyager-scraping LinkedIn connector with one backed by
[Unipile](https://www.unipile.com), a hosted unified-messaging API. Reuse the
Unipile infrastructure for WhatsApp and Instagram in follow-up phases.

The user-visible behaviour of "Continue with LinkedIn" must be
indistinguishable from every other AuthButton in the app — same button text,
same setup modal on success, no special-case branches.

The connector lives in a new top-level `connectors/` folder in this (private)
monorepo. Public Twister has no Unipile- or LinkedIn-specific tool surface
after this change.

## Constraints and naming discipline

- **No "Unipile" in public-facing names.** Endpoint paths, abstract tool
  class names, `AuthProvider` values, storage keys, webhook event names, and
  Flutter UI strings are all vendor-agnostic. The string "unipile" appears
  only in (a) the private package name `@plotday/unipile`, (b) inside the
  server-side concrete impl files, and (c) the env var names (`UNIPILE_*`).
  If we swap providers later, no public-facing identifier needs to change.
- **Tools stay internal.** The abstract tool classes the connector imports
  live in `libs/unipile/`, not in `public/twister/`. They are workspace-
  private; no published-package surface area.
- **Reusable layering.** The HTTP client and the account-management tool
  are generic across providers. Only the provider-specific tool impls and
  the provider-specific connectors are provider-flavoured.
- **Single-channel connector.** A LinkedIn connection corresponds to exactly
  one LinkedIn account; additional accounts require additional connections.
  This matches the existing infrastructure where a channel = one external
  resource. The two LinkedIn data types (DMs, connection requests) are
  exposed as boolean Options on the connector, not as channels.

## Architecture

Six layers, three of them shared across LinkedIn / WhatsApp / Instagram from
day one.

```
┌────────────────────────────────────────────────────────────────┐
│ Flutter app — no LinkedIn special-case anywhere                │
│   auth_button.dart   uses _startTwistAuth() like every other   │
│                      AuthButton. Server hands back a hosted-   │
│                      auth URL; Flutter opens it; same callback │
│                      flow as OAuth; setup modal opens on       │
│                      success.                                  │
└────────────────────────────────────────────────────────────────┘
                          │ HTTPS
┌────────────────────────────────────────────────────────────────┐
│ workers/api                                                    │
│                                                                │
│  Auth flow extensions (vendor-agnostic endpoint names):        │
│    • twist-integrations.ts gains a hosted-auth branch keyed    │
│      on PROVIDER_CONFIGS[provider].authMode === "hosted".      │
│    • The existing "get auth URL" endpoint returns a Unipile-   │
│      generated hosted link for hosted-auth providers.          │
│    • The existing /auth completion endpoint, when called for a │
│      hosted-auth provider, does NOT exchange a code; it looks  │
│      up the account_id that the webhook delivered against the  │
│      caller's state token and finishes the Authorization.      │
│                                                                │
│  New webhook endpoint (vendor-agnostic name):                  │
│    POST /hook/messaging                                        │
│      → dispatches Unipile events to handlers; no Unipile-      │
│        specific identifiers leak past this file.               │
│                                                                │
│  src/twist/tools/unipile/  ← concrete tool impls (internal)    │
│    client.ts        UnipileClient — HTTP, API key, retries,    │
│                     error mapping, response normalization.     │
│    account.ts       Concrete impl of HostedAccount tool.       │
│    linkedin.ts      Concrete impl of LinkedInMessaging tool.   │
│    normalize.ts     Unipile response → Plot shape.             │
│    webhook.ts       /hook/messaging event router.              │
│    types.ts         Internal Unipile response types.           │
└────────────────────────────────────────────────────────────────┘
                          │ build(LinkedInMessaging)
┌────────────────────────────────────────────────────────────────┐
│ libs/unipile/  ← PRIVATE workspace package, @plotday/unipile   │
│                                                                │
│   Abstract tool classes the connector imports. Names are       │
│   provider-flavoured (not Unipile-flavoured) so the connector  │
│   code reads cleanly.                                          │
│                                                                │
│     LinkedInMessaging   — LinkedIn-specific ops                │
│     WhatsApp            — (added in next phase)                │
│     Instagram           — (added in next phase)                │
│                                                                │
│   Account lifecycle (link generation, status, delete) is NOT   │
│   exposed to the connector. Those operations are server-only   │
│   and live in the internal UnipileClient — they are called by  │
│   the auth endpoints and the webhook handler.                  │
│                                                                │
│   Plus shared input/output types: HostedAccountStatus,         │
│   LinkedInChat, LinkedInMessage, LinkedInInvitation, …         │
└────────────────────────────────────────────────────────────────┘
                          │ workspace import
┌────────────────────────────────────────────────────────────────┐
│ connectors/linkedin/  (PRIVATE, @plotday/connector-linkedin)   │
│                                                                │
│   Single-channel connector. The channel id is the Unipile      │
│   account id; the channel title is the connected account's     │
│   display name. Additional LinkedIn accounts = additional      │
│   connections.                                                 │
│                                                                │
│   Two boolean Options:                                         │
│     • importMessages       (default true)                      │
│     • importInvitations    (default true)                      │
│                                                                │
│   build() returns:                                             │
│     { integrations, linkedin: LinkedInMessaging, options,      │
│       callbacks, tasks }                                       │
└────────────────────────────────────────────────────────────────┘
```

## Provider config and auth-flow integration

The existing OAuth machinery in `workers/api/src/app/twist-integrations.ts`
and `workers/api/src/provider.ts` already routes per-provider by an entry in
`PROVIDER_CONFIGS`. We extend that record with an `authMode` discriminator:

```typescript
type ProviderConfig = {
  name: string;
  authMode: "oauth" | "hosted";   // NEW
  // ...existing OAuth fields, all optional when authMode = "hosted"
};
```

- `authMode: "oauth"` — every existing provider; flow unchanged.
- `authMode: "hosted"` — LinkedIn now, WhatsApp/Instagram later; the API
  worker calls Unipile's `POST /hosted/accounts/link` to generate an auth
  URL with a Plot-controlled `state` parameter, returns the URL to the
  Flutter client, and waits for the matching `account.connected` webhook
  to land the `account_id`.

The Flutter app's `_startTwistAuth()` does not change. It still asks for an
auth URL, opens it, waits for the redirect, and posts back to `/auth`. For
hosted-auth providers the `/auth` completion path:

1. Validates the returned `state`.
2. Looks up the `account_id` recorded by the webhook against that state.
3. If not yet received, polls for up to ~15s (Unipile webhooks are usually
   delivered before the user-facing redirect, but not always).
4. Stores the credentials as a regular `StoredTokenData` row whose
   `access_token` is the Unipile `account_id` and whose `providerData` is
   the new `HostedAccountProviderData` shape (account id, account type,
   linked profile name/email).
5. Invokes the connector's `onAuth` callback exactly as OAuth does.

```typescript
// provider.ts (new)
export type HostedAccountProviderData = {
  accountId: string;            // Unipile account_id
  accountType: string;          // "LINKEDIN" | "WHATSAPP" | "INSTAGRAM"
  userId: string;               // Provider-side user id (used by integrations.extractUserId)
  fullName: string | null;
  email: string | null;
};
```

`AuthProvider.LinkedIn` is unchanged. Its `PROVIDER_CONFIGS` entry switches
from a cookie-capture flow to `authMode: "hosted"`. Its `extractUserId`
arm reads the new shape.

## The Unipile HTTP client (internal)

`workers/api/src/twist/tools/unipile/client.ts` exposes a single class:

```typescript
export class UnipileClient {
  constructor(env: { UNIPILE_API_KEY: string; UNIPILE_DSN: string }) { … }

  // Account lifecycle (all providers)
  createHostedAuthLink(input: {
    providers: ("LINKEDIN" | "WHATSAPP" | "INSTAGRAM")[];
    state: string;
    successRedirectUrl: string;
    failureRedirectUrl: string;
    notifyUrl: string;
    expiresAt: Date;
  }): Promise<{ url: string }>;
  getAccount(accountId: string): Promise<UnipileAccount>;
  deleteAccount(accountId: string): Promise<void>;

  // LinkedIn messaging
  listChats(input: { accountId: string; before?: string; limit?: number }):
    Promise<UnipileChatPage>;
  listMessages(input: { accountId: string; chatId: string; …}):
    Promise<UnipileMessagePage>;
  sendMessage(input: { accountId: string; chatId: string; text: string }):
    Promise<UnipileMessage>;
  setChatRead(input: { accountId: string; chatId: string; read: boolean }):
    Promise<void>;

  // LinkedIn invitations
  listReceivedInvitations(input: { accountId: string; … }):
    Promise<UnipileInvitationPage>;
  acceptInvitation(accountId: string, invitationId: string): Promise<void>;
  ignoreInvitation(accountId: string, invitationId: string): Promise<void>;
}
```

The client is the only file in the codebase that knows Unipile's URL
shape, header set, or API key. Everything else uses Plot-shaped wrappers.

## The Unipile webhook handler

`POST /hook/messaging` accepts Unipile's event envelope:

```jsonc
{
  "AccountId": "…",
  "EventType": "account.connected" | "account.disconnected" |
               "account.error"     | "messaging.new_message" |
               "users.invitation.received",
  "Payload": { … }
}
```

The handler:

1. Verifies the webhook (Unipile signs with a workspace-shared secret in
   the `X-Unipile-Signature` header — verified server-side; never leaves
   this file).
2. Looks up the `twist_instance_id` + `actorId` for the `account_id`.
3. Dispatches by event type:
   - `account.connected` — records the account against the auth state so
     the in-flight `/auth` call can complete.
   - `account.disconnected` / `account.error` — marks the connection
     `needs_reauth_at = now()` via the existing helper.
   - `messaging.new_message` and `users.invitation.received` — invokes the
     connector's stored webhook callback with a normalized payload (see
     "Connector webhook contract" below).

The dispatcher never exposes the Unipile event shape to the connector.

## Connector webhook contract

Two normalized event shapes the connector sees:

```typescript
type LinkedInMessagingWebhookEvent =
  | { kind: "message.received"; chatId: string; messageId: string }
  | { kind: "message.read";     chatId: string }
  | { kind: "invitation.received"; invitationId: string };
```

The connector registers a single callback via the existing
`network.createWebhook` pattern, dispatched by `/hook/messaging`. On receipt
it fetches the affected chat/invitation via the LinkedIn tool and writes
the resulting links. The "fetch by id" hop keeps the connector idempotent
and ignorant of Unipile's payload schema.

## The LinkedIn connector

```typescript
import {
  Connector, type NewLinkWithNotes, type ToolBuilder,
} from "@plotday/twister";
import { AuthProvider, Integrations } from "@plotday/twister/tools/integrations";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Options } from "@plotday/twister/options";
import {
  LinkedInMessaging,
  type LinkedInChat, type LinkedInMessage, type LinkedInInvitation,
} from "@plotday/unipile";

const OPTIONS_SCHEMA = {
  importMessages: {
    type: "boolean", label: "Import direct messages",
    description: "Sync your LinkedIn DMs into Plot.", default: true,
  },
  importInvitations: {
    type: "boolean", label: "Import connection requests",
    description: "Sync inbound LinkedIn connection requests into Plot.",
    default: true,
  },
} as const;

export class LinkedIn extends Connector<LinkedIn> {
  static readonly PROVIDER = AuthProvider.LinkedIn;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.LinkedIn;
  readonly scopes = LinkedIn.SCOPES;
  readonly linkTypes = [/* message + invitation, single-channel */];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      linkedin: build(LinkedInMessaging),
      options: build(Options, OPTIONS_SCHEMA),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
    };
  }

  async getChannels(auth, _token): Promise<Channel[]> {
    // The auth Authorization gives us the connected actor's display name
    // and email. There is exactly one channel per LinkedIn connection;
    // its id is the Unipile account id, which is the stored access_token.
    return [{ id: auth.token.access_token, title: auth.actor.name ?? "LinkedIn" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_state_${channel.id}`, { initialSync: true, since: null });
    await this.runTask(await this.callback(this.syncBatch, channel.id, true));
  }

  async syncBatch(channelId: string, initialSync: boolean): Promise<void> {
    // Reads `this.tools.options.importMessages` /
    // `this.tools.options.importInvitations` each pass; skips a branch
    // when its option is off. Persists a since-cursor per branch.
  }

  override async onNoteCreated(note, thread): Promise<NoteWriteBackResult | void> {
    // Sends the reply via this.tools.linkedin.sendMessage.
  }

  override async onThreadRead(thread, _actor, unread): Promise<void> {
    // Mirrors read state via this.tools.linkedin.setChatRead.
  }
}
```

The connector body never names a Unipile concept — only the package name
`@plotday/unipile` betrays the provider. If we swap providers later, the
import path is one global rename; the tool classes and method shapes
stay LinkedIn-flavoured.

## Polling vs webhooks

Unipile webhooks (`messaging.new_message`, `users.invitation.received`)
are the primary update path. A low-frequency polling loop (every 30 min)
runs as a backstop and as the only mechanism while the user is mid-
backfill — it pages chats/invitations sorted by last activity and dedupes
against `sources[]`. Adaptive polling cadence is removed: webhooks make it
unnecessary, and Unipile rate-limits cover both paths.

## Migration

A single SQL migration:

```sql
UPDATE twist_instance_connection
   SET needs_reauth_at = now(),
       recovery_pending = true
 WHERE provider = 'linkedin'
   AND needs_reauth_at IS NULL;
```

Existing cookie-based tokens become inert because all the Voyager call
sites are deleted in the same change. The Flutter app already surfaces a
"Reconnect" prompt for connections with `needs_reauth_at` set; existing
users land in that path and complete a Unipile hosted-auth flow as if
connecting for the first time.

## Full delete list

**Public submodule (`public/`):**

- `public/connectors/linkedin-messaging/` — entire package.
- `public/twister/src/tools/linkedin.ts`.
- `public/twister/src/llm-docs/tools/linkedin.ts`.
- `LinkedInProviderData` from `public/twister/src/tools/integrations.ts`.
- Changeset: `"@plotday/twister": minor`, `Removed:` LinkedIn tool and
  related types.

**This repo:**

- `workers/api/src/twist/tools/linkedin.ts`.
- `workers/api/src/twist/tools/linkedin-voyager.ts`.
- `POST /twist/:id/integrations/linkedin/cookie` and
  `LinkedInCookieRequestSchema` in
  `workers/api/src/app/twist-integrations.ts`.
- `LINKEDIN_RATE_LIMITER` binding from `workers/api/wrangler.jsonc` and
  any TypeScript references.
- `LinkedInProviderData` and the related branch in `extractUserId` /
  `parseTokenResponse` in `workers/api/src/provider.ts`.
- `apps/plot/lib/widget/linkedin_login_modal.dart`.
- LinkedIn branch and `_startLinkedInCookieFlow` in
  `apps/plot/lib/widget/auth_button.dart`.
- `postLinkedInCookie` and `TwistLinkedInCookieResult` in
  `apps/plot/lib/api/twist_api.dart`.

## New files

**Public submodule:** none. (The whole point: no public Unipile surface.)

**This repo:**

- `libs/unipile/` — workspace package `@plotday/unipile`.
  - `src/index.ts` (barrel)
  - `src/account.ts` — abstract `HostedAccount` tool class.
  - `src/linkedin.ts` — abstract `LinkedInMessaging` tool + types.
  - `src/types.ts` — shared shapes.
  - `package.json`, `tsconfig.json`.
- `workers/api/src/twist/tools/unipile/` — concrete impls.
  - `client.ts`, `account.ts`, `linkedin.ts`, `normalize.ts`, `webhook.ts`,
    `types.ts`.
- `workers/api/src/app/twist-integrations.ts` — additions for `authMode:
  "hosted"` branch; webhook route registration.
- `workers/api/src/app/hook-messaging.ts` — `/hook/messaging` handler.
- `connectors/linkedin/` — package `@plotday/connector-linkedin`.
  - `src/index.ts`
  - `src/linkedin.ts`
  - `package.json`, `tsconfig.json`, `README.md`, `LICENSE`.
- `pnpm-workspace.yaml` — add `connectors/*`.
- `libs/db/migrations/<timestamp>_linkedin_reauth.sql`.

## Env vars / secrets

Added to `workers/api/.dev.vars` (and Cloudflare secrets):

```
UNIPILE_API_KEY=<workspace API key>
UNIPILE_DSN=<region subdomain, e.g. "api6">
UNIPILE_WEBHOOK_SECRET=<for /hook/messaging signature verification>
```

A development webhook URL of `https://api-kris.plot.day/hook/messaging`
is registered with Unipile's workspace webhook config (the existing
cloudflared tunnel pattern from AGENTS.md).

## Open questions deferred to implementation

- Does Unipile's `account.error` event mean a single bad sync or a fully
  expired session? Verify against Unipile's docs during implementation;
  err toward `needs_reauth_at` only on the fully-expired signal.
- Unipile's webhook signature format — confirm header name and HMAC mode.
- `onCreateLink` (Plot-initiated LinkedIn message) is out of scope for
  this change; we keep the existing `createDefault: false` shape.

## Non-goals

- Adding WhatsApp or Instagram connectors. The package, server-side
  infrastructure, and abstract types are laid out so that adding them is
  a copy-the-LinkedIn-connector exercise, but the actual connectors ship
  in follow-up PRs.
- Backfilling historical archives. Initial sync walks a single page per
  branch (DMs ~20, invitations ~20) as the existing connector does, to
  keep the import bounded.
- Changing the channel model for other connectors. The "single channel,
  data-type options" pattern here is LinkedIn-specific for now.
