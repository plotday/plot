# LinkedIn (Unipile-backed) Connector — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing Voyager-scraping LinkedIn connector with a Unipile-backed one. Ship reusable Unipile infrastructure (HTTP client, hosted-auth flow, webhook handler) so WhatsApp and Instagram become copy-the-connector exercises later.

**Architecture:** A private workspace package (`libs/unipile/`) exposes provider-flavoured abstract tool classes (`LinkedInMessaging`, …) that the connector imports. Concrete impls live in `workers/api/src/twist/tools/unipile/` and wrap a single internal `UnipileClient`. Hosted auth piggy-backs on the existing OAuth shape — same Flutter button, same auth-url endpoint, same setup modal — branching server-side on a new `authMode: "hosted"` provider-config field. Connector is single-channel with two boolean Options (importMessages, importInvitations) instead of channels.

**Tech Stack:** TypeScript (Cloudflare Workers, Hono, Kysely, Vitest); pnpm workspaces; Atlas migrations; Flutter/Dart for the client. Twister SDK from `public/twister` (workspace link).

---

## Working directory

All paths below are relative to the worktree root:
`/Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/`

The `public/` submodule is a separate git repo with its own branch. We'll touch it in Phase 7 only; the rest of the work lives in this repo's branch.

## Spec

See `docs/superpowers/specs/2026-05-22-linkedin-unipile-design.md` for the design.

## Phase ordering rationale

We build inside-out so each phase compiles before the next starts:

1. `libs/unipile/` (types only — nothing depends on it yet).
2. Server-side `UnipileClient` + concrete impls (depend on `libs/unipile/` types).
3. Hosted-auth flow + `/hook/messaging` (depends on UnipileClient).
4. Private connector at `connectors/linkedin/` (depends on libs/unipile/).
5. Flutter cleanup (depends on server-side `/linkedin/cookie` being removed → moved to Phase 7).
6. DB migration.
7. Cleanup — public submodule PR + delete dead server/client code. This happens last because the server-side `/linkedin/cookie` endpoint and the Flutter modal can co-exist with the new flow until the new flow is verified working.

---

## Phase 1: `libs/unipile/` package skeleton

### Task 1.1: Create the workspace package

**Files:**
- Create: `libs/unipile/package.json`
- Create: `libs/unipile/tsconfig.json`
- Create: `libs/unipile/src/index.ts`
- Modify: `pnpm-workspace.yaml` (add `connectors/*`)

- [ ] **Step 1: Write `libs/unipile/package.json`**

```json
{
  "name": "@plotday/unipile",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "lint": "tsc --noEmit"
  },
  "dependencies": {
    "@plotday/twister": "workspace:*"
  },
  "devDependencies": {
    "@plotday/tsconfig": "workspace:*",
    "typescript": "^5.9.3"
  }
}
```

- [ ] **Step 2: Write `libs/unipile/tsconfig.json`**

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/tsconfig/base.json",
  "compilerOptions": {
    "rootDir": "./src",
    "outDir": "./dist",
    "noEmit": true
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 3: Write a stub `libs/unipile/src/index.ts`**

```ts
// Barrel exports — populated in subsequent tasks.
export {};
```

- [ ] **Step 4: Add `connectors/*` to `pnpm-workspace.yaml`**

Add the `connectors/*` line so it appears alongside the existing entries:

```yaml
packages:
  - apps/*
  - workers/*
  - libs/*
  - twists/*
  - connectors/*
  - public/twister
  - public/connectors/*
  - public/twists/*
```

- [ ] **Step 5: Run `pnpm install` from the worktree root**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm install
```

Expected: `+1 package` (or similar) reported for `@plotday/unipile`, no errors.

- [ ] **Step 6: Verify the lib lints**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/libs/unipile && pnpm lint
```

Expected: exits 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git add libs/unipile pnpm-workspace.yaml pnpm-lock.yaml
git commit -m "Add empty @plotday/unipile workspace package"
```

### Task 1.2: Define shared types

**Files:**
- Create: `libs/unipile/src/types.ts`
- Modify: `libs/unipile/src/index.ts`

- [ ] **Step 1: Write `libs/unipile/src/types.ts`**

```ts
/**
 * Shared types used across all provider tools in this package.
 *
 * These shapes are intentionally Plot-flavoured, not Unipile-flavoured.
 * If we swap providers later, the impls in workers/api change but these
 * types do not.
 */

export type LinkedInProfile = {
  /** Provider-side member id (Unipile's `provider_id` / LinkedIn member URN). */
  id: string;
  /** LinkedIn public identifier slug (`linkedin.com/in/<slug>`). May be null
   * when the member's profile is restricted. */
  publicIdentifier: string | null;
  fullName: string;
  headline: string | null;
  email: string | null;
  pictureUrl: string | null;
  /** `https://www.linkedin.com/in/<slug>/` when publicIdentifier is set,
   * otherwise null. */
  url: string | null;
};

export type LinkedInAttachment = {
  id: string;
  kind: "image" | "video" | "audio" | "file" | "other";
  name: string | null;
  url: string;
  contentType: string | null;
  byteSize: number | null;
};

export type LinkedInMessage = {
  /** Unipile message id (opaque). */
  id: string;
  /** Unipile chat id this message belongs to. */
  chatId: string;
  /** Provider id of the sender. */
  senderId: string;
  /** True iff the sender is the connected account. */
  sentByMe: boolean;
  sentAt: Date;
  /** Plain-text body (Unipile returns the canonical text form). */
  text: string;
  attachments: LinkedInAttachment[];
};

export type LinkedInChat = {
  id: string;
  title: string | null;
  isGroup: boolean;
  participants: LinkedInProfile[];
  lastMessagePreview: string | null;
  lastActivityAt: Date;
  unreadCount: number;
  archived: boolean;
  /** `https://www.linkedin.com/messaging/thread/<id>/`. */
  url: string;
};

export type LinkedInChatPage = {
  chats: LinkedInChat[];
  /** Pass back as `before` to fetch the next page; null when no more pages. */
  nextCursor: string | null;
};

export type LinkedInMessagePage = {
  messages: LinkedInMessage[];
  nextCursor: string | null;
};

export type LinkedInInvitation = {
  /** Unipile invitation id. */
  id: string;
  /** Token required to accept/ignore the invitation. */
  sharedSecret: string;
  inviter: LinkedInProfile;
  message: string | null;
  sentAt: Date;
};

export type LinkedInInvitationPage = {
  invitations: LinkedInInvitation[];
  nextCursor: string | null;
};
```

- [ ] **Step 2: Re-export from `libs/unipile/src/index.ts`**

```ts
export * from "./types";
```

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/libs/unipile && pnpm lint
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add libs/unipile/src
git commit -m "Add shared LinkedIn types to @plotday/unipile"
```

### Task 1.3: Define the `LinkedInMessaging` abstract tool

**Files:**
- Create: `libs/unipile/src/linkedin.ts`
- Modify: `libs/unipile/src/index.ts`

- [ ] **Step 1: Write `libs/unipile/src/linkedin.ts`**

```ts
import { ITool } from "@plotday/twister";

import type {
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitation,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
} from "./types";

/**
 * Built-in tool for calling a connected LinkedIn account's messaging and
 * invitation APIs.
 *
 * Implementation lives in `workers/api/src/twist/tools/unipile/linkedin.ts`
 * and routes through Unipile's hosted API. The connector never sees that
 * detail — methods take provider-flavoured arguments (chatId, invitationId)
 * and return provider-flavoured shapes.
 */
export abstract class LinkedInMessaging extends ITool {
  static readonly toolId = "LinkedInMessaging";

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInChatPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getChat(params: {
    channelId: string;
    chatId: string;
  }): Promise<LinkedInChat>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
  }): Promise<LinkedInMessage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setChatRead(params: {
    channelId: string;
    chatId: string;
    read: boolean;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract acceptInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void>;
}
```

- [ ] **Step 2: Re-export from `libs/unipile/src/index.ts`**

```ts
export * from "./types";
export * from "./linkedin";
```

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/libs/unipile && pnpm lint
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add libs/unipile/src
git commit -m "Add LinkedInMessaging abstract tool to @plotday/unipile"
```

---

## Phase 2: Server-side Unipile client

### Task 2.1: Add Unipile env vars + bindings

**Files:**
- Modify: `workers/api/.dev.vars`
- Modify: `workers/api/src/env.ts`
- Modify: `workers/api/wrangler.jsonc` (only `vars` section; the rate limiter binding stays for now and is removed in Phase 7)

- [ ] **Step 1: Add stub env vars to `workers/api/.dev.vars`**

Append these lines (real values come from the user; placeholders for now so the worker boots):

```
UNIPILE_API_KEY=local-dev-placeholder
UNIPILE_DSN=api6
UNIPILE_WEBHOOK_SECRET=local-dev-placeholder
```

- [ ] **Step 2: Add the new keys to the `Bindings` type in `workers/api/src/env.ts`**

Locate the `Bindings` type / interface and add:

```ts
UNIPILE_API_KEY: string;
UNIPILE_DSN: string;
UNIPILE_WEBHOOK_SECRET: string;
```

If the file uses `worker-configuration.d.ts` instead, also append the same three keys there.

- [ ] **Step 3: Run the worker type-check**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

Expected: exits 0 (no other code reads these vars yet).

- [ ] **Step 4: Commit**

```bash
git add workers/api/.dev.vars workers/api/src/env.ts workers/api/worker-configuration.d.ts 2>/dev/null
git commit -m "Add Unipile env var bindings to api worker"
```

### Task 2.2: Internal Unipile API types

**Files:**
- Create: `workers/api/src/twist/tools/unipile/types.ts`

- [ ] **Step 1: Write `workers/api/src/twist/tools/unipile/types.ts`**

```ts
/**
 * Internal Unipile API response shapes. These never leak past
 * normalize.ts — every caller of the UnipileClient receives Plot-shaped
 * values from `libs/unipile/src/types.ts` instead.
 */

export type UnipileAccountSource =
  | "LINKEDIN"
  | "WHATSAPP"
  | "INSTAGRAM";

export type UnipileAccount = {
  object: "Account";
  id: string;
  type: UnipileAccountSource;
  created_at: string;
  connection_params?: {
    im?: {
      id?: string;
      username?: string;
    };
  };
  sources: {
    id: string;
    status: "OK" | "ERROR" | "STOPPED" | "CREDENTIALS";
  }[];
  name?: string;
};

export type UnipileChat = {
  object: "Chat";
  id: string;
  account_id: string;
  account_type: UnipileAccountSource;
  provider_id: string;
  name: string | null;
  type: 0 | 1; // 0 = 1:1, 1 = group
  timestamp: string;
  unread_count: number;
  archived: 0 | 1;
  read_only: 0 | 1;
  muted_until: string | null;
  attendee_provider_id: string | null;
};

export type UnipileChatList = {
  object: "ChatList";
  items: UnipileChat[];
  cursor: string | null;
};

export type UnipileMessage = {
  object: "Message";
  id: string;
  chat_id: string;
  chat_provider_id: string;
  provider_id: string;
  sender_id: string;
  sender_attendee_id: string;
  timestamp: string;
  is_sender: 0 | 1;
  is_event: 0 | 1;
  seen: 0 | 1;
  text: string | null;
  attachments?: UnipileAttachment[];
};

export type UnipileAttachment = {
  id: string;
  type:
    | "img"
    | "video"
    | "audio"
    | "file"
    | "link"
    | "sticker"
    | string;
  url?: string;
  name?: string;
  mimetype?: string;
  file_size?: number;
};

export type UnipileMessageList = {
  object: "MessageList";
  items: UnipileMessage[];
  cursor: string | null;
};

export type UnipileAttendee = {
  object: "Attendee";
  provider_id: string;
  name: string | null;
  profile_url: string | null;
  picture_url: string | null;
  is_self: 0 | 1;
  specifics?: {
    public_identifier?: string;
    headline?: string;
    email?: string;
  };
};

export type UnipileAttendeeList = {
  object: "AttendeeList";
  items: UnipileAttendee[];
  cursor: string | null;
};

export type UnipileInvitation = {
  object: "Invitation";
  id: string;
  inviter: UnipileAttendee;
  message: string | null;
  shared_secret: string;
  created_at: string;
};

export type UnipileInvitationList = {
  object: "InvitationList";
  items: UnipileInvitation[];
  cursor: string | null;
};

export type UnipileHostedAuthLink = {
  object: "HostedAuthURL";
  url: string;
};
```

- [ ] **Step 2: Lint the api worker**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/tools/unipile
git commit -m "Add internal Unipile API response types"
```

### Task 2.3: UnipileClient HTTP layer

**Files:**
- Create: `workers/api/src/twist/tools/unipile/client.ts`
- Create: `workers/api/src/twist/tools/unipile/__tests__/client.test.ts`

- [ ] **Step 1: Write the failing test for URL construction**

`workers/api/src/twist/tools/unipile/__tests__/client.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { UnipileClient, UnipileApiError } from "../client";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_DSN: "api7",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
};

describe("UnipileClient", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    fetchSpy.mockRestore();
  });

  it("sends the API key header and uses the configured DSN", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ object: "ChatList", items: [], cursor: null }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    );

    const client = new UnipileClient(env);
    await client.listChats({ accountId: "acct-1" });

    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api7.unipile.com:13441/api/v1/chats?account_id=acct-1"
    );
    expect((init?.headers as Record<string, string>)["X-API-KEY"]).toBe(
      "test-key"
    );
    expect((init?.headers as Record<string, string>).accept).toBe(
      "application/json"
    );
  });

  it("throws UnipileApiError with status on non-2xx", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response('{"status":401,"title":"Unauthorized"}', {
        status: 401,
        headers: { "content-type": "application/json" },
      })
    );
    const client = new UnipileClient(env);
    await expect(
      client.listChats({ accountId: "acct-1" })
    ).rejects.toMatchObject({ name: "UnipileApiError", status: 401 });
  });
});
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && \
  pnpm test -- src/twist/tools/unipile/__tests__/client.test.ts
```

Expected: FAIL — `UnipileClient` not exported.

- [ ] **Step 3: Implement `workers/api/src/twist/tools/unipile/client.ts`**

```ts
import type {
  UnipileAccount,
  UnipileAttendee,
  UnipileAttendeeList,
  UnipileChat,
  UnipileChatList,
  UnipileHostedAuthLink,
  UnipileInvitationList,
  UnipileMessage,
  UnipileMessageList,
} from "./types";

/** Thrown on non-2xx Unipile responses. */
export class UnipileApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public bodyText: string
  ) {
    super(message);
    this.name = "UnipileApiError";
  }
}

type Env = {
  UNIPILE_API_KEY: string;
  UNIPILE_DSN: string;
  UNIPILE_WEBHOOK_SECRET: string;
};

/**
 * Thin HTTP client for Unipile's REST API. This is the only file in the
 * codebase that knows Unipile's URL shape, header set, or API key — every
 * other caller works against Plot-shaped wrappers.
 *
 * The DSN selects the region (`api6`, `api7`, …); Unipile assigns one per
 * workspace.
 */
export class UnipileClient {
  private readonly base: string;

  constructor(private readonly env: Env) {
    this.base = `https://${env.UNIPILE_DSN}.unipile.com:13441/api/v1`;
  }

  // ---------- Account lifecycle ----------

  async createHostedAuthLink(input: {
    providers: ("LINKEDIN" | "WHATSAPP" | "INSTAGRAM")[];
    name: string;
    successRedirectUrl: string;
    failureRedirectUrl: string;
    notifyUrl: string;
    expiresAt: Date;
  }): Promise<UnipileHostedAuthLink> {
    return this.post<UnipileHostedAuthLink>("/hosted/accounts/link", {
      type: "create",
      providers: input.providers,
      api_url: this.base,
      expiresOn: input.expiresAt.toISOString(),
      name: input.name,
      success_redirect_url: input.successRedirectUrl,
      failure_redirect_url: input.failureRedirectUrl,
      notify_url: input.notifyUrl,
    });
  }

  getAccount(accountId: string): Promise<UnipileAccount> {
    return this.get<UnipileAccount>(`/accounts/${encodeURIComponent(accountId)}`);
  }

  async deleteAccount(accountId: string): Promise<void> {
    await this.request(`/accounts/${encodeURIComponent(accountId)}`, {
      method: "DELETE",
    });
  }

  // ---------- Chats / messages ----------

  listChats(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileChatList> {
    return this.get<UnipileChatList>("/chats", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }

  getChat(input: { chatId: string }): Promise<UnipileChat> {
    return this.get<UnipileChat>(`/chats/${encodeURIComponent(input.chatId)}`);
  }

  listChatAttendees(input: {
    chatId: string;
  }): Promise<UnipileAttendeeList> {
    return this.get<UnipileAttendeeList>(
      `/chats/${encodeURIComponent(input.chatId)}/attendees`
    );
  }

  listMessages(input: {
    chatId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileMessageList> {
    return this.get<UnipileMessageList>(
      `/chats/${encodeURIComponent(input.chatId)}/messages`,
      {
        ...(input.cursor ? { cursor: input.cursor } : {}),
        ...(input.limit ? { limit: String(input.limit) } : {}),
      }
    );
  }

  sendMessage(input: {
    chatId: string;
    text: string;
  }): Promise<UnipileMessage> {
    return this.post<UnipileMessage>(
      `/chats/${encodeURIComponent(input.chatId)}/messages`,
      { text: input.text }
    );
  }

  async setChatRead(input: { chatId: string; read: boolean }): Promise<void> {
    await this.request(
      `/chats/${encodeURIComponent(input.chatId)}`,
      {
        method: "PATCH",
        body: JSON.stringify({ action: input.read ? "setReadStatus" : "setUnreadStatus", value: input.read }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  // ---------- LinkedIn invitations ----------

  listReceivedInvitations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileInvitationList> {
    return this.get<UnipileInvitationList>("/users/invite/received", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }

  async acceptInvitation(input: {
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.request(
      `/users/invite/received/${encodeURIComponent(input.invitationId)}`,
      {
        method: "POST",
        body: JSON.stringify({
          action: "accept",
          shared_secret: input.sharedSecret,
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  async ignoreInvitation(input: {
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.request(
      `/users/invite/received/${encodeURIComponent(input.invitationId)}`,
      {
        method: "POST",
        body: JSON.stringify({
          action: "ignore",
          shared_secret: input.sharedSecret,
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  getAttendee(input: { providerId: string }): Promise<UnipileAttendee> {
    return this.get<UnipileAttendee>(
      `/users/${encodeURIComponent(input.providerId)}`
    );
  }

  // ---------- Internals ----------

  private get<T>(
    path: string,
    query?: Record<string, string>
  ): Promise<T> {
    const qs =
      query && Object.keys(query).length > 0
        ? "?" + new URLSearchParams(query).toString()
        : "";
    return this.request<T>(`${path}${qs}`, { method: "GET" });
  }

  private post<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>(path, {
      method: "POST",
      body: JSON.stringify(body),
      headers: { "content-type": "application/json" },
    });
  }

  private async request<T>(
    path: string,
    init: RequestInit
  ): Promise<T> {
    const url = `${this.base}${path}`;
    const headers = {
      "X-API-KEY": this.env.UNIPILE_API_KEY,
      accept: "application/json",
      ...((init.headers as Record<string, string>) ?? {}),
    };
    const response = await fetch(url, { ...init, headers });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new UnipileApiError(
        `Unipile ${init.method} ${path} returned ${response.status}`,
        response.status,
        text
      );
    }
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && \
  pnpm test -- src/twist/tools/unipile/__tests__/client.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile
git commit -m "Add UnipileClient HTTP layer with API key + DSN config"
```

### Task 2.4: Unipile → Plot normalization (pure, TDD)

**Files:**
- Create: `workers/api/src/twist/tools/unipile/normalize.ts`
- Create: `workers/api/src/twist/tools/unipile/__tests__/normalize.test.ts`

- [ ] **Step 1: Write failing tests**

`workers/api/src/twist/tools/unipile/__tests__/normalize.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  normalizeChat,
  normalizeMessage,
  normalizeInvitation,
  normalizeProfile,
} from "../normalize";

describe("normalize", () => {
  it("normalizes a 1:1 chat with one attendee into a LinkedInChat", () => {
    const chat = normalizeChat(
      {
        object: "Chat",
        id: "c1",
        account_id: "acct-1",
        account_type: "LINKEDIN",
        provider_id: "linkedin-thread-xyz",
        name: null,
        type: 0,
        timestamp: "2026-05-22T10:00:00.000Z",
        unread_count: 2,
        archived: 0,
        read_only: 0,
        muted_until: null,
        attendee_provider_id: "ACoAA12345",
      },
      [
        {
          object: "Attendee",
          provider_id: "ACoAA12345",
          name: "Jane Doe",
          profile_url: "https://www.linkedin.com/in/jdoe/",
          picture_url: "https://media.licdn.com/jdoe.jpg",
          is_self: 0,
          specifics: { public_identifier: "jdoe", headline: "PM" },
        },
      ]
    );
    expect(chat.id).toBe("c1");
    expect(chat.isGroup).toBe(false);
    expect(chat.participants).toHaveLength(1);
    expect(chat.participants[0]!.fullName).toBe("Jane Doe");
    expect(chat.participants[0]!.publicIdentifier).toBe("jdoe");
    expect(chat.unreadCount).toBe(2);
    expect(chat.url).toBe(
      "https://www.linkedin.com/messaging/thread/linkedin-thread-xyz/"
    );
  });

  it("normalizes a message and flags sent-by-me when is_sender=1", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m1",
      chat_id: "c1",
      chat_provider_id: "linkedin-thread-xyz",
      provider_id: "lnk-msg-1",
      sender_id: "ACoAA12345",
      sender_attendee_id: "att-1",
      timestamp: "2026-05-22T10:05:00.000Z",
      is_sender: 1,
      is_event: 0,
      seen: 1,
      text: "Hello",
      attachments: [],
    });
    expect(msg.sentByMe).toBe(true);
    expect(msg.text).toBe("Hello");
    expect(msg.sentAt.toISOString()).toBe("2026-05-22T10:05:00.000Z");
    expect(msg.attachments).toEqual([]);
  });

  it("normalizes an invitation with inviter profile", () => {
    const inv = normalizeInvitation({
      object: "Invitation",
      id: "inv-1",
      created_at: "2026-05-22T09:00:00.000Z",
      message: "Let's connect",
      shared_secret: "ss-token",
      inviter: {
        object: "Attendee",
        provider_id: "ACoAA999",
        name: "Carla Ng",
        profile_url: "https://www.linkedin.com/in/carlang/",
        picture_url: null,
        is_self: 0,
        specifics: { public_identifier: "carlang" },
      },
    });
    expect(inv.id).toBe("inv-1");
    expect(inv.sharedSecret).toBe("ss-token");
    expect(inv.message).toBe("Let's connect");
    expect(inv.inviter.fullName).toBe("Carla Ng");
    expect(inv.inviter.publicIdentifier).toBe("carlang");
  });

  it("falls back to publicIdentifier when name missing", () => {
    const profile = normalizeProfile({
      object: "Attendee",
      provider_id: "ACoAA000",
      name: null,
      profile_url: null,
      picture_url: null,
      is_self: 0,
      specifics: { public_identifier: "ghost" },
    });
    expect(profile.fullName).toBe("ghost");
  });
});
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && \
  pnpm test -- src/twist/tools/unipile/__tests__/normalize.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `workers/api/src/twist/tools/unipile/normalize.ts`**

```ts
import type {
  LinkedInAttachment,
  LinkedInChat,
  LinkedInInvitation,
  LinkedInMessage,
  LinkedInProfile,
} from "@plotday/unipile";

import type {
  UnipileAttachment,
  UnipileAttendee,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
} from "./types";

export function normalizeProfile(att: UnipileAttendee): LinkedInProfile {
  const publicIdentifier = att.specifics?.public_identifier ?? null;
  const fullName =
    (att.name && att.name.trim()) ||
    publicIdentifier ||
    "Unknown";
  return {
    id: att.provider_id,
    publicIdentifier,
    fullName,
    headline: att.specifics?.headline ?? null,
    email: att.specifics?.email ?? null,
    pictureUrl: att.picture_url ?? null,
    url:
      att.profile_url ??
      (publicIdentifier
        ? `https://www.linkedin.com/in/${publicIdentifier}`
        : null),
  };
}

export function normalizeChat(
  chat: UnipileChat,
  attendees: UnipileAttendee[]
): LinkedInChat {
  const profiles = attendees
    .filter((a) => a.is_self === 0)
    .map(normalizeProfile);
  return {
    id: chat.id,
    title: chat.name,
    isGroup: chat.type === 1,
    participants: profiles,
    lastMessagePreview: null,
    lastActivityAt: new Date(chat.timestamp),
    unreadCount: chat.unread_count,
    archived: chat.archived === 1,
    url: `https://www.linkedin.com/messaging/thread/${chat.provider_id}/`,
  };
}

export function normalizeMessage(msg: UnipileMessage): LinkedInMessage {
  return {
    id: msg.id,
    chatId: msg.chat_id,
    senderId: msg.sender_id,
    sentByMe: msg.is_sender === 1,
    sentAt: new Date(msg.timestamp),
    text: msg.text ?? "",
    attachments: (msg.attachments ?? []).map(normalizeAttachment),
  };
}

function normalizeAttachment(a: UnipileAttachment): LinkedInAttachment {
  let kind: LinkedInAttachment["kind"] = "other";
  if (a.type === "img") kind = "image";
  else if (a.type === "video") kind = "video";
  else if (a.type === "audio") kind = "audio";
  else if (a.type === "file") kind = "file";
  return {
    id: a.id,
    kind,
    name: a.name ?? null,
    url: a.url ?? "",
    contentType: a.mimetype ?? null,
    byteSize: a.file_size ?? null,
  };
}

export function normalizeInvitation(
  inv: UnipileInvitation
): LinkedInInvitation {
  return {
    id: inv.id,
    sharedSecret: inv.shared_secret,
    inviter: normalizeProfile(inv.inviter),
    message: inv.message,
    sentAt: new Date(inv.created_at),
  };
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && \
  pnpm test -- src/twist/tools/unipile/__tests__/normalize.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile
git commit -m "Add Unipile -> Plot normalization with unit tests"
```

### Task 2.5: Concrete `LinkedInMessaging` tool impl

**Files:**
- Create: `workers/api/src/twist/tools/unipile/linkedin.ts`

- [ ] **Step 1: Implement `workers/api/src/twist/tools/unipile/linkedin.ts`**

```ts
import type { Kysely } from "kysely";

import { LinkedInMessaging as ILinkedInMessaging } from "@plotday/unipile";
import type {
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
} from "@plotday/unipile";

import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import type { StoredTokenData } from "../../../provider";
import { Store } from "../store";
import { Tool } from "../tool";
import { UnipileClient } from "./client";
import {
  normalizeChat,
  normalizeInvitation,
  normalizeMessage,
  normalizeProfile,
} from "./normalize";

/**
 * Concrete impl of the LinkedInMessaging built-in tool. Routes all calls
 * through Unipile via UnipileClient. The connector never sees Unipile
 * identifiers — it works with Plot-shaped {chatId, messageId, …} values
 * that happen to be Unipile ids.
 */
export class LinkedInMessaging extends Tool implements ILinkedInMessaging {
  private store: Store;
  private client: UnipileClient;

  constructor(
    private options: {
      env: Bindings;
      db: Kysely<DB>;
      twistInstanceId: string;
      path: string[];
    }
  ) {
    super();
    this.store = new Store({
      path: options.path,
      storage: options.env.STORAGE,
      twistInstanceId: options.twistInstanceId,
    });
    this.client = new UnipileClient(options.env);
  }

  async listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInChatPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listChats({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    const chats: LinkedInChat[] = [];
    for (const raw of result.items) {
      const attendees = await this.client.listChatAttendees({ chatId: raw.id });
      const chat = normalizeChat(raw, attendees.items);
      if (params.since && chat.lastActivityAt < params.since) continue;
      chats.push(chat);
    }
    return { chats, nextCursor: result.cursor };
  }

  async getChat(params: {
    channelId: string;
    chatId: string;
  }): Promise<LinkedInChat> {
    await this.assertAccount(params.channelId);
    const [raw, attendees] = await Promise.all([
      this.client.getChat({ chatId: params.chatId }),
      this.client.listChatAttendees({ chatId: params.chatId }),
    ]);
    return normalizeChat(raw, attendees.items);
  }

  async listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listMessages({
      chatId: params.chatId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    const messages = result.items
      .map(normalizeMessage)
      .filter((m) => !params.since || m.sentAt >= params.since);
    return { messages, nextCursor: result.cursor };
  }

  async sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
  }): Promise<LinkedInMessage> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.sendMessage({
      chatId: params.chatId,
      text: params.text,
    });
    return normalizeMessage(raw);
  }

  async setChatRead(params: {
    channelId: string;
    chatId: string;
    read: boolean;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.setChatRead({ chatId: params.chatId, read: params.read });
  }

  async listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listReceivedInvitations({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    return {
      invitations: result.items.map(normalizeInvitation),
      nextCursor: result.cursor,
    };
  }

  async acceptInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.acceptInvitation({
      invitationId: params.invitationId,
      sharedSecret: params.sharedSecret,
    });
  }

  async ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.ignoreInvitation({
      invitationId: params.invitationId,
      sharedSecret: params.sharedSecret,
    });
  }

  /**
   * Look up the stored token for the channel's account so call sites have
   * a single rejection point when the connection is missing or revoked.
   * The channelId IS the Unipile account_id (see Connector.getChannels).
   */
  private async assertAccount(channelId: string): Promise<void> {
    // We don't strictly need the token to call Unipile (the API key is
    // workspace-scoped), but we DO need to confirm the channel still has a
    // live token row — otherwise the connector is calling us after disconnect.
    const channelConfigKey = `channel_config:linkedin:${channelId}`;
    const channelConfig = await this.store.get<{
      enabled?: boolean;
      enabledBy?: string;
    }>(channelConfigKey);
    if (!channelConfig?.enabledBy) {
      throw new Error(
        `LinkedIn channel ${channelId} is not enabled by any actor`
      );
    }
    const token = await this.store.get<StoredTokenData>(
      `auth_token:linkedin:${channelConfig.enabledBy}`
    );
    if (!token?.access_token) {
      throw new Error(
        `LinkedIn channel ${channelId} has no stored credentials — reconnect`
      );
    }
  }
}

// Re-export the normalizeProfile so the webhook handler can use it.
export { normalizeProfile };
```

- [ ] **Step 2: Register the tool in `workers/api/src/twist/tools/factory.ts`**

Two switch statements: one in `getToolClass`, one in `createTool`. Add cases mirroring how `LinkedIn` is wired today.

`getToolClass`:

```ts
    case "LinkedInMessaging":
      return LinkedInMessaging;
```

`createTool` (mirror the existing `case "LinkedIn":` branch):

```ts
    case "LinkedInMessaging":
      return new LinkedInMessaging({ env, db, twistInstanceId, path });
```

And add the import at the top:

```ts
import { LinkedInMessaging } from "./unipile/linkedin";
```

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

Expected: exits 0.

- [ ] **Step 4: Run all existing tests to confirm nothing regressed**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile workers/api/src/twist/tools/factory.ts
git commit -m "Wire LinkedInMessaging concrete tool through factory"
```

---

## Phase 3: Hosted-auth flow + `/hook/messaging`

### Task 3.1: Add `HostedAccountProviderData` and `authMode` to provider config

**Files:**
- Modify: `workers/api/src/provider.ts`

- [ ] **Step 1: Add the new providerData shape**

In `workers/api/src/provider.ts`, add this type alongside the other `*ProviderData` types and to the `ProviderData` union:

```ts
export type HostedAccountProviderData = {
  /** Vendor-issued account id (Unipile account_id). Stored as the user's
   * access_token because every Unipile call needs it. */
  accountId: string;
  /** Vendor's source type, e.g. "LINKEDIN" — the impl uses this to route. */
  accountType: string;
  /** Provider-side user id (e.g. LinkedIn member URN). */
  userId: string;
  fullName: string | null;
  email: string | null;
};
```

Add it to the `ProviderData` union and update `extractUserId` so the `linkedin` branch reads from `HostedAccountProviderData`:

```ts
    case "linkedin":
      return (providerData as HostedAccountProviderData).userId ?? null;
```

Remove the existing `LinkedInProviderData` type and references to it (the cookie shape no longer applies).

- [ ] **Step 2: Add `authMode` to `ProviderConfig`**

Add a `authMode: "oauth" | "hosted"` field. Default oauth where omitted (annotate optional with a default in the consumer).

```ts
export type ProviderConfig = {
  name: string;
  authMode?: "oauth" | "hosted"; // default "oauth"
  // ... existing OAuth fields, ALL optional when authMode === "hosted"
};
```

- [ ] **Step 3: Update `PROVIDER_CONFIGS[linkedin]` to use hosted mode**

Replace the existing `linkedin` entry with:

```ts
  linkedin: {
    name: "LinkedIn",
    authMode: "hosted",
    // parseTokenResponse is unused for hosted-auth providers; the webhook
    // handler builds HostedAccountProviderData directly.
  },
```

- [ ] **Step 4: Lint the api worker — expect failures elsewhere**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

This may surface call-site type errors (e.g., the existing `linkedin-voyager.ts` import of `LinkedInProviderData`). Those files are being deleted in Phase 7. To unblock Phase 3, comment out the broken references with a `// REMOVED IN PHASE 7` marker — do NOT delete the files yet. The lint failures must be confined to files we will delete.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/provider.ts workers/api/src/twist/tools/linkedin.ts workers/api/src/twist/tools/linkedin-voyager.ts workers/api/src/app/twist-integrations.ts
git commit -m "Add HostedAccountProviderData and authMode to provider config"
```

### Task 3.2: Hosted-auth branch in `GenerateAuthUrl`

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (`GenerateAuthUrl`, `Bindings` access)

- [ ] **Step 1: Locate `GenerateAuthUrl` at line ~4296 and add a hosted-auth branch at the start**

Insert immediately after the `config` lookup:

```ts
if (config.authMode === "hosted") {
  return await Integrations.GenerateHostedAuthUrl({
    provider,
    callback,
    redirectUri,
    env,
    storage,
  });
}
```

- [ ] **Step 2: Add `GenerateHostedAuthUrl` as a new static method on the `Integrations` class (same file)**

```ts
static async GenerateHostedAuthUrl({
  provider,
  callback,
  redirectUri,
  env,
  storage,
}: {
  provider: AuthProvider;
  callback?: Callback;
  redirectUri: string;
  env: Bindings;
  storage: DurableObjectNamespace<Storage>;
}): Promise<{ url: string; clientId: string; state: string }> {
  const state = crypto.randomUUID();

  // Stash the in-flight auth so the webhook handler and the /auth completion
  // path can pair the inbound account_id with this state token.
  const storageObj = storage.get(storage.idFromName("auth"));
  await storageObj.set(`hosted_auth:${state}`, {
    provider,
    callback: callback ? String(callback) : null,
    redirectUri,
    createdAt: Date.now(),
  });

  // Map the API provider name to Unipile's source enum.
  const sourceMap: Record<string, "LINKEDIN" | "WHATSAPP" | "INSTAGRAM"> = {
    linkedin: "LINKEDIN",
    whatsapp: "WHATSAPP",
    instagram: "INSTAGRAM",
  };
  const source = sourceMap[provider];
  if (!source) {
    throw new Error(`Provider ${provider} not supported for hosted auth`);
  }

  const client = new (await import("../tools/unipile/client")).UnipileClient(env);
  const { url } = await client.createHostedAuthLink({
    providers: [source],
    name: state,
    successRedirectUrl: `${env.API_ROOT}/auth/hosted/success?state=${state}`,
    failureRedirectUrl: `${env.API_ROOT}/auth/hosted/failure?state=${state}`,
    notifyUrl: `${env.API_ROOT}/hook/messaging`,
    expiresAt: new Date(Date.now() + 30 * 60 * 1000),
  });

  return { url, clientId: "hosted", state };
}
```

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

Expected: exits 0 (the dynamic import keeps the file split clean).

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "Add GenerateHostedAuthUrl for hosted-auth providers"
```

### Task 3.3: `/hook/messaging` webhook endpoint

**Files:**
- Create: `workers/api/src/app/hook-messaging.ts`
- Modify: `workers/api/src/index.ts` (route registration)

- [ ] **Step 1: Look up how existing `/hook/*` endpoints register**

```bash
grep -n "/hook/" /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api/src/index.ts | head
```

Note the registration pattern; mirror it for `/hook/messaging`.

- [ ] **Step 2: Write `workers/api/src/app/hook-messaging.ts`**

```ts
import { Hono } from "hono";

import { createLogger } from "@plotday/worker-util";
import type { TwistEnvironment } from "../env";

const hookMessaging = new Hono<TwistEnvironment>();

/**
 * Receives Unipile webhook events. One URL per workspace; events
 * differentiated by `event_type` in the body.
 *
 * Vendor naming ("Unipile") stays internal to this file — callers see
 * generic "messaging" events.
 */
hookMessaging.post("/hook/messaging", async (c) => {
  const logger = createLogger({ route: "hook/messaging" });

  // 1. Verify signature.
  const signature = c.req.header("x-unipile-signature");
  const bodyText = await c.req.text();
  if (!signature || !(await verifySignature(bodyText, signature, c.env.UNIPILE_WEBHOOK_SECRET))) {
    logger.warn("Hosted-auth webhook signature mismatch");
    return c.json({ ok: false }, 401);
  }

  let event: HostedWebhookEvent;
  try {
    event = JSON.parse(bodyText) as HostedWebhookEvent;
  } catch {
    return c.json({ ok: false, error: "invalid json" }, 400);
  }

  // 2. Dispatch by event type. Each branch is best-effort and idempotent.
  try {
    switch (event.event_type) {
      case "account.connected":
        await handleAccountConnected(c.env, event, logger);
        break;
      case "account.disconnected":
      case "account.error":
      case "account.credentials":
        await handleAccountNeedsReauth(c.env, event, logger);
        break;
      case "messaging.new_message":
        await handleNewMessage(c.env, event, logger);
        break;
      case "users.invitation.received":
        await handleInvitationReceived(c.env, event, logger);
        break;
      default:
        logger.info("Unhandled hosted-auth event type", {
          event_type: event.event_type,
        });
    }
  } catch (error) {
    logger.error("Hosted-auth webhook handler threw", error as Error);
    // Re-throw so PostHog captureException reports it; respond 500 so Unipile
    // retries.
    throw error;
  }
  return c.json({ ok: true });
});

type HostedWebhookEvent = {
  event_type: string;
  account_id?: string;
  payload?: Record<string, unknown>;
  [k: string]: unknown;
};

async function verifySignature(
  body: string,
  signatureHeader: string,
  secret: string
): Promise<boolean> {
  // Unipile signs as HMAC-SHA256(secret, body) hex.
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body)
  );
  const expected = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  // constant-time compare
  if (expected.length !== signatureHeader.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ signatureHeader.charCodeAt(i);
  }
  return diff === 0;
}

async function handleAccountConnected(
  env: TwistEnvironment["Bindings"],
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  // Pull the original auth state token (we encoded it in the link's "name").
  const state = (event.name as string | undefined) ?? null;
  const accountId = event.account_id;
  if (!state || !accountId) {
    logger.warn("account.connected event missing state or account_id");
    return;
  }
  const storageObj = env.STORAGE.get(env.STORAGE.idFromName("auth"));
  const pending = await storageObj.get<{
    provider: string;
    callback: string | null;
    redirectUri: string;
    createdAt: number;
  }>(`hosted_auth:${state}`);
  if (!pending) {
    logger.warn("account.connected for unknown auth state", { state });
    return;
  }
  // Record the account_id; the /auth completion endpoint reads this when the
  // browser redirect lands. We DO NOT call onAuth here — the connector's
  // onAuth runs from /auth like every other provider.
  await storageObj.set(`hosted_auth_result:${state}`, {
    accountId,
    accountType: (event.provider as string | undefined) ?? "LINKEDIN",
    receivedAt: Date.now(),
  });
}

async function handleAccountNeedsReauth(
  env: TwistEnvironment["Bindings"],
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  if (!accountId) return;
  // Look up the twist_instance_connection row by account_id (stored as
  // access_token) and stamp needs_reauth_at.
  // Implementation detail: query StoredTokenData for matching access_token.
  logger.info("account needs reauth", { account_id: accountId, event_type: event.event_type });
  // TODO during implementation: wire to the existing `markNeedsReauth` helper.
  // Concrete impl: query twist_instance_connection by access_token, set
  // needs_reauth_at = now(), recovery_pending = true.
}

async function handleNewMessage(
  env: TwistEnvironment["Bindings"],
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  // Dispatch to the connector's stored webhook callback for this account.
  // The callback was created by the connector's onChannelEnabled via
  // network.createWebhook (see Phase 4).
  logger.info("new_message received", { account_id: event.account_id });
  // TODO during implementation: load the stored webhook callback token for
  // this account_id and invoke it with { kind: "message.received", chatId,
  // messageId }.
}

async function handleInvitationReceived(
  env: TwistEnvironment["Bindings"],
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  logger.info("invitation received", { account_id: event.account_id });
  // TODO during implementation: same dispatch path as handleNewMessage.
}

export default hookMessaging;
```

> **NOTE for implementer:** the `TODO during implementation` notes above are
> the only deviation from "no placeholders" allowed in this plan. They mark
> the two glue-code call sites that depend on Phase-4 connector wiring (the
> stored webhook callback registration). Wire them in Task 4.3 below.

- [ ] **Step 3: Register the route in `workers/api/src/index.ts`**

Find the section where other `/hook/*` routes are mounted and add:

```ts
import hookMessaging from "./app/hook-messaging";
// ...
app.route("/", hookMessaging);
```

- [ ] **Step 4: Lint and run all tests**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint && pnpm test
```

Expected: lint 0; tests pass.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/hook-messaging.ts workers/api/src/index.ts
git commit -m "Add /hook/messaging webhook endpoint with signature verification"
```

### Task 3.4: Hosted-auth `/auth` completion path

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` (`POST /twist/:id/integrations/auth/complete` or the existing `/auth` callback handler — whichever is canonical; verify by reading the file's auth handlers)

- [ ] **Step 1: Re-read the existing `/auth` token-exchange handler**

```bash
grep -n "POST.*\\/auth\\|onAuth\\|tokenInfo" /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api/src/app/twist-integrations.ts | head -20
```

Identify the handler that receives the OAuth `code` + `state` from the Flutter app and invokes the connector's `onAuth`. Hosted-auth slots in alongside that handler.

- [ ] **Step 2: Branch the handler on `authMode`**

At the top of the OAuth completion handler, after looking up `state` and the originating provider:

```ts
const config = PROVIDER_CONFIGS[provider];
if (config?.authMode === "hosted") {
  // Hosted-auth completion: pair the state token with the account_id the
  // webhook already delivered (or wait up to 15s for it).
  const storageObj = c.env.STORAGE.get(c.env.STORAGE.idFromName("auth"));
  const deadline = Date.now() + 15_000;
  let result: { accountId: string; accountType: string } | null = null;
  while (Date.now() < deadline) {
    result = await storageObj.get<{ accountId: string; accountType: string }>(
      `hosted_auth_result:${state}`
    );
    if (result) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!result) {
    return c.json(
      { message: "Hosted auth did not complete in time. Try again." },
      504
    );
  }

  // Fetch account profile so the connection has a usable label.
  const client = new (await import("../twist/tools/unipile/client")).UnipileClient(
    c.env
  );
  const account = await client.getAccount(result.accountId);
  const providerData: HostedAccountProviderData = {
    accountId: result.accountId,
    accountType: result.accountType,
    userId:
      account.connection_params?.im?.id ?? result.accountId,
    fullName: account.name ?? null,
    email: null,
  };

  // Build the same tokenInfo shape OAuth produces so `invokeOnAuth` is
  // identical for both paths. The "access_token" IS the Unipile account_id.
  const tokenInfo = {
    access_token: result.accountId,
    refresh_token: null,
    expires_at: null,
    scopes: [] as string[],
    client_id: "hosted",
    providerData,
  };

  // Clean up the auth state and call the connector's onAuth via the same
  // helper the OAuth branch uses.
  await storageObj.delete(`hosted_auth:${state}`);
  await storageObj.delete(`hosted_auth_result:${state}`);
  return c.json(await invokeOnAuthForHosted({ c, state, tokenInfo, provider }));
}
```

Implement `invokeOnAuthForHosted` to mirror the existing OAuth onAuth invocation (look at the function the OAuth branch already calls and reuse it; rename if it's already named generically). This is the trickiest step — read the surrounding code carefully and reuse, don't fork.

- [ ] **Step 3: Lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint
```

Expected: exits 0.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/app/twist-integrations.ts
git commit -m "Add hosted-auth completion path mirroring the OAuth flow"
```

---

## Phase 4: Private LinkedIn connector

### Task 4.1: Scaffold `connectors/linkedin/`

**Files:**
- Create: `connectors/linkedin/package.json`
- Create: `connectors/linkedin/tsconfig.json`
- Create: `connectors/linkedin/README.md`
- Create: `connectors/linkedin/LICENSE`
- Create: `connectors/linkedin/src/index.ts`
- Create: `connectors/linkedin/src/linkedin.ts` (empty class skeleton)

- [ ] **Step 1: Write `connectors/linkedin/package.json`**

```json
{
  "name": "@plotday/connector-linkedin",
  "plotTwistId": "4e6a959d-ebe2-4a85-bd06-ec46fbac204a",
  "displayName": "LinkedIn",
  "description": "LinkedIn messages and connection requests in your Plot inbox",
  "logoUrl": "https://api.iconify.design/logos/linkedin-icon.svg",
  "publisher": "Plot",
  "publisherUrl": "https://plot.day",
  "author": "Plot <team@plot.day> (https://plot.day)",
  "license": "MIT",
  "version": "0.2.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "@plotday/connector": "./src/index.ts",
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "private": true,
  "scripts": {
    "build": "tsc",
    "clean": "rm -rf dist",
    "deploy": "plot deploy",
    "lint": "tsc --noEmit"
  },
  "dependencies": {
    "@plotday/twister": "workspace:*",
    "@plotday/unipile": "workspace:*"
  },
  "devDependencies": {
    "@plotday/tsconfig": "workspace:*",
    "typescript": "^5.9.3"
  }
}
```

> The `plotTwistId` is identical to the existing public connector's. This is intentional — the deployed twist id needs to stay stable so existing references in DB and clients keep matching. The minor version bump (`0.2.0`) signals the swap.

- [ ] **Step 2: Write `connectors/linkedin/tsconfig.json`**

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": { "outDir": "./dist" },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 3: Write `connectors/linkedin/README.md`**

```markdown
# @plotday/connector-linkedin

LinkedIn messaging and connection-request connector for Plot. Private — backed by the internal Unipile-based built-in tools.
```

- [ ] **Step 4: Copy LICENSE from `public/connectors/linkedin-messaging/LICENSE`**

```bash
cp /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public/connectors/linkedin-messaging/LICENSE \
   /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/connectors/linkedin/LICENSE
```

- [ ] **Step 5: Write a stub `src/index.ts` and `src/linkedin.ts`**

`src/index.ts`:

```ts
export { default, LinkedIn } from "./linkedin";
```

`src/linkedin.ts`:

```ts
import { Connector } from "@plotday/twister";

export class LinkedIn extends Connector<LinkedIn> {
  build() {
    return {};
  }
}

export default LinkedIn;
```

- [ ] **Step 6: Reinstall and lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm install
cd connectors/linkedin && pnpm lint
```

Expected: install adds the new package; lint passes.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git add connectors/linkedin pnpm-lock.yaml
git commit -m "Scaffold private @plotday/connector-linkedin package"
```

### Task 4.2: Implement the connector body

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

- [ ] **Step 1: Replace the stub with the real connector**

`connectors/linkedin/src/linkedin.ts`:

```ts
import {
  Connector,
  type NewLinkWithNotes,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import type {
  Actor,
  NewContact,
  NewNote,
  Note,
  Thread,
} from "@plotday/twister/plot";
import {
  AuthProvider,
  Integrations,
  type Authorization,
  type AuthToken,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Network } from "@plotday/twister/tools/network";
import { Options, type OptionsSchema } from "@plotday/twister/options";
import {
  LinkedInMessaging,
  type LinkedInChat,
  type LinkedInInvitation,
  type LinkedInMessage,
  type LinkedInProfile,
} from "@plotday/unipile";

const TYPE_MESSAGE = "message";
const TYPE_INVITATION = "invitation";
const STATUS_INBOX = "inbox";
const STATUS_ARCHIVE = "archive";
const STATUS_PENDING = "pending";
const PROVIDER_KEY = "linkedin";

const OPTIONS_SCHEMA = {
  importMessages: {
    type: "boolean",
    label: "Import direct messages",
    description: "Sync your LinkedIn DMs into Plot.",
    default: true,
  },
  importInvitations: {
    type: "boolean",
    label: "Import connection requests",
    description: "Sync inbound LinkedIn connection requests into Plot.",
    default: true,
  },
} as const satisfies OptionsSchema;

type SyncState = {
  initialSync: boolean;
  lastMessageHighWaterMs: number | null;
  lastInvitationHighWaterMs: number | null;
};

export class LinkedIn extends Connector<LinkedIn> {
  static readonly PROVIDER = AuthProvider.LinkedIn;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.LinkedIn;
  readonly scopes = LinkedIn.SCOPES;
  readonly linkTypes = [
    {
      type: TYPE_MESSAGE,
      label: "Message",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_INBOX, label: "Inbox" },
        { status: STATUS_ARCHIVE, label: "Archived" },
      ],
    },
    {
      type: TYPE_INVITATION,
      label: "Connection request",
      logo: "https://api.iconify.design/logos/linkedin-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
      statuses: [
        { status: STATUS_PENDING, label: "Pending" },
        { status: STATUS_ARCHIVE, label: "Archived" },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      linkedin: build(LinkedInMessaging),
      network: build(Network, {
        urls: [],  // We do not call third-party URLs from the connector
                   // sandbox. All LinkedIn calls go through tools.linkedin.
      }),
      options: build(Options, OPTIONS_SCHEMA),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
    };
  }

  // ------- Channel lifecycle -------

  async getChannels(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    // Single channel per LinkedIn account; channelId IS the Unipile account_id
    // (stored as access_token). Additional accounts = additional connections.
    if (!token?.token) return [];
    const title = auth?.actor.name ?? "LinkedIn";
    return [{ id: token.token, title }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_state_${channel.id}`, {
      initialSync: true,
      lastMessageHighWaterMs: null,
      lastInvitationHighWaterMs: null,
    } satisfies SyncState);

    // Register the messaging webhook callback. The /hook/messaging
    // dispatcher invokes this when a new message/invitation event lands.
    const webhookCallback = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, webhookCallback);

    // Schedule the initial sync as a separate task so onChannelEnabled
    // returns promptly.
    const batch = await this.callback(this.syncBatch, channel.id, true);
    await this.runTask(batch);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);
  }

  // ------- Sync loop -------

  async syncBatch(channelId: string, initialSync: boolean): Promise<void> {
    const state = (await this.get<SyncState>(`sync_state_${channelId}`)) ?? {
      initialSync,
      lastMessageHighWaterMs: null,
      lastInvitationHighWaterMs: null,
    };

    const importMessages = this.tools.options.importMessages !== false;
    const importInvitations = this.tools.options.importInvitations !== false;

    let newMessageHigh = state.lastMessageHighWaterMs ?? 0;
    let newInvitationHigh = state.lastInvitationHighWaterMs ?? 0;

    if (importMessages) {
      const since = state.lastMessageHighWaterMs
        ? new Date(state.lastMessageHighWaterMs)
        : undefined;
      const result = await this.tools.linkedin.listChats({
        channelId,
        limit: 20,
        since,
      });
      const links: NewLinkWithNotes[] = [];
      for (const chat of result.chats) {
        const link = await this.buildChatLink(
          channelId,
          chat,
          state.initialSync,
          since
        );
        if (link) links.push(link);
        const t = chat.lastActivityAt.getTime();
        if (t > newMessageHigh) newMessageHigh = t;
      }
      if (links.length > 0) {
        await this.tools.integrations.saveLinks(links);
      }
    }

    if (importInvitations) {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 20,
      });
      const links = result.invitations
        .map((inv) => buildInvitationLink(inv, state.initialSync))
        .filter((l): l is NewLinkWithNotes => l != null);
      for (const inv of result.invitations) {
        const t = inv.sentAt.getTime();
        if (t > newInvitationHigh) newInvitationHigh = t;
      }
      if (links.length > 0) {
        await this.tools.integrations.saveLinks(links);
      }
    }

    await this.set(`sync_state_${channelId}`, {
      initialSync: false,
      lastMessageHighWaterMs: newMessageHigh || null,
      lastInvitationHighWaterMs: newInvitationHigh || null,
    } satisfies SyncState);

    if (state.initialSync) {
      await this.tools.integrations.channelSyncCompleted(channelId);
    }

    // Schedule the next polling pass — 30 min backstop (webhooks are
    // primary).
    const next = await this.callback(this.syncBatch, channelId, false);
    await this.runTask(next, {
      runAt: new Date(Date.now() + 30 * 60 * 1000),
    });
  }

  // ------- Webhook callback -------

  async onWebhookEvent(
    channelId: string,
    event:
      | { kind: "message.received"; chatId: string; messageId: string }
      | { kind: "invitation.received"; invitationId: string }
  ): Promise<void> {
    if (event.kind === "message.received") {
      const chat = await this.tools.linkedin.getChat({
        channelId,
        chatId: event.chatId,
      });
      const link = await this.buildChatLink(channelId, chat, false, undefined);
      if (link) await this.tools.integrations.saveLinks([link]);
    } else {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 1,
      });
      const target = result.invitations.find((i) => i.id === event.invitationId);
      if (!target) return;
      const link = buildInvitationLink(target, false);
      if (link) await this.tools.integrations.saveLinks([link]);
    }
  }

  // ------- Write-back -------

  override async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;
    const sent = await this.tools.linkedin.sendMessage({
      channelId,
      chatId,
      text: note.content ?? "",
    });
    return {
      key: `message-${sent.id}`,
      externalContent: sent.text,
    };
  }

  override async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;
    try {
      await this.tools.linkedin.setChatRead({
        channelId,
        chatId,
        read: !unread,
      });
    } catch (error) {
      console.warn(
        `LinkedIn setChatRead failed for chat ${chatId} (read=${!unread})`,
        error
      );
    }
  }

  // ------- Helpers -------

  private async buildChatLink(
    channelId: string,
    chat: LinkedInChat,
    initialSync: boolean,
    since: Date | undefined
  ): Promise<NewLinkWithNotes | null> {
    const messages = await this.tools.linkedin.listMessages({
      channelId,
      chatId: chat.id,
      limit: 20,
      since: initialSync ? undefined : since,
    });

    const notes: NewNote[] = messages.messages
      .slice()
      .reverse()
      .map((msg) => buildNoteFromMessage(msg, chat));

    const contacts = chat.participants
      .map(profileToContact)
      .filter((c): c is NewContact => c != null);

    const title = chat.isGroup
      ? chat.title ?? joinParticipantNames(chat.participants)
      : chat.participants[0]?.fullName ?? "LinkedIn message";

    return {
      source: `linkedin:chat:${chat.id}`,
      sources: [`linkedin:chat:${chat.id}`],
      type: TYPE_MESSAGE,
      status: STATUS_INBOX,
      title,
      preview: chat.lastMessagePreview ?? null,
      sourceUrl: chat.url,
      created: chat.lastActivityAt,
      contacts,
      notes,
      meta: {
        syncProvider: PROVIDER_KEY,
        channelId,
        chatId: chat.id,
        isGroup: chat.isGroup,
      },
      ...(initialSync ? { unread: false, archived: false } : {}),
    } as NewLinkWithNotes;
  }
}

export default LinkedIn;

// ------- Pure helpers -------

function buildNoteFromMessage(
  msg: LinkedInMessage,
  chat: LinkedInChat
): NewNote {
  const author = msg.sentByMe
    ? null
    : chat.participants.find((p) => p.id === msg.senderId) ?? null;

  const attachmentSuffix = msg.attachments.length
    ? "\n\n" +
      msg.attachments
        .map(
          (a) =>
            `📎 [${a.name ?? "attachment"}](${a.url})` +
            (a.contentType ? ` (${a.contentType})` : "")
        )
        .join("\n")
    : "";

  return {
    thread: { source: `linkedin:chat:${chat.id}` },
    key: `message-${msg.id}`,
    created: msg.sentAt,
    content: msg.text + attachmentSuffix,
    contentType: "text",
    author: author ? profileToContact(author) ?? undefined : undefined,
  };
}

function profileToContact(profile: LinkedInProfile | null): NewContact | null {
  if (!profile) return null;
  if (profile.email) {
    return {
      email: profile.email,
      name: profile.fullName,
      avatar: profile.pictureUrl ?? undefined,
    };
  }
  if (profile.publicIdentifier) {
    return {
      email: `${profile.publicIdentifier}@linkedin.invalid`,
      name: profile.fullName,
      avatar: profile.pictureUrl ?? undefined,
    };
  }
  return null;
}

function joinParticipantNames(profiles: LinkedInProfile[]): string {
  if (profiles.length === 0) return "LinkedIn group";
  if (profiles.length === 1) return profiles[0]!.fullName;
  if (profiles.length === 2)
    return `${profiles[0]!.fullName}, ${profiles[1]!.fullName}`;
  return `${profiles[0]!.fullName}, ${profiles[1]!.fullName} +${profiles.length - 2}`;
}

function buildInvitationLink(
  inv: LinkedInInvitation,
  initialSync: boolean
): NewLinkWithNotes | null {
  const contact = profileToContact(inv.inviter);
  if (!contact) return null;

  const notes: NewNote[] = [];
  if (inv.message) {
    notes.push({
      thread: { source: `linkedin:invitation:${inv.id}` },
      key: `invitation-${inv.id}`,
      content: inv.message,
      contentType: "text",
      created: inv.sentAt,
      author: contact,
    });
  }

  return {
    source: `linkedin:invitation:${inv.id}`,
    sources: [
      `linkedin:invitation:${inv.id}`,
      `linkedin:person:${inv.inviter.id}`,
    ],
    type: TYPE_INVITATION,
    status: STATUS_PENDING,
    title: `Connection request from ${inv.inviter.fullName}`,
    preview: inv.message ?? inv.inviter.headline ?? null,
    sourceUrl: inv.inviter.url,
    created: inv.sentAt,
    contacts: [contact],
    notes,
    meta: {
      syncProvider: PROVIDER_KEY,
      channelId: PROVIDER_KEY,
      invitationId: inv.id,
      sharedSecret: inv.sharedSecret,
      inviterId: inv.inviter.id,
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } as NewLinkWithNotes;
}
```

- [ ] **Step 2: Lint the connector**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/connectors/linkedin && pnpm lint
```

Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git add connectors/linkedin/src
git commit -m "Implement LinkedIn connector with options + write-back"
```

### Task 4.3: Wire webhook dispatch from `/hook/messaging` to the connector

**Files:**
- Modify: `workers/api/src/app/hook-messaging.ts` (resolve the two `TODO during implementation` stubs)

- [ ] **Step 1: Implement `handleAccountNeedsReauth`**

In `hook-messaging.ts`, replace the stub body of `handleAccountNeedsReauth` with a DB query that finds the `twist_instance_connection` row(s) by `access_token = account_id` and `provider = 'linkedin'` (or whatever, based on `event.provider`), and sets `needs_reauth_at = now(), recovery_pending = true`. Mirror the existing `markNeedsReauth` helper if it exists; otherwise inline a small Kysely query.

- [ ] **Step 2: Implement `handleNewMessage` and `handleInvitationReceived`**

Pull the connector's stored webhook callback for the account. The connector stores it under `webhook_callback_${channelId}` (where `channelId == account_id`) via `this.set` (see Task 4.2). That value is a `Callback` (a serialised callback token). Invoke it via the existing `callbacks.run` infrastructure:

```ts
async function handleNewMessage(env, event, logger) {
  const accountId = event.account_id;
  if (!accountId) return;
  const chatId = (event.payload?.chat_id as string | undefined) ?? null;
  const messageId = (event.payload?.message_id as string | undefined) ?? null;
  if (!chatId || !messageId) return;

  const token = await loadConnectorWebhookCallback(env, accountId);
  if (!token) return;
  await runCallback(env, token, {
    kind: "message.received",
    chatId,
    messageId,
  });
}
```

`loadConnectorWebhookCallback` reads from the same Storage DO + key the
connector wrote to: `webhook_callback_${accountId}` under the
LinkedInMessaging tool path. `runCallback` invokes the stored token. Refer
to `workers/api/src/twist/tools/network.ts` for the canonical pattern
(other connectors do the same thing for webhooks).

- [ ] **Step 3: Lint and run tests**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/workers/api && pnpm lint && pnpm test
```

Expected: lint 0; tests pass.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/app/hook-messaging.ts
git commit -m "Dispatch hosted-auth webhooks to connector callbacks"
```

---

## Phase 5: DB migration to force re-auth

### Task 5.1: SQL migration to invalidate existing LinkedIn connections

**Files:**
- Create: `libs/db/schema/99-data/<sequence>_linkedin_force_reauth.sql` (or wherever the project conventionally puts data migrations; otherwise drop into the next-generated migration directly)
- Generated: `libs/db/migrations/<timestamp>_linkedin_force_reauth.sql`

- [ ] **Step 1: Add the SQL to a fresh data-migration file**

Per AGENTS.md, the canonical path is `pnpm gen-migration -- linkedin_force_reauth`, then add the SQL body to the generated file:

```sql
UPDATE public.twist_instance_connection
   SET needs_reauth_at = now(),
       recovery_pending = true
 WHERE provider = 'linkedin'
   AND needs_reauth_at IS NULL;
```

- [ ] **Step 2: Run migrations against the worktree's local DB**

First ensure the worktree DB is up:

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
bash scripts/worktree-db
pnpm apply-migrations
```

Expected: migration applies cleanly. Confirm `atlas.sum` is updated.

- [ ] **Step 3: Verify**

```bash
psql "$DATABASE_URL" -c \
  "SELECT count(*) FROM twist_instance_connection WHERE provider = 'linkedin' AND needs_reauth_at IS NULL;"
```

Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add libs/db/migrations
git commit -m "Force re-auth on all LinkedIn connections (Unipile migration)"
```

---

## Phase 6: Flutter cleanup

### Task 6.1: Drop the LinkedIn special-case from `auth_button.dart`

**Files:**
- Modify: `apps/plot/lib/widget/auth_button.dart`

- [ ] **Step 1: Remove the LinkedIn branch in `_onPress`**

Delete these lines (around 697–705):

```dart
      // LinkedIn does not use OAuth for personal messaging — it has its own
      // session-cookie capture flow. Route the connect-button tap to the
      // LinkedIn login modal instead of falling through to OAuth (which the
      // server would reject with "Provider linkedin does not use OAuth").
      if (widget.provider == AuthProvider.linkedin) {
        _startLinkedInCookieFlow();
        return;
      }
```

- [ ] **Step 2: Delete `_startLinkedInCookieFlow` (around 829–861)**

The entire `_startLinkedInCookieFlow` method goes away.

- [ ] **Step 3: Remove the now-unused import**

Delete:

```dart
import 'package:plot/widget/linkedin_login_modal.dart';
```

- [ ] **Step 4: Run analyzer**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/apps/plot && flutter analyze lib/widget/auth_button.dart
```

Expected: no errors related to this file.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/auth_button.dart
git commit -m "Remove LinkedIn cookie-capture branch from AuthButton"
```

### Task 6.2: Delete `linkedin_login_modal.dart`

**Files:**
- Delete: `apps/plot/lib/widget/linkedin_login_modal.dart`

- [ ] **Step 1: Delete the file**

```bash
git rm apps/plot/lib/widget/linkedin_login_modal.dart
```

- [ ] **Step 2: Run analyzer over the whole app**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/apps/plot && flutter analyze
```

Expected: no errors referencing the deleted modal. If there are stragglers, remove them in this commit.

- [ ] **Step 3: Commit**

```bash
git commit -m "Delete LinkedIn cookie-capture modal"
```

### Task 6.3: Remove `postLinkedInCookie` and `TwistLinkedInCookieResult` from `twist_api.dart`

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart`

- [ ] **Step 1: Remove the static method (around line 301) and the result class (line 687)**

Delete:

- The `postLinkedInCookie` static method (lines ~292–318).
- The `TwistLinkedInCookieResult` class (lines ~686–702).

- [ ] **Step 2: Run analyzer**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/apps/plot && flutter analyze
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/api/twist_api.dart
git commit -m "Remove LinkedIn cookie API stubs from twist_api"
```

---

## Phase 7: Cleanup — public submodule + dead server code

### Task 7.1: Branch the `public/` submodule

- [ ] **Step 1: Create a branch in the submodule**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public
git checkout -b linkedin-unipile-cleanup
```

### Task 7.2: Delete `public/connectors/linkedin-messaging/`

- [ ] **Step 1: Remove the package directory**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public
git rm -r connectors/linkedin-messaging
```

- [ ] **Step 2: Commit (inside the submodule)**

```bash
git commit -m "Remove public LinkedIn connector (replaced by private Unipile-backed one)"
```

### Task 7.3: Remove the `LinkedIn` tool from twister

**Files (in `public/` submodule):**
- Delete: `public/twister/src/tools/linkedin.ts`
- Delete: `public/twister/src/llm-docs/tools/linkedin.ts`
- Modify: `public/twister/src/tools/integrations.ts` (remove `LinkedInProviderData`)
- Modify: any twister `src/index.ts` or barrel that exports the LinkedIn tool

- [ ] **Step 1: Delete the LinkedIn tool files and barrels**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public
git rm twister/src/tools/linkedin.ts twister/src/llm-docs/tools/linkedin.ts
```

- [ ] **Step 2: Remove `LinkedInProviderData` from `public/twister/src/tools/integrations.ts`**

Delete the type definition and remove it from the `ProviderData` union and the `extractUserId` switch.

- [ ] **Step 3: Find and remove any remaining `LinkedIn` exports**

```bash
grep -rn "LinkedIn" /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public/twister/src
```

Remove any matches that are part of the tool's public surface.

- [ ] **Step 4: Rebuild twister**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public/twister && pnpm build
```

Expected: clean build.

- [ ] **Step 5: Add a changeset**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/public
cat > .changeset/remove-linkedin-tool.md <<'EOF'
---
"@plotday/twister": minor
---

Removed: `LinkedIn` built-in tool and `LinkedInProviderData` type. LinkedIn is now backed by a private connector and uses the standard hosted-auth provider config.
EOF
pnpm validate-changesets
```

Expected: validation passes.

- [ ] **Step 6: Commit inside the submodule**

```bash
git add twister .changeset
git commit -m "Remove LinkedIn tool from @plotday/twister"
```

### Task 7.4: Delete dead server-side LinkedIn code

**Files (in the worktree, NOT the submodule):**
- Delete: `workers/api/src/twist/tools/linkedin.ts`
- Delete: `workers/api/src/twist/tools/linkedin-voyager.ts`
- Modify: `workers/api/src/twist/tools/factory.ts` (remove the `LinkedIn` cases)
- Modify: `workers/api/src/app/twist-integrations.ts` (remove `/linkedin/cookie` endpoint)
- Modify: `workers/api/wrangler.jsonc` (remove `LINKEDIN_RATE_LIMITER` binding)
- Modify: `workers/api/src/provider.ts` (remove any remaining `LinkedInProviderData` shims)

- [ ] **Step 1: Delete the files**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git rm workers/api/src/twist/tools/linkedin.ts workers/api/src/twist/tools/linkedin-voyager.ts
```

- [ ] **Step 2: Remove the factory cases**

In `workers/api/src/twist/tools/factory.ts`, delete the `case "LinkedIn":` branches in both `getToolClass` and `createTool`, plus the `import { LinkedIn } from "./linkedin"` at the top.

- [ ] **Step 3: Remove `/linkedin/cookie` endpoint and related imports**

In `workers/api/src/app/twist-integrations.ts`:
- Delete the `LinkedInCookieRequestSchema` (line ~542).
- Delete the entire `twistIntegrations.post("/twist/:id/integrations/linkedin/cookie", …)` handler (line ~549 through ~700).
- Delete the `import { probeLinkedInProfile } from "../twist/tools/linkedin-voyager";` at the top.

- [ ] **Step 4: Remove `LINKEDIN_RATE_LIMITER` binding from `wrangler.jsonc`**

Remove the binding block in both the dev and prod sections.

- [ ] **Step 5: Update the worker `Bindings` type**

If `Bindings` references `LINKEDIN_RATE_LIMITER`, remove it.

- [ ] **Step 6: Lint + tests + bump submodule pointer**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm install
cd workers/api && pnpm lint && pnpm test
```

Expected: lint 0; tests pass.

- [ ] **Step 7: Stage the submodule pointer bump**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git add public
```

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/twist/tools/linkedin.ts \
        workers/api/src/twist/tools/linkedin-voyager.ts \
        workers/api/src/twist/tools/factory.ts \
        workers/api/src/app/twist-integrations.ts \
        workers/api/wrangler.jsonc \
        workers/api/src/provider.ts \
        workers/api/src/env.ts 2>/dev/null
git commit -m "Remove Voyager-based LinkedIn implementation"
```

---

## Phase 8: End-to-end verification

### Task 8.1: Start local infrastructure

- [ ] **Step 1: Set real Unipile env vars**

Replace the placeholder values in `workers/api/.dev.vars` with the user's actual `UNIPILE_API_KEY`, `UNIPILE_DSN`, and `UNIPILE_WEBHOOK_SECRET`. **Ask the user for these values — do not invent them.**

- [ ] **Step 2: Start the local DB**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && bash scripts/worktree-db
```

Expected: PostgreSQL up; `pnpm apply-migrations` applies cleanly.

- [ ] **Step 3: Start the API worker**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm --filter @plotday/api dev
```

In a second shell, start the tunnel so Unipile can reach the local webhook:

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm tunnel:start
```

- [ ] **Step 4: Register the webhook with Unipile**

In Unipile's dashboard (or via their `/webhooks` API), register
`https://api-kris.plot.day/hook/messaging` for the `account.*` and
`messaging.*` event types. Verify the signing secret matches
`UNIPILE_WEBHOOK_SECRET`.

### Task 8.2: Walk the connection flow in the app

- [ ] **Step 1: Launch the Flutter app via the `run-app` skill**

```bash
# invoke the run-app skill — see apps/plot/AGENTS.md
```

- [ ] **Step 2: Try connecting LinkedIn**

In Plot, navigate to install/edit a twist that uses LinkedIn. Click
"Continue with LinkedIn". Confirm:

- Button label is "Continue with LinkedIn" (same as every other AuthButton).
- A webview/browser opens to a Unipile-hosted URL.
- After completing LinkedIn auth on that page, the user is redirected
  back to Plot and the setup modal opens.
- The setup modal shows the connection's account name + the two boolean
  options (Import direct messages, Import connection requests).
- Toggling one off and saving causes only the other to sync.

- [ ] **Step 3: Verify sync**

- A few minutes after enabling, expect threads to appear in the Plot
  inbox.
- Reply to a LinkedIn thread in Plot — verify the reply lands on
  LinkedIn (check via linkedin.com).
- Mark a thread read in Plot — verify the LinkedIn chat shows as read.

- [ ] **Step 4: Verify webhook signature handling**

While the worker is running, watch `wrangler dev` logs for an
`x-unipile-signature` mismatch warning when (deliberately, with `curl`)
hitting the endpoint without a valid signature:

```bash
curl -X POST https://api-kris.plot.day/hook/messaging \
  -H 'content-type: application/json' \
  -d '{"event_type":"account.connected"}'
```

Expected: 401 with the worker logging the mismatch.

### Task 8.3: Manual cleanup verification

- [ ] **Step 1: Confirm `flutter analyze` is clean**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile/apps/plot && flutter analyze
```

Expected: no errors, no warnings on the files we touched.

- [ ] **Step 2: Confirm repo-wide lint passes**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile && pnpm lint
```

Expected: exits 0.

- [ ] **Step 3: Confirm no `LinkedInProviderData`, `linkedin-voyager`, or `postLinkedInCookie` references survive**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/linkedin-unipile
git grep -E "LinkedInProviderData|linkedin-voyager|postLinkedInCookie|TwistLinkedInCookieResult|LinkedInLoginModal|LINKEDIN_RATE_LIMITER" -- ':!docs/' ':!.claude/' ':!*.lock'
```

Expected: no matches (docs and lockfiles excluded).

---

## Phase 9: Finalize

### Task 9.1: Run `/finalize`

- [ ] **Step 1: Invoke the `finalize` skill**

This runs the project's full pre-commit checklist (lint, backwards compat, error capture, docs, public submodule PR handling).

### Task 9.2: Add a user-visible update note

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a bullet at the top of the current section**

```markdown
- LinkedIn integration now uses our new unified messaging backend, with a smoother sign-in flow. Existing LinkedIn connections will ask you to reconnect once.
```

- [ ] **Step 2: Commit**

```bash
git add docs/updates.md
git commit -m "Note LinkedIn unified-messaging migration in updates"
```

### Task 9.3: Open PRs

Open two PRs (the main repo PR depends on the public submodule PR landing first):

1. `public/` submodule PR titled "Remove LinkedIn tool and connector".
2. This repo's PR titled "LinkedIn connector: switch to Unipile-backed hosted auth".

Both PRs reference the design doc and the implementation plan in their descriptions.

---

## Plan self-review

**Spec coverage:**

- Vendor-agnostic naming → Tasks 2.3 (`UnipileClient` is the only namesake), 3.1 (`HostedAccountProviderData`, `authMode: "hosted"`), 3.3 (`/hook/messaging` route).
- Single-channel + options → Task 4.2 (`getChannels` returns one channel keyed on `access_token`; `OPTIONS_SCHEMA` exposes the two toggles).
- Flutter UX parity → Task 6.1 (delete LinkedIn special case so `_startTwistAuth` handles LinkedIn like every other provider).
- Delete-everything cleanup → Tasks 6.2, 6.3, 7.2, 7.3, 7.4.
- Migration to force re-auth → Task 5.1.
- Public-twister changeset → Task 7.3 Step 5.
- Spec's "Open questions deferred to implementation" — kept open; webhook
  signature format and `account.error` semantics verified during Task 8.

**Placeholder scan:** the only two intentional "TODO during implementation" notes are in Task 3.3 Step 2 — they explicitly flag the integration points wired up in Task 4.3 (where I provide concrete code).

**Type consistency:** `LinkedInMessaging` is the abstract class in `libs/unipile/src/linkedin.ts` AND the concrete impl class in `workers/api/src/twist/tools/unipile/linkedin.ts` — the impl implements the abstract via `implements ILinkedInMessaging` after renaming the abstract import. The concrete class shadows the abstract — keep both classes named `LinkedInMessaging` and disambiguate via `import { LinkedInMessaging as ILinkedInMessaging }` at the impl call site (Task 2.5 shows this). The `Channel` shape (`{id, title}`) is consistent across `getChannels` and the factory wiring. `channelId === access_token === Unipile account_id` invariant is consistent across the connector body, the LinkedInMessaging tool, the auth state storage, and the webhook dispatcher.
