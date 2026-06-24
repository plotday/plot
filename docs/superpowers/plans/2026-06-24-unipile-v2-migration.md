# Unipile v1 → v2 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Plot's Unipile integration (LinkedIn / Instagram / WhatsApp connectors) from Unipile API v1 to v2 — a hard cutover, require-reconnect, code + tests green locally, then verified against the live v2 API via the Cloudflare tunnel. No production deploy.

**Architecture:** All changes live in the API worker (`workers/api`). The single `UnipileClient` (`src/twist/tools/unipile/client.ts`) is the only file that knows Unipile's URL shape; the messaging wrapper, normalize layer, webhook receiver, and bootstrap script sit around it. Connectors and the public `libs/unipile` abstraction consume only normalized Plot shapes and are NOT touched. We migrate domain-by-domain (accounts, auth, chats, messages, LinkedIn) so the test suite stays green at every commit, then update the webhook receiver and bootstrap, then live-verify.

**Tech Stack:** TypeScript, Cloudflare Workers, Hono, vitest, pnpm. Unipile REST API v2 (single host `https://api.unipile.com`, `X-API-KEY` header).

## CONFIRMED v2 REALITY (authoritative — supersedes any conflicting assumption below)

Probed live against the dev mock account `acc_01kvwz2rk0e8k81mgrp27mye6t` (provider `mock`, user `mock-user-me`) on 2026-06-24. Where the task code blocks below assume different shapes (`/api/v2`, `items`/`cursor`, `name`/`picture_url`, separate attendees, `events`/`request_url`), **this section wins.**

- **Base host:** `https://api.unipile.com` — **NO DSN.** `UNIPILE_DSN` is removed everywhere. New key at `op://$ENV/Unipile/v2/api key` → `UNIPILE_API_KEY`. `X-API-KEY` header unchanged.
- **Version prefix:** `/v2` (NOT `/api/v2`; `/api/v2` returns 404). Full URL = `https://api.unipile.com/v2/...`.
- **`account_id` in path** for messaging/users routes: `/v2/:account_id/chats`, `/v2/:account_id/users/me`, etc. Account/webhook routes are workspace-level: `/v2/accounts`, `/v2/webhooks/endpoints`.
- **List wrapper:** `{ object: "<Name>s", data: T[], has_more: boolean }` (NOT `{ items, cursor }`). Pagination `?limit=&offset=`; walk while `has_more`.
- **Account:** `{ object:"Account", id:"acc_…", user_id, provider, status, name, created_at, application_id, metadata }`. **Identity = `user_id`** (no `connection_params`). `provider` (not `type`). `status` is a string (`"running"`).
- **UserProfile** (`users/me`, `users/:id`): `{ id, object:"UserProfile", type, display_name, public_identifier, first_name, last_name, public_picture_url, bio, location, specifics:{network_distance,…}, provider }`. (Provider id = `id`; name = `display_name`; pic = `public_picture_url`; handle = `public_identifier` top-level. email, when present, under `specifics`.)
- **Chat:** `{ object:"Chat", id, name, is_group, is_1to1, type, is_archived, unread_count, folders:[], provider, last_message_timestamp, participants_count, last_message:{text,is_sender}, specifics }`. Group adds `participants:[{object:"GroupParticipant", is_self, is_admin, user:{User}}]`; 1:1 adds top-level `user_id` + `user:{User}` (the other party; self implicit). **Participants are embedded — no separate attendees call.** `id` is the provider thread id (no separate `provider_id`).
- **Embedded User:** `{ id, object:"User", type, display_name, public_identifier, first_name, last_name, public_picture_url, specifics:{network_distance} }`.
- **Message:** `{ object:"Message", id, sender_id, chat_id, timestamp, is_sender(bool), is_seen(bool), is_event(bool), reactions_counter:[], attachments:[], text, provider, sender:{User} }`. `event_type` only on event messages (confirm in live verify).
- **Webhook endpoint:** `POST /v2/webhooks/endpoints` body `{ name, url, trigger_events:[…], headers?:[{key,value}] }` → `{ object:"WebhookEndpoint", id:"we_…", url, trigger_events, secret:"wes_…", enabled, account_ids:[], account_targets:[] }`. List `{ object:"WebhookEndpoints", data:[…], has_more }`; delete `DELETE /v2/webhooks/endpoints/:id`. **Auth model change:** v2 returns a per-endpoint signing `secret` (`wes_…`); custom `headers` are accepted but not echoed → **verify deliveries via the v2 signature** (exact header/scheme confirmed during live verification by logging the first delivery's headers). `message.new` is a valid `trigger_event`; validate the rest of the event list by attempting creation (the API names any invalid index).

## Global Constraints

- **Only work locally. Never deploy.** This includes workers — they only run locally. (AGENTS.md)
- **v2 host stays per-tenant DSN.** Base = `https://${UNIPILE_DSN}`; the v1 version segment `/api/v1` becomes the v2 segment. Env vars `UNIPILE_API_KEY`, `UNIPILE_DSN`, `UNIPILE_WEBHOOK_SECRET` all remain.
- **v2 version prefix = `/api/v2`** (assumed; **confirm in Task 0** against the live reference — if it is bare `/v2`, do a global replace of `/api/v2` → `/v2` and re-run the suite). Every task below writes `/api/v2`.
- **`account_id` moves into the URL path** for messaging/users routes: `/api/v2/:account_id/...`. It is no longer a query/body param.
- **Pagination:** `cursor` → `offset`/`limit` (numbers). List responses carry `cursor` today; v2 may return an offset/limit cursor or none — keep the wrapper's `nextCursor` contract by deriving it (see Task 4).
- **Attachments:** sent as base64 JSON (`{ filename, content_type, data }`), not multipart.
- **IDs:** Unipile-generated IDs gain prefixes (`acc_` accounts, `we_` webhooks); message/chat IDs are provider IDs. Treat all IDs as opaque strings — never parse them.
- **Error capture:** any new `catch` for an unexpected error calls `tracker.captureException(...)` (or `captureServerError` in route handlers). Do NOT capture expected errors (auth failures, 404s).
- **Run tests from `workers/api`:** `pnpm vitest run <path>` for a file, `pnpm vitest run src/twist/tools/unipile` for the suite. Lint: `pnpm lint` in `workers/api`.
- **Commit cadence:** one commit per task, message prefixed `feat(unipile-v2):` / `refactor(unipile-v2):` / `test(unipile-v2):`, ending with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

---

## Task 0: Confirm the v2 path prefix and core conventions

**Files:** none (research only — record findings in the commit message of Task 1).

- [ ] **Step 1: Confirm the version prefix and DSN host.** Fetch the live v2 reference for "List accounts" and one messaging route. Confirm whether the path is `/api/v2/...` or `/v2/...`, that the host is the tenant DSN, and that the auth header is `X-API-KEY`.

Run (WebFetch): `https://developer.unipile.com/v2.0/reference` and the messaging/accounts pages under it; cross-check against `https://github.com/unipile/unipile-node-sdk` (`src/` path builders).
Expected: a definitive prefix string. Default to `/api/v2` if the reference is ambiguous; the live-verify phase (Task 9) is the backstop.

- [ ] **Step 2: Record the confirmed prefix** at the top of this plan (edit the Global Constraints line if it differs from `/api/v2`). No code yet.

---

## Task 1: Centralize the version segment in the client (safe refactor, no behavior change)

Make `this.base` the host only and give every method an explicit version segment, so later tasks can flip endpoints to v2 **one domain at a time** while the suite stays green. URLs are byte-identical after this task, so **no test changes**.

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Test: `workers/api/src/twist/tools/unipile/client.test.ts` (run only — must still pass unchanged)

**Interfaces:**
- Produces: `private base = "https://${DSN}"` (host only); a `private readonly v1 = "/api/v1"` segment is prepended inside the path-building helpers `get`/`post`/`request`/`requestFormData` and the inline URL in `downloadAttachmentRaw`. Public method signatures unchanged.

- [ ] **Step 1: Change the base to host-only and thread the version segment through the helpers.**

In `client.ts`, change the constructor base:

```ts
// was: this.base = `https://${env.UNIPILE_DSN}/api/v1`;
this.base = `https://${env.UNIPILE_DSN}`;
```

Add a version field on the class (near `private readonly base: string;`):

```ts
/** API version path segment. Flipped to /api/v2 domain-by-domain. */
private apiVersion = "/api/v1";
```

Update the three private helpers and `downloadAttachmentRaw` to prepend `this.apiVersion`:

```ts
private get<T>(path: string, query?: Record<string, string>): Promise<T> {
  const qs =
    query && Object.keys(query).length > 0
      ? "?" + new URLSearchParams(query).toString()
      : "";
  return this.request<T>(`${this.apiVersion}${path}${qs}`, { method: "GET" });
}

private post<T>(path: string, body: unknown): Promise<T> {
  return this.request<T>(`${this.apiVersion}${path}`, {
    method: "POST",
    body: JSON.stringify(body),
    headers: { "content-type": "application/json" },
  });
}

private async requestFormData<T>(path: string, form: FormData): Promise<T> {
  const url = `${this.base}${this.apiVersion}${path}`;
  /* ...unchanged body... */
}
```

`request<T>` already receives a path that now includes the version (from `get`/`post`); for the one direct `request` caller paths (`deleteAccount`, `deleteWebhook`, `setChatRead`, `setChatRequestStatus`, `acceptInvitation`, `ignoreInvitation`) prepend the version at the call site, e.g.:

```ts
await this.request(`${this.apiVersion}/accounts/${encodeURIComponent(accountId)}`, { method: "DELETE" });
```

And in `downloadAttachmentRaw`:

```ts
const url = `${this.base}${this.apiVersion}/messages/${encodeURIComponent(input.messageId)}/attachments/${encodeURIComponent(input.attachmentId)}`;
```

Leave `request<T>`'s internal `const url = `${this.base}${path}`;` as-is (path now carries the version).

- [ ] **Step 2: Run the client + cleanup tests — they must pass with NO edits (URLs unchanged).**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts src/twist/tools/unipile/account-cleanup.test.ts`
Expected: PASS (same `https://api7.unipile.com:13441/api/v1/...` URLs as before).

- [ ] **Step 3: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/client.ts
git commit -m "refactor(unipile-v2): centralize API version segment in client

No behavior change — base becomes host-only and an apiVersion segment is
prepended in the request helpers, so v2 endpoints can be flipped per domain.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Accounts + webhooks endpoints → v2

Migrate workspace-level endpoints (no `account_id` in path): account list/get/delete and the webhook registration endpoints (unified `/webhooks/endpoints`). Flip `apiVersion` to `/api/v2` here — all other domains were made version-independent in Task 1 by carrying their own `/api/v1`... **wait:** Task 1 used a single `apiVersion` field, so flipping it flips everything. To migrate per-domain, **convert the shared field into per-call literals in this task for the account/webhook methods only**, and keep `apiVersion = "/api/v1"` for the rest. Concretely: this task changes the account/webhook method paths to start with `/api/v2` explicitly and bypass `apiVersion`.

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Modify: `workers/api/src/twist/tools/unipile/types.ts`
- Test: `workers/api/src/twist/tools/unipile/client.test.ts`, `workers/api/src/twist/tools/unipile/account-cleanup.test.ts`

**Interfaces:**
- Produces (client): `listAccounts()` (offset/limit), `getAccount(id)`, `deleteAccount(id)`, `listWebhooks()`, `createWebhook(input)`, `deleteWebhook(id)` — all on `/api/v2/...`.
- Produces (types): `UnipileAccount` with `provider` (was `type`); `UnipileWebhook` shape for `/webhooks/endpoints`.

- [ ] **Step 1: Add a private absolute-path escape hatch** so a method can pin its own version regardless of `apiVersion`:

```ts
private getAbs<T>(absPath: string, query?: Record<string, string>): Promise<T> {
  const qs = query && Object.keys(query).length > 0 ? "?" + new URLSearchParams(query).toString() : "";
  return this.request<T>(`${absPath}${qs}`, { method: "GET" });
}
private postAbs<T>(absPath: string, body: unknown): Promise<T> {
  return this.request<T>(absPath, { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } });
}
```
(`request<T>` prepends only `this.base`, so `absPath` must start with `/api/v2`.)

- [ ] **Step 2: Write the failing test for v2 account paths.** In `client.test.ts`, update the `listAccounts` test URLs and add `offset` pagination:

```ts
// listAccounts walks pages with offset/limit
expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/accounts?limit=100");
expect(calls[1]!.url).toBe("https://api7.unipile.com:13441/api/v2/accounts?limit=100&offset=100");
```
In `account-cleanup.test.ts` update the DELETE URL:
```ts
expect(String(url)).toBe("https://api7.unipile.com:13441/api/v2/accounts/acct-1");
```

- [ ] **Step 3: Run the tests to verify they fail.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts src/twist/tools/unipile/account-cleanup.test.ts`
Expected: FAIL on the account-path assertions (still `/api/v1/...`).

- [ ] **Step 4: Implement v2 account + webhook methods.** Replace the bodies:

```ts
getAccount(accountId: string): Promise<UnipileAccount> {
  return this.getAbs<UnipileAccount>(`/api/v2/accounts/${encodeURIComponent(accountId)}`);
}

async deleteAccount(accountId: string): Promise<void> {
  await this.request(`/api/v2/accounts/${encodeURIComponent(accountId)}`, { method: "DELETE" });
}

/** v2 lists are offset/limit paginated. Walk until a short page. */
async listAccounts(): Promise<UnipileAccount[]> {
  const out: UnipileAccount[] = [];
  const limit = 100;
  let offset = 0;
  for (;;) {
    const page = await this.getAbs<UnipileAccountList>("/api/v2/accounts",
      offset === 0 ? { limit: String(limit) } : { limit: String(limit), offset: String(offset) });
    out.push(...page.items);
    if (page.items.length < limit) break;
    offset += limit;
  }
  return out;
}

listWebhooks(): Promise<{ object: string; items: UnipileWebhook[] }> {
  return this.getAbs<{ object: string; items: UnipileWebhook[] }>("/api/v2/webhooks/endpoints");
}

createWebhook(input: { requestUrl: string; events: string[]; headers?: { key: string; value: string }[] }): Promise<UnipileWebhook> {
  return this.postAbs<UnipileWebhook>("/api/v2/webhooks/endpoints", {
    request_url: input.requestUrl,
    events: input.events,
    ...(input.headers ? { headers: input.headers } : {}),
  });
}

async deleteWebhook(id: string): Promise<void> {
  await this.request(`/api/v2/webhooks/endpoints/${encodeURIComponent(id)}`, { method: "DELETE" });
}
```

> **LIVE-CONFIRM (Task 9):** exact `/webhooks/endpoints` request body field names and whether `headers` (custom delivery headers) are supported. If not supported, Task 7 switches webhook auth to signature verification.

- [ ] **Step 5: Update `types.ts` for the v2 account + webhook shapes.**

```ts
export type UnipileAccount = {
  object: "Account";
  id: string;              // acc_… prefix in v2; opaque
  provider: UnipileAccountSource;   // was `type`
  created_at: string;
  name?: string;
  // connection_params/sources removed in v2; identity now via provider profile.
};

export type UnipileAccountList = {
  object: "AccountList";
  items: UnipileAccount[];
  cursor?: string | null;  // tolerated; pagination is offset/limit
};

export type UnipileWebhook = {
  object: "WebhookEndpoint";
  id: string;              // we_… prefix
  request_url: string;
  events?: string[] | null;
  headers?: { key: string; value: string }[];
};
```
Remove `UnipileWebhookSource` usages that no longer apply (the unified endpoint has no `source`). Keep the type exported if still referenced; otherwise delete it and fix imports (Task 6/bootstrap).

- [ ] **Step 6: Fix `account-cleanup.ts` identity resolution** (it read `connection_params.im.id`, removed in v2). Resolve identity via the provider profile instead:

```ts
async function accountIdentity(client: UnipileClient, account: UnipileAccount): Promise<string | null> {
  try {
    const profile = await client.getOwnProfile({ accountId: account.id });
    return profile.provider_id ?? null;
  } catch {
    return null;
  }
}
```
(Remove the `connection_params` references.)

- [ ] **Step 7: Run the tests to verify they pass.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts src/twist/tools/unipile/account-cleanup.test.ts`
Expected: PASS.

- [ ] **Step 8: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/unipile/types.ts workers/api/src/twist/tools/unipile/account-cleanup.ts workers/api/src/twist/tools/unipile/client.test.ts workers/api/src/twist/tools/unipile/account-cleanup.test.ts
git commit -m "feat(unipile-v2): migrate accounts + webhook endpoints to v2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Hosted auth + own-profile → v2

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Modify: `workers/api/src/twist/tools/unipile/types.ts` (UnipileAttendee/UnipileHostedAuthLink if shape changed)
- Modify: `workers/api/src/app/authBridge.ts` (only if a field it reads moved)
- Test: `workers/api/src/twist/tools/unipile/client.test.ts`

**Interfaces:**
- Produces: `createHostedAuthLink(input)` → `POST /api/v2/auth/link`; `getOwnProfile({accountId})` → `GET /api/v2/:account_id/users/me`.

- [ ] **Step 1: Write failing tests** for the two v2 paths in `client.test.ts`:

```ts
test("createHostedAuthLink posts /api/v2/auth/link", async () => {
  const { client, calls } = recordingClient(() => new Response(JSON.stringify({ object: "HostedAuthURL", url: "https://x" }), { status: 200 }));
  await client.createHostedAuthLink({ providers: ["LINKEDIN"], name: "state1", successRedirectUrl: "s", failureRedirectUrl: "f", notifyUrl: "n", expiresAt: new Date("2026-01-01T00:00:00Z") });
  expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/auth/link");
  expect(calls[0]!.init.method).toBe("POST");
});

test("getOwnProfile targets /api/v2/:account_id/users/me", async () => {
  const { client, calls } = recordingClient(() => new Response(JSON.stringify({ object: "Attendee", provider_id: "me" }), { status: 200 }));
  await client.getOwnProfile({ accountId: "acc1" });
  expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/acc1/users/me");
});
```

- [ ] **Step 2: Run to verify failure.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts -t "auth"`
Expected: FAIL (paths still v1 / method missing).

- [ ] **Step 3: Implement.**

```ts
async createHostedAuthLink(input: {
  providers: ("LINKEDIN" | "WHATSAPP" | "INSTAGRAM")[];
  name: string;
  successRedirectUrl: string;
  failureRedirectUrl: string;
  notifyUrl: string;
  expiresAt: Date;
}): Promise<UnipileHostedAuthLink> {
  return this.postAbs<UnipileHostedAuthLink>("/api/v2/auth/link", {
    type: "create",
    providers: input.providers,
    api_url: this.base,                       // host only in v2
    expiresOn: input.expiresAt.toISOString(),
    name: input.name,
    success_redirect_url: input.successRedirectUrl,
    failure_redirect_url: input.failureRedirectUrl,
    notify_url: input.notifyUrl,
  });
}

getOwnProfile(input: { accountId: string }): Promise<UnipileAttendee> {
  return this.getAbs<UnipileAttendee>(`/api/v2/${encodeURIComponent(input.accountId)}/users/me`);
}
```

> **LIVE-CONFIRM (Task 9):** exact `/api/v2/auth/link` body (v2 redesigned hosted auth — field names may differ, e.g. `expiresOn` → `expires_at`). Confirm and adjust the body keys.

- [ ] **Step 4: authBridge.ts** — it reads `profile.name`, `profile.specifics?.email`, `profile.provider_id` (all still present on `UnipileAttendee`) and, in the fallback, `account.connection_params?.im?.id` (removed in v2). Change that fallback line:

```ts
// was: userId = account.connection_params?.im?.id ?? result.accountId;
userId = account.name ? result.accountId : result.accountId; // v2: no connection_params; keep accountId
```
Simplify to `userId = result.accountId;` in the `getAccount` fallback branch and drop the `connection_params` read.

- [ ] **Step 5: Run to verify pass.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/unipile/types.ts workers/api/src/app/authBridge.ts workers/api/src/twist/tools/unipile/client.test.ts
git commit -m "feat(unipile-v2): hosted auth link and own-profile fetch on v2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Chats read → v2 (account_id in path, attendees, offset/limit)

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts` (listChats, getChat, listChatAttendees, getUser)
- Modify: `workers/api/src/twist/tools/unipile/types.ts` (UnipileChat renames)
- Modify: `workers/api/src/twist/tools/unipile/normalize.ts` (normalizeChat field reads)
- Modify: `workers/api/src/twist/tools/unipile/messaging.ts` (thread accountId; attendee handling)
- Test: `client.test.ts`, `normalize.test.ts`

**Interfaces:**
- Produces (client): `listChats({accountId, offset?, limit?, folder?})`; `getChat({accountId, chatId})`; `listChatAttendees({accountId, chatId})` (or removed if attendees embed in chat — see LIVE-CONFIRM); `getUser({accountId, identifier})`.
- Consumes: `getAbs`/`postAbs` from Task 2.

- [ ] **Step 1: Write failing test for v2 listChats path.** In `client.test.ts`, update the first test:

```ts
expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/acct-1/chats");
```

- [ ] **Step 2: Update `normalize.test.ts` chat fixtures to v2 wire shapes.** Change the two `normalizeChat` input objects: `timestamp` → `last_message_timestamp`, `archived: 0` → `is_archived: false`, drop `account_type`/`read_only`/`muted_until`/`attendee_provider_id` numerics, keep `id`, `name`, `type`. Keep the EXPECTED outputs (Plot shapes) identical (`chat.unreadCount`, `chat.url`, `chat.folder`).

- [ ] **Step 3: Run to verify failure.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts src/twist/tools/unipile/normalize.test.ts`
Expected: FAIL.

- [ ] **Step 4: Implement v2 chat-read client methods.**

```ts
listChats(input: { accountId: string; offset?: number; limit?: number; folder?: string | null }): Promise<UnipileChatList> {
  return this.getAbs<UnipileChatList>(`/api/v2/${encodeURIComponent(input.accountId)}/chats`, {
    ...(input.limit ? { limit: String(input.limit) } : {}),
    ...(input.offset ? { offset: String(input.offset) } : {}),
    ...(input.folder ? { folder: input.folder } : {}),
  });
}

getChat(input: { accountId: string; chatId: string }): Promise<UnipileChat> {
  return this.getAbs<UnipileChat>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}`);
}

getUser(input: { accountId: string; identifier: string }): Promise<UnipileAttendee> {
  return this.getAbs<UnipileAttendee>(`/api/v2/${encodeURIComponent(input.accountId)}/users/${encodeURIComponent(input.identifier)}`);
}
```

For attendees: **LIVE-CONFIRM (Task 9)** whether v2 embeds participants in the chat object or keeps a per-chat endpoint. Implement both-safe: keep `listChatAttendees` but on the v2 path, and have `normalizeChat` accept embedded attendees if present:

```ts
listChatAttendees(input: { accountId: string; chatId: string }): Promise<UnipileAttendeeList> {
  return this.getAbs<UnipileAttendeeList>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/attendees`);
}
```

- [ ] **Step 5: Update `types.ts` `UnipileChat`:**

```ts
export type UnipileChat = {
  object: "Chat";
  id: string;
  account_id: string;
  provider: UnipileAccountSource;     // was account_type
  name: string | null;
  type: 0 | 1;
  last_message_timestamp: string;     // was timestamp
  unread_count: number;
  is_archived: boolean;               // was archived: 0|1
  folder?: string;
  attendees?: UnipileAttendee[];      // v2 may embed
};
```

- [ ] **Step 6: Update `normalize.ts` `normalizeChat`** to read the renamed fields (keep output identical):

```ts
lastActivityAt: new Date(chat.last_message_timestamp),
archived: chat.is_archived === true,
```
For the `url`, v2 chat uses `id` as the provider thread id (no separate `provider_id`): `provider === "linkedin" ? \`https://www.linkedin.com/messaging/thread/${chat.id}/\` : null`. **LIVE-CONFIRM (Task 9)**: whether the LinkedIn thread URL should use `chat.id` or another field.

- [ ] **Step 7: Update `messaging.ts`** to pass `accountId` and prefer embedded attendees:

```ts
async listChats(params) {
  await this.assertAccount(params.channelId);
  const result = await this.client.listChats({ accountId: params.channelId, limit: params.limit });
  const chats: ChatThread[] = [];
  for (const raw of result.items) {
    const attendees = raw.attendees ?? (await this.client.listChatAttendees({ accountId: params.channelId, chatId: raw.id })).items;
    const chat = normalizeChat(raw, attendees, this.provider);
    if (params.since && chat.lastActivityAt < params.since) continue;
    chats.push(chat);
  }
  return { chats, nextCursor: result.cursor ?? null };
}

async getChat(params) {
  await this.assertAccount(params.channelId);
  const raw = await this.client.getChat({ accountId: params.channelId, chatId: params.chatId });
  const attendees = raw.attendees ?? (await this.client.listChatAttendees({ accountId: params.channelId, chatId: params.chatId })).items;
  return normalizeChat(raw, attendees, this.provider);
}
```
(`listChats` signature already drops `cursor` in favor of offset internally; the wrapper's public `cursor?` param is ignored for the page walk — keep the param for interface compatibility but stop forwarding it.)

- [ ] **Step 8: Run to verify pass.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts src/twist/tools/unipile/normalize.test.ts src/twist/tools/unipile/messaging.test.ts`
Expected: PASS.

- [ ] **Step 9: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/unipile/types.ts workers/api/src/twist/tools/unipile/normalize.ts workers/api/src/twist/tools/unipile/messaging.ts workers/api/src/twist/tools/unipile/client.test.ts workers/api/src/twist/tools/unipile/normalize.test.ts
git commit -m "feat(unipile-v2): chats read on v2 (account in path, embedded attendees)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Messages → v2 (list, send, start chat, attachments base64, reactions, read-state)

**Files:**
- Modify: `client.ts` (listMessages, sendMessage, sendMessageMultipart→base64, startChat, downloadAttachmentRaw, addMessageReaction, removeMessageReaction, setChatRead, setChatRequestStatus)
- Modify: `types.ts` (UnipileMessage renames; reactions_counter)
- Modify: `normalize.ts` (normalizeMessage field reads)
- Modify: `messaging.ts` (thread accountId into all message methods)
- Test: `client.test.ts`, `normalize.test.ts`

**Interfaces:**
- Produces (client): every message method gains `accountId`; `sendMessage({accountId, chatId, text})` → `POST /api/v2/:account_id/chats/:chat_id/messages/send`; `startChat` → `POST /api/v2/:account_id/chats/send` with `users_ids` + base64 attachments.

- [ ] **Step 1: Write failing tests** in `client.test.ts`:

```ts
test("sendMessage posts to v2 send path", async () => {
  const { client, calls } = recordingClient(() => new Response(JSON.stringify({ id: "m" }), { status: 200 }));
  await client.sendMessage({ accountId: "acc1", chatId: "c1", text: "hi" });
  expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/acc1/chats/c1/messages/send");
});

test("startChat posts /api/v2/:account/chats/send with users_ids", async () => {
  const { client, calls } = recordingClient(() => new Response(JSON.stringify({ id: "m", chat_id: "c" }), { status: 200 }));
  await client.startChat({ accountId: "acc1", attendeeProviderIds: ["a", "b"], text: "hi", title: "Crew" });
  expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/acc1/chats/send");
  const body = JSON.parse(String(calls[0]!.init.body));
  expect(body.users_ids).toEqual(["a", "b"]);
  expect(body.text).toBe("hi");
});
```
Update the existing `removeMessageReaction` test URL expectation to the v2 reaction path (see Step 4 LIVE-CONFIRM) and the existing `startChat` test (lines 66–83) is replaced by the one above.

- [ ] **Step 2: Run to verify failure.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement v2 message methods.**

```ts
listMessages(input: { accountId: string; chatId: string; offset?: number; limit?: number }): Promise<UnipileMessageList> {
  return this.getAbs<UnipileMessageList>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages`, {
    ...(input.limit ? { limit: String(input.limit) } : {}),
    ...(input.offset ? { offset: String(input.offset) } : {}),
  });
}

sendMessage(input: { accountId: string; chatId: string; text: string }): Promise<UnipileMessage> {
  return this.postAbs<UnipileMessage>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages/send`, { text: input.text });
}

/** v2: attachments are base64 JSON, not multipart. */
async sendMessageMultipart(input: { accountId: string; chatId: string; text: string; attachments: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> }): Promise<UnipileMessage> {
  const attachments = input.attachments.map((a) => ({ filename: a.filename, content_type: a.mimeType, data: base64FromBytes(a.buffer) }));
  return this.postAbs<UnipileMessage>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages/send`, { text: input.text, attachments });
}

async startChat(input: { accountId: string; attendeeProviderIds: string[]; text: string; title?: string | null }): Promise<UnipileMessage> {
  return this.postAbs<UnipileMessage>(`/api/v2/${encodeURIComponent(input.accountId)}/chats/send`, {
    users_ids: input.attendeeProviderIds,
    text: input.text,
    ...(input.title ? { name: input.title } : {}),
  });
}
```

Add the base64 helper at the bottom of the file (module scope):

```ts
function base64FromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!);
  return btoa(binary);
}
```

`downloadAttachmentRaw`, `addMessageReaction`, `removeMessageReaction`, `setChatRead`, `setChatRequestStatus` all gain `accountId` and move under `/api/v2/:account_id/chats/:chat_id/...`:

```ts
async setChatRead(input: { accountId: string; chatId: string; read: boolean }): Promise<void> {
  await this.request(`/api/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}`, {
    method: "PATCH",
    body: JSON.stringify({ action: input.read ? "setReadStatus" : "setUnreadStatus", value: input.read }),
    headers: { "content-type": "application/json" },
  });
}
```

> **LIVE-CONFIRM (Task 9):** exact v2 paths/bodies for: attachment download, message reaction add/clear (likely `/api/v2/:account_id/chats/:chat_id/messages/:message_id/reaction`), set-read action token, and IG message-request accept/decline. Encode the confirmed paths; keep the POST-empty-then-DELETE clear-reaction fallback only if v2 still needs it.

- [ ] **Step 4: Update `types.ts` `UnipileMessage`:**

```ts
export type UnipileMessage = {
  object: "Message";
  id: string;                  // was provider_id; provider id in v2
  chat_id: string;
  sender_id: string;           // was sender_attendee_id for our purposes
  timestamp: string;
  is_sender: boolean;          // v2 booleans (was 0|1)
  is_event?: boolean;
  event_type?: string;
  is_seen?: boolean;           // was seen
  text: string | null;
  attachments?: UnipileAttachment[];
  reactions_counter?: Array<{ value: string; count: number; reacted: boolean }>; // was reactions[]
};
```

- [ ] **Step 5: Update `normalize.ts` `normalizeMessage`** for booleans and reactions_counter:

```ts
export function normalizeMessage(msg: UnipileMessage): ChatMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    sentByMe: msg.is_sender === true,
    eventType: msg.is_event === true ? msg.event_type ?? "unknown" : null,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
    reactions: (msg.reactions_counter ?? []).map((r) => ({ value: r.value, senderId: "", sentByMe: r.reacted === true })),
  };
}
```
> **LIVE-CONFIRM (Task 9):** v2 reactions_counter shape (does it carry per-reactor `sender_id`? if not, `senderId` stays `""` — verify the connector tolerates it; the LinkedIn connector uses reactions for write-back fidelity, see memory `ms_teams_reaction_writeback`).

- [ ] **Step 6: Update `normalize.test.ts` message fixtures** to v2 (`is_sender: true`, `is_seen: true`, `reactions_counter: [{ value: "👍", count: 1, reacted: true }]`) and adjust the reaction expectation to the new mapping.

- [ ] **Step 7: Update `messaging.ts`** to thread `accountId` (= `params.channelId`) into every client message call (`listMessages`, `sendMessage`/`sendMessageMultipart`, `downloadAttachmentRaw`, `setChatRead`, `addMessageReaction`, `removeMessageReaction`, `startChat`, `getAttendee`). Example:

```ts
async listMessages(params) {
  await this.assertAccount(params.channelId);
  const result = await this.client.listMessages({ accountId: params.channelId, chatId: params.chatId, limit: params.limit });
  const messages = result.items.map(normalizeMessage).filter((m) => !params.since || m.sentAt >= params.since);
  return { messages, nextCursor: result.cursor ?? null };
}
```
`getAttendee` and `getProfile`: `getAttendee({ accountId, providerId })` → `GET /api/v2/:account_id/users/:provider_id`; update `getProfile` to pass `accountId: params.channelId`.

- [ ] **Step 8: Run the full unipile suite.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile`
Expected: PASS (all files).

- [ ] **Step 9: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/
git commit -m "feat(unipile-v2): messages, send, start-chat, attachments, reactions on v2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: LinkedIn invitations + relations → v2

**Files:**
- Modify: `client.ts` (listReceivedInvitations, acceptInvitation, ignoreInvitation, listRelations)
- Modify: `types.ts` if invitation/relation shapes changed
- Modify: `normalize.ts` only if relation/invitation fields renamed
- Test: `client.test.ts` (listRelations URL)

**Interfaces:**
- Produces: `listRelations({accountId, offset?, limit?})` → `GET /api/v2/:account_id/users/relations`; invitations on their v2 paths.

- [ ] **Step 1: Write failing test** — update the `listRelations` URL in `client.test.ts`:

```ts
expect(calls[0]!.url).toBe("https://api7.unipile.com:13441/api/v2/acct-1/users/relations?limit=50");
```
(Drop `account_id`/`cursor` query; v2 puts account in path and uses offset/limit.)

- [ ] **Step 2: Run to verify failure.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile/client.test.ts -t "listRelations"`
Expected: FAIL.

- [ ] **Step 3: Implement.**

```ts
listRelations(input: { accountId: string; offset?: number; limit?: number }): Promise<UnipileRelationList> {
  return this.getAbs<UnipileRelationList>(`/api/v2/${encodeURIComponent(input.accountId)}/users/relations`, {
    ...(input.limit ? { limit: String(input.limit) } : {}),
    ...(input.offset ? { offset: String(input.offset) } : {}),
  });
}

listReceivedInvitations(input: { accountId: string; offset?: number; limit?: number }): Promise<UnipileInvitationList> {
  return this.getAbs<UnipileInvitationList>(`/api/v2/${encodeURIComponent(input.accountId)}/users/invitations`, {
    ...(input.limit ? { limit: String(input.limit) } : {}),
    ...(input.offset ? { offset: String(input.offset) } : {}),
  });
}

async acceptInvitation(input: { accountId: string; invitationId: string; sharedSecret: string }): Promise<void> {
  await this.request(`/api/v2/${encodeURIComponent(input.accountId)}/users/invitations/${encodeURIComponent(input.invitationId)}`, {
    method: "POST",
    body: JSON.stringify({ action: "accept", shared_secret: input.sharedSecret }),
    headers: { "content-type": "application/json" },
  });
}
// ignoreInvitation: same shape, action: "ignore".
```

> **LIVE-CONFIRM (Task 9):** exact v2 LinkedIn invitation list/accept/ignore paths and relation shape (relations may now nest under `specifics`; the migration notes renamed `first_name`/`last_name` → `display_name` in some search payloads — confirm the relations payload and adjust `normalizeRelation` + its tests only if it actually changed).

- [ ] **Step 4: Thread `accountId`** through the `linkedin.ts` tool methods that call these (they already have `params.channelId`). Update `workers/api/src/twist/tools/unipile/linkedin.ts` calls to pass `accountId: params.channelId`.

- [ ] **Step 5: Run.**

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add workers/api/src/twist/tools/unipile/
git commit -m "feat(unipile-v2): LinkedIn invitations + relations on v2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Webhook receiver — v2 event remap (`hook-messaging.ts`)

The handler already passes IDs only to connector callbacks, so v2's lighter payloads need no new fetch. The change is: classify v2 dot-notation event names off `event.type`, and read v2 payload field locations. Keep the custom-header auth model if v2 supports custom delivery headers (Task 2 LIVE-CONFIRM); otherwise switch to signature verification.

**Files:**
- Modify: `workers/api/src/app/hook-messaging.ts`
- Test: create `workers/api/src/app/hook-messaging.test.ts`

**Interfaces:**
- Consumes: nothing new from the client.
- Produces: `classifyEvent` mapping v2 names → the same internal dispatch kinds.

- [ ] **Step 1: Write a failing test** `hook-messaging.test.ts` for `classifyEvent` (export it from the module for testability — add `export` to `function classifyEvent`):

```ts
import { describe, it, expect } from "vitest";
import { classifyEvent } from "./hook-messaging";

describe("classifyEvent v2", () => {
  it("maps message.new", () => { expect(classifyEvent({ type: "message.new" } as any)).toBe("messaging.new_message"); });
  it("maps account.add and account.reconnect to connected", () => {
    expect(classifyEvent({ type: "account.add" } as any)).toBe("account.connected");
    expect(classifyEvent({ type: "account.reconnect" } as any)).toBe("account.connected");
  });
  it("maps account.status.disconnected/errored to needs_reauth", () => {
    expect(classifyEvent({ type: "account.status.disconnected" } as any)).toBe("account.needs_reauth");
    expect(classifyEvent({ type: "account.status.errored" } as any)).toBe("account.needs_reauth");
  });
});
```

- [ ] **Step 2: Run to verify failure.**

Run: `cd workers/api && pnpm vitest run src/app/hook-messaging.test.ts`
Expected: FAIL (classifyEvent not exported / v2 names unmapped).

- [ ] **Step 3: Implement the v2 remap.** Export `classifyEvent` and add v2 names (keep v1 names + the hosted-auth `status` shape during transition for safety):

```ts
export function classifyEvent(event: HostedWebhookEvent): /* same union */ {
  const t = (event.type as string | undefined) ?? event.event_type;
  // v2 dot-notation
  if (t === "message.new") return "messaging.new_message";
  if (t === "account.add" || t === "account.reconnect") return "account.connected";
  if (t === "account.status.disconnected" || t === "account.status.errored" || t === "account.status.credentials") return "account.needs_reauth";
  if (t === "users.invitation.received" || t === "relation.invitation") return "users.invitation.received";
  if (t === "users.new_relation" || t === "relation.new") return "users.new_relation";
  // v1 fallbacks (kept until cutover completes)
  if (t === "account.connected") return "account.connected";
  if (t === "account.disconnected" || t === "account.error" || t === "account.credentials") return "account.needs_reauth";
  if (t === "messaging.new_message") return "messaging.new_message";
  // hosted-auth notify shape
  if (event.status === "CREATION_SUCCESS" || event.status === "RECONNECTED") return "account.connected";
  if (event.status === "CREATION_ERROR" || event.status === "CHECKPOINT" || event.status === "CREDENTIALS") return "account.needs_reauth";
  return null;
}
```
Add `type?: string;` to the `HostedWebhookEvent` type. Update the field reads in `handleNewMessage`/`handleInvitationReceived`/`handleNewRelation`: v2 nests under `payload` with the same id keys (`chat_id`, `message_id`, `invitation_id`) and the account id may be on the core event as `account_id` — keep the existing `event.account_id ?? event.AccountId` reads.

> **LIVE-CONFIRM (Task 9):** exact v2 event names (`message.new` vs `message_received`), the payload field path for `chat_id`/`message_id`, and where `account_id` sits in the v2 core event. Adjust the string literals to match real deliveries observed over the tunnel.

- [ ] **Step 4: Webhook auth.** If Task 2 confirmed custom delivery headers are supported, leave the `x-plot-webhook-token` check as-is. If NOT, replace it with v2 signature verification (HMAC of the raw body against `UNIPILE_WEBHOOK_SECRET` using the documented header) and add a test for the verifier. **LIVE-CONFIRM (Task 9).**

- [ ] **Step 5: Run.**

Run: `cd workers/api && pnpm vitest run src/app/hook-messaging.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add workers/api/src/app/hook-messaging.ts workers/api/src/app/hook-messaging.test.ts
git commit -m "feat(unipile-v2): webhook receiver maps v2 dot-notation events

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Bootstrap script — one unified webhook endpoint

**Files:**
- Modify: `scripts/bootstrap-unipile-webhooks.ts`

**Interfaces:**
- Consumes: `createWebhook({ requestUrl, events, headers })`, `listWebhooks()`, `deleteWebhook(id)` (Task 2 signatures).

- [ ] **Step 1: Rewrite the registration loop** to create ONE endpoint subscribing to all needed events, replacing the `SOURCES` loop:

```ts
const EVENTS = [
  "message.new",
  "account.add",
  "account.reconnect",
  "account.status.disconnected",
  "account.status.errored",
  "users.invitation.received",
  "users.new_relation",
]; // LIVE-CONFIRM exact names (Task 9)

const existing = (await client.listWebhooks()).items;
const match = existing.find((w) => w.request_url === requestUrl);
const desiredHeader = { key: HEADER_NAME, value: env.UNIPILE_WEBHOOK_SECRET! };
const headerMatches = match?.headers?.some((h) => h.key === HEADER_NAME && h.value === desiredHeader.value);
if (match && headerMatches) {
  log(`  already registered (${match.id}) — no change`);
} else {
  if (match) { log(`  recreating ${match.id}`); await client.deleteWebhook(match.id); }
  const created = await client.createWebhook({ requestUrl, events: EVENTS, headers: [desiredHeader] });
  log(`  created (${created.id})`);
}
```
Remove the `SOURCES`/`UnipileWebhookSource` import. If custom headers are unsupported in v2 (Task 7 fallback), drop the `headers` field and rely on signature verification.

- [ ] **Step 2: Type-check the script.**

Run: `cd /Users/kris.braun/code/plot/.claude/worktrees/unipile-v2-migration && pnpm exec tsc --noEmit -p workers/api/tsconfig.json` (or the repo's lint for scripts)
Expected: no type errors in the script.

- [ ] **Step 3: Commit.**

```bash
git add scripts/bootstrap-unipile-webhooks.ts
git commit -m "feat(unipile-v2): bootstrap a single unified v2 webhook endpoint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Live verification against the real v2 API (tunnel)

**Prerequisite (USER):** v2 `UNIPILE_API_KEY` + tenant `UNIPILE_DSN` + `UNIPILE_WEBHOOK_SECRET` present in `workers/api/.dev.vars` (via 1Password + `pnpm get-env`). Without these, Steps below cannot run — pause and request them.

**Files:** none (verification + encoding any path corrections discovered, which become follow-up edits in the relevant task's file).

- [ ] **Step 1: Lint + full unipile suite green** before live testing.

Run: `cd workers/api && pnpm lint && pnpm vitest run src/twist/tools/unipile src/app/hook-messaging.test.ts`
Expected: clean lint, all tests PASS.

- [ ] **Step 2: Start the local worker + tunnel.**

Run (two shells): `pnpm --filter @plotday/api dev` and `pnpm tunnel:start` (then `pnpm tunnel:status` → confirm `https://api-kris.plot.day`).

- [ ] **Step 3: Register the v2 webhook endpoint at the tunnel URL.**

Run: `API_ROOT=https://api-kris.plot.day tsx scripts/bootstrap-unipile-webhooks.ts development` (or ensure `.dev.vars.development` `API_ROOT` is the tunnel URL).
Expected: "created (we_…)".

- [ ] **Step 4: Verification passes** (against a real LinkedIn/Instagram/WhatsApp test account). For each, confirm behavior and reconcile any path/shape mismatch by editing the owning task's file + test, then re-running that file's tests:
  - Hosted auth connect → `account.add` webhook arrives; `authBridge` resolves profile name.
  - Inbound message from another device → `message.new` webhook over the tunnel → Plot note created (connector fetch-by-ID through the v2 client).
  - Outbound: send message, add + clear reaction, mark chat read.
  - Backfill: list chats + messages paginate (offset/limit).
  - Disconnect the account → needs-reauth surfaces in the app.

- [ ] **Step 5: Resolve every LIVE-CONFIRM marker.** Grep the worktree for `LIVE-CONFIRM` and replace each assumed path/shape with the confirmed one, updating the corresponding test. Run the full suite green after each fix.

Run: `cd workers/api && pnpm vitest run src/twist/tools/unipile src/app/hook-messaging.test.ts`
Expected: PASS.

- [ ] **Step 6: Stop the tunnel** (`pnpm tunnel:stop`) and commit any LIVE-CONFIRM corrections.

```bash
git add -A
git commit -m "fix(unipile-v2): reconcile endpoints/shapes with live v2 API

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Finalize

**Files:**
- Modify: `docs/updates.md` (only if users would notice — likely a one-line "Reconnect your LinkedIn/Instagram/WhatsApp" note is NOT needed since reconnect is operational; skip unless the cutover ships user-visibly).
- Verify: repo-wide lint.

- [ ] **Step 1: Run `/finalize` checklist** — lint changed packages, confirm no removed/renamed fields break old clients (connectors unaffected; verified by tests), confirm new catch blocks capture exceptions.

Run: `cd workers/api && pnpm lint`
Expected: clean.

- [ ] **Step 2: Update the production cutover runbook** in the design spec is already present; confirm it still matches the implemented bootstrap/auth changes. No code.

- [ ] **Step 3: Final commit / open PR** per the finishing-a-development-branch skill (user decides merge vs PR).

---

## Self-review notes

- **Spec coverage:** base/host (Task 1), accounts+webhooks (Task 2), hosted auth+profile (Task 3), chats (Task 4), messages/attachments/reactions (Task 5), LinkedIn invitations/relations (Task 6), webhook event remap (Task 7), unified bootstrap (Task 8), live verification (Task 9), finalize (Task 10). All spec sections map to a task.
- **Pagination:** spec `cursor`→offset/limit covered in Tasks 2/4/5/6.
- **Require-reconnect:** no data migration task (correct); needs-reauth path already exists in `messaging.ts`/`hook-messaging.ts` and is exercised in Task 9 Step 4.
- **Type consistency:** message methods all gain `accountId`; `messaging.ts` threads `params.channelId` as `accountId` consistently (Tasks 4–6). `getAbs`/`postAbs` introduced in Task 2 and reused in 3–6.
- **LIVE-CONFIRM markers** are explicit research-then-encode steps tied to Task 9, not vague placeholders — each names the exact uncertainty and where to fix it.
