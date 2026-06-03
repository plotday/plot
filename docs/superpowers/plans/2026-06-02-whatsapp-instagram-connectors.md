# WhatsApp + Instagram premium connectors (Unipile) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship WhatsApp and Instagram premium connectors (Unipile-backed) with full two-way sync and compose, built on a shared Unipile messaging core that the LinkedIn connector is refactored onto in the same pass.

**Architecture:** A provider-neutral messaging layer in `libs/unipile` (neutral types + an abstract `UnipileMessaging` tool + pure connector helpers) and `workers/api/src/twist/tools/unipile` (a `UnipileMessagingTool` concrete base over the existing provider-agnostic `UnipileClient`, parameterized by `provider`). LinkedIn, WhatsApp, and Instagram are thin subclasses + thin connector packages. Sync is webhook-driven with a one-time backfill; **no recurring poll**.

**Tech Stack:** TypeScript (ESM, `moduleResolution: bundler`), pnpm workspaces, Vitest, Cloudflare Workers runtime, `@plotday/twister` SDK (pinned submodule `d6803ad`), Unipile REST API.

**Reference spec:** `docs/superpowers/specs/2026-06-02-whatsapp-instagram-connectors-design.md`

---

## Conventions for the implementer

- **Worktree:** all work happens in this worktree (`.claude/worktrees/whatsapp-instagram-connectors`, branch off local main). Twister `dist` is already built; if you re-clone state, run `cd public/twister && pnpm build`.
- **Commit messages:** end every commit body with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Lint = typecheck:** each TS package's `lint` script is `tsc --noEmit`. "Run lint" means `pnpm --filter <pkg> lint`.
- **Unit tests (workers/api):** `pnpm --filter @plotday/api test` runs the *unit* config (excludes `__tests__/`). Put unit tests next to source as `*.test.ts`. The integration pool can wedge the shell on exit — always wrap in `timeout`: `timeout 180 pnpm --filter @plotday/api test -- <file>`.
- **Unit tests (libs/unipile):** see Task 1 (adds a Vitest `test` script).
- **Never deploy.** Live two-way verification against real Unipile accounts is the user's manual step (spec §12).
- **`§13` open items** (reaction-clear path, IG message-request representation, IG username resolution, WhatsApp JID acceptance) are coded against the best-known Unipile shape and flagged with `// LIVE-CONFIRM (§13):` comments so the user can correct them during live testing.
- **Port instructions** that say "port from `connectors/linkedin/src/linkedin.ts`" refer to the **current repo file** as the behavioral reference — read it directly; it is not another plan task.

---

## File Structure

**`libs/unipile/src/`** (types + abstract tools + pure helpers; imported by both connectors and workers/api)
- `messaging.ts` — NEW. Neutral types (`ChatProfile`, `ChatAttachment`, `ChatMessageReaction`, `ChatMessage`, `ChatThread`, `ChatThreadPage`, `ChatMessagePage`) + abstract `UnipileMessaging extends ITool` (common methods + `resolveRecipient`).
- `connector-helpers.ts` — NEW. Pure functions shared by all three connectors: `profileToContact`, `senderFallbackContact`, `joinParticipantNames`, `buildNoteFromMessage`, `buildReactionsFromMessage`, `pickDesiredReaction`, `assembleConversationLink`, `assembleGroupLink`, and the tool-driven `buildLinkForChat` / `backfillChats`.
- `linkedin.ts` — MOD. `LinkedInMessaging extends UnipileMessaging` + LinkedIn-only methods (`listReceivedInvitations`, `acceptInvitation`, `ignoreInvitation`, `listRelations`) and types (`LinkedInInvitation`, `*Page`).
- `whatsapp.ts` — NEW. `WhatsAppMessaging extends UnipileMessaging` (marker subclass; `resolveRecipient` = phone→JID).
- `instagram.ts` — NEW. `InstagramMessaging extends UnipileMessaging` + `acceptMessageRequest` / `ignoreMessageRequest`.
- `types.ts` — MOD. Keep raw Unipile wire types; remove the LinkedIn* Plot-shaped types (moved/renamed to `messaging.ts`).
- `index.ts` — MOD. Export `messaging`, `connector-helpers`, `linkedin`, `whatsapp`, `instagram`, `types`.

**`workers/api/src/twist/tools/unipile/`** (concrete tools over `UnipileClient`)
- `messaging.ts` — NEW. `abstract class UnipileMessagingTool extends Tool` implementing the common methods; `provider` abstract; `assertAccount` keyed on `this.provider`.
- `linkedin.ts` — MOD. `LinkedInMessaging extends UnipileMessagingTool` (`provider="linkedin"`) + invitation/relation methods.
- `whatsapp.ts` — NEW. `WhatsAppMessaging extends UnipileMessagingTool` (`provider="whatsapp"`, `resolveRecipient` phone→JID).
- `instagram.ts` — NEW. `InstagramMessaging extends UnipileMessagingTool` (`provider="instagram"`, `resolveRecipient` username→id, message-request actions).
- `normalize.ts` — MOD. Return neutral types; add `folder` to `normalizeChat`; keep invitation/relation normalizers.
- `client.ts` — MOD. Fix `startChat` → `POST /chats`; add `resolveUser`; add `listChats` `folder` passthrough; add reaction-clear per §13.
- `*.test.ts` — NEW/MOD unit tests.

**`connectors/`**
- `linkedin/src/linkedin.ts` — MOD. Refactor onto shared core; collapse to one composable `conversation` type; drop poll/refresh; fixes.
- `whatsapp/**` — NEW package.
- `instagram/**` — NEW package.

**Server wiring**
- `workers/api/src/twist/tools/factory.ts` — MOD. Register `WhatsAppMessaging`, `InstagramMessaging`.
- `workers/api/src/provider.ts` — MOD. `PROVIDER_CONFIGS` entries for `whatsapp`, `instagram`.
- `workers/api/src/app/hook-messaging.ts` — MOD. Derive reauth provider from the channel's connector.
- `apps/site/app/data/connections.ts` — MOD. Two premium entries.
- `docs/updates.md`, `docs/features.md` — MOD.

---

# Phase 1 — Shared core + LinkedIn refactor & fixes

End state: `@plotday/unipile`, `@plotday/connector-linkedin`, and `@plotday/api` lint + unit tests green; LinkedIn behavior preserved and fixed (startChat endpoint, 1 composable type, reaction-clear, no poll, person-keyed compose).

### Task 1: Add a Vitest test runner to `libs/unipile`

**Files:**
- Modify: `libs/unipile/package.json`
- Create: `libs/unipile/vitest.config.ts`

- [ ] **Step 1: Add the `test` script + vitest dev dep**

In `libs/unipile/package.json`, add to `scripts`:
```json
"test": "vitest run",
"test:watch": "vitest"
```
Add to `devDependencies` (match the version used elsewhere in the repo; check `workers/api/package.json`):
```json
"vitest": "^2.1.8"
```

- [ ] **Step 2: Create `libs/unipile/vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
```

- [ ] **Step 3: Install**

Run: `pnpm install`
Expected: completes; `vitest` resolves in `libs/unipile`.

- [ ] **Step 4: Sanity check the runner**

Create a temporary `libs/unipile/src/__smoke.test.ts` with `import {test,expect} from "vitest"; test("ok",()=>expect(1).toBe(1));`
Run: `pnpm --filter @plotday/unipile test`
Expected: 1 passing test. Then delete the smoke file.

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/package.json libs/unipile/vitest.config.ts pnpm-lock.yaml
git commit -m "chore(unipile): add vitest runner

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Neutral messaging types + abstract `UnipileMessaging` tool

**Files:**
- Create: `libs/unipile/src/messaging.ts`

This replaces the LinkedIn-named Plot-shaped types. Field mapping from the old `LinkedInProfile`: `fullName→name`, `publicIdentifier→handle`, `headline→subtitle`, `url→profileUrl`, plus new `phone`.

- [ ] **Step 1: Write `libs/unipile/src/messaging.ts`**

```ts
import { ITool } from "@plotday/twister";

/**
 * Provider-neutral messaging types shared by the LinkedIn, WhatsApp, and
 * Instagram connectors. Intentionally Plot-flavoured, not Unipile-flavoured:
 * the concrete tools in workers/api map Unipile wire shapes onto these.
 */

export type ChatProfile = {
  /** Provider-side id (Unipile `provider_id`). */
  id: string;
  /** True when this profile is the connected account itself. */
  isSelf: boolean;
  /** Display name. */
  name: string;
  /** Username / public slug: LinkedIn public_identifier, IG @username, or null. */
  handle: string | null;
  /** Secondary line: LinkedIn headline, WhatsApp status, etc. */
  subtitle: string | null;
  email: string | null;
  /** E.164-ish phone when known (WhatsApp). */
  phone: string | null;
  pictureUrl: string | null;
  /** Canonical web profile URL when derivable, else null. */
  profileUrl: string | null;
};

export type ChatAttachment = {
  id: string;
  kind: "image" | "video" | "audio" | "file" | "other";
  name: string | null;
  url: string;
  contentType: string | null;
  byteSize: number | null;
};

export type ChatMessageReaction = {
  value: string;
  senderId: string;
  sentByMe: boolean;
};

export type ChatMessage = {
  id: string;
  chatId: string;
  senderId: string;
  sentByMe: boolean;
  /** Non-null for synthetic events (reactions, renames, calls); connectors skip these. */
  eventType: string | null;
  sentAt: Date;
  text: string;
  attachments: ChatAttachment[];
  reactions: ChatMessageReaction[];
};

export type ChatThread = {
  id: string;
  title: string | null;
  isGroup: boolean;
  participants: ChatProfile[];
  lastMessagePreview: string | null;
  lastActivityAt: Date;
  unreadCount: number;
  archived: boolean;
  /**
   * Provider folder/bucket when applicable. Instagram surfaces message
   * requests via a non-inbox folder (e.g. "REQUESTS"); null when unknown or
   * the platform has no folder concept.
   */
  folder: string | null;
  url: string | null;
};

export type ChatThreadPage = { chats: ChatThread[]; nextCursor: string | null };
export type ChatMessagePage = { messages: ChatMessage[]; nextCursor: string | null };

/**
 * Common messaging surface every Unipile provider tool implements. Concrete
 * impls live in `workers/api/src/twist/tools/unipile/*`. Provider-specific
 * extras (LinkedIn invitations/relations, IG message requests) are declared on
 * the per-provider subclasses.
 */
export abstract class UnipileMessaging extends ITool {
  // Subclasses set their own static toolId (e.g. "WhatsAppMessaging").

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listChats(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<ChatThreadPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getChat(params: { channelId: string; chatId: string }): Promise<ChatThread>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listMessages(params: {
    channelId: string;
    chatId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<ChatMessagePage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract sendMessage(params: {
    channelId: string;
    chatId: string;
    text: string;
    attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  }): Promise<ChatMessage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract downloadAttachment(params: {
    channelId: string;
    messageId: string;
    attachmentId: string;
  }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setMessageReaction(params: {
    channelId: string;
    messageId: string;
    reaction: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract clearMessageReaction(params: { channelId: string; messageId: string }): Promise<void>;

  /**
   * Start a new chat (1:1 or group) and send the first message. Provider ids
   * are the platform's attendee ids (LinkedIn URN, WhatsApp JID, IG user id).
   * `title` names a group; ignored for 1:1.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract startChat(params: {
    channelId: string;
    recipientIds: string[];
    text: string;
    title?: string | null;
  }): Promise<{ chatId: string; message: ChatMessage }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getProfile(params: { channelId: string; profileId: string }): Promise<ChatProfile>;

  /**
   * Resolve a free-form typed address (phone for WhatsApp, @username for
   * Instagram) to a provider attendee id usable in `startChat`. Returns null
   * when the address can't be resolved. Default (LinkedIn: closed roster,
   * compose targets contacts) returns null.
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract resolveRecipient(params: { channelId: string; address: string }): Promise<string | null>;
}
```

- [ ] **Step 2: Lint (will fail until index/linkedin updated — expected)**

Run: `pnpm --filter @plotday/unipile lint`
Expected: FAIL — `linkedin.ts`/`index.ts` still reference old type names. Proceed to Task 3 (do not commit yet).

---

### Task 3: Port `libs/unipile/src/linkedin.ts` + `types.ts` + `index.ts` onto the neutral core

**Files:**
- Modify: `libs/unipile/src/linkedin.ts`
- Modify: `libs/unipile/src/types.ts`
- Modify: `libs/unipile/src/index.ts`

- [ ] **Step 1: Rewrite `libs/unipile/src/linkedin.ts`**

```ts
import { UnipileMessaging, type ChatProfile } from "./messaging";

/** LinkedIn connection request (invitation). */
export type LinkedInInvitation = {
  id: string;
  sharedSecret: string;
  inviter: ChatProfile;
  message: string | null;
  sentAt: Date;
};
export type LinkedInInvitationPage = {
  invitations: LinkedInInvitation[];
  nextCursor: string | null;
};
export type LinkedInRelationPage = {
  relations: ChatProfile[];
  nextCursor: string | null;
};

/**
 * LinkedIn messaging tool: the common surface plus LinkedIn-only
 * invitations and 1st-degree relations. Implementation:
 * `workers/api/src/twist/tools/unipile/linkedin.ts`.
 */
export abstract class LinkedInMessaging extends UnipileMessaging {
  static readonly toolId = "LinkedInMessaging";

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage>;

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

- [ ] **Step 2: Update `libs/unipile/src/types.ts`**

This file currently holds BOTH the raw Unipile wire types AND the LinkedIn* Plot-shaped types. Read the current file. **Remove** the Plot-shaped exports that moved to `messaging.ts`/`linkedin.ts` (`LinkedInProfile`, `LinkedInAttachment`, `LinkedInMessageReaction`, `LinkedInMessage`, `LinkedInChat`, `LinkedInChatPage`, `LinkedInMessagePage`, `LinkedInInvitation`, `LinkedInInvitationPage`, `LinkedInRelationPage`). **Keep** the raw Unipile wire types (`UnipileAttendee`, `UnipileChat`, `UnipileMessage`, `UnipileAttachment`, `UnipileMessageReaction`, `UnipileInvitation`, `UnipileRelation`, `Unipile*List`, `UnipileHostedAuthLink`, `UnipileWebhook`, `UnipileWebhookSource`, `UnipileAccount`). If `types.ts` has no raw wire types (they may live in `workers/api/src/twist/tools/unipile/types.ts` instead — check both), leave the raw types where they are and only remove Plot-shaped ones from `libs/unipile`.

> Note: the raw Unipile wire types used by `normalize.ts` live in `workers/api/src/twist/tools/unipile/types.ts` (local `./types`), NOT in `libs/unipile`. Confirm by reading both. `libs/unipile/src/types.ts` holds the Plot-shaped types being moved. After moving, `libs/unipile/src/types.ts` may become empty — if so, delete it and drop its `export * from "./types"` in `index.ts`.

- [ ] **Step 3: Rewrite `libs/unipile/src/index.ts`**

```ts
export * from "./messaging";
export * from "./connector-helpers";
export * from "./linkedin";
export * from "./whatsapp";
export * from "./instagram";
```
(Remove `export * from "./types"` if `types.ts` was deleted. `connector-helpers`, `whatsapp`, `instagram` are created in later tasks — create empty stub files now so the build resolves, or reorder: add these exports as each file is created. For this task, temporarily export only `./messaging` and `./linkedin`; add the rest in their tasks.)

For THIS task, set `index.ts` to:
```ts
export * from "./messaging";
export * from "./linkedin";
```

- [ ] **Step 4: Lint**

Run: `pnpm --filter @plotday/unipile lint`
Expected: PASS (libs/unipile now self-consistent; connector-helpers/whatsapp/instagram not yet referenced).

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/messaging.ts libs/unipile/src/linkedin.ts libs/unipile/src/types.ts libs/unipile/src/index.ts
git commit -m "refactor(unipile): provider-neutral messaging types + abstract UnipileMessaging

Renames LinkedIn* Plot-shaped types to neutral Chat* and extracts the common
messaging surface into an abstract UnipileMessaging tool; LinkedInMessaging now
extends it with invitation/relation methods.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Shared pure connector helpers (`libs/unipile/src/connector-helpers.ts`)

This is the DRY heart: the three connectors share link/note assembly and the chat-sync loop. Logic is ported from `connectors/linkedin/src/linkedin.ts` (`profileToContact`, `buildNoteFromMessage`, `buildReactionsFromMessage`, `build1to1ConversationLink`, `buildGroupLink`, `joinParticipantNames`, `pickDesiredLinkedInReaction`, `senderFallbackContact`) and generalized with a `provider` key.

**Files:**
- Create: `libs/unipile/src/connector-helpers.ts`
- Create: `libs/unipile/src/connector-helpers.test.ts`

- [ ] **Step 1: Write the failing test `libs/unipile/src/connector-helpers.test.ts`**

```ts
import { describe, expect, test } from "vitest";
import {
  profileToContact,
  joinParticipantNames,
  pickDesiredReaction,
  assembleConversationLink,
  assembleGroupLink,
} from "./connector-helpers";
import type { ChatMessage, ChatProfile, ChatThread } from "./messaging";

const prof = (over: Partial<ChatProfile>): ChatProfile => ({
  id: "p1", isSelf: false, name: "Alice", handle: null, subtitle: null,
  email: null, phone: null, pictureUrl: null, profileUrl: null, ...over,
});
const msg = (over: Partial<ChatMessage>): ChatMessage => ({
  id: "m1", chatId: "c1", senderId: "p1", sentByMe: false, eventType: null,
  sentAt: new Date("2026-06-01T00:00:00Z"), text: "hi", attachments: [],
  reactions: [], ...over,
});
const chat = (over: Partial<ChatThread>): ChatThread => ({
  id: "c1", title: null, isGroup: false, participants: [], lastMessagePreview: null,
  lastActivityAt: new Date("2026-06-01T00:00:00Z"), unreadCount: 0, archived: false,
  folder: null, url: null, ...over,
});

describe("profileToContact", () => {
  test("uses email when present", () => {
    const c = profileToContact(prof({ email: "a@x.com", name: "Alice" }), "whatsapp");
    expect(c.email).toBe("a@x.com");
    expect(c.source).toEqual({ accountId: "p1" });
  });
  test("synthesizes provider-scoped fallback email from handle", () => {
    const c = profileToContact(prof({ handle: "alice", email: null }), "instagram");
    expect(c.email).toBe("alice@instagram.invalid");
  });
  test("phone fallback for whatsapp without handle/email", () => {
    const c = profileToContact(prof({ phone: "15551234567", handle: null, email: null }), "whatsapp");
    expect(c.email).toBe("15551234567@whatsapp.invalid");
  });
  test("name-only when nothing addressable", () => {
    const c = profileToContact(prof({ handle: null, email: null, phone: null }), "linkedin");
    expect(c.email).toBeUndefined();
    expect(c.name).toBe("Alice");
  });
});

describe("pickDesiredReaction", () => {
  test("fixed set: first allowed emoji with a reactor", () => {
    expect(pickDesiredReaction({ "❤️": [{ name: "x" }] }, ["👍", "❤️"])).toBe("❤️");
  });
  test("open-unicode: deterministic first key with a reactor", () => {
    expect(pickDesiredReaction({ "🎉": [{ name: "x" }], "🙏": [{ name: "y" }] })).toBe("🙏");
  });
  test("null when no reactors", () => {
    expect(pickDesiredReaction({})).toBeNull();
  });
});

describe("joinParticipantNames", () => {
  test("truncates with +N", () => {
    expect(joinParticipantNames([prof({ name: "A" }), prof({ name: "B" }), prof({ name: "C" })]))
      .toBe("A, B +1");
  });
});

describe("assembleConversationLink", () => {
  test("1:1 is person-keyed and includes secondary chat source", () => {
    const other = prof({ id: "p2", name: "Bob" });
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1", chat: chat({ participants: [prof({ isSelf: true }), other] }),
      messages: [msg({ senderId: "p2" })], initialSync: true,
    });
    expect(link).not.toBeNull();
    expect(link!.source).toBe("whatsapp:person:p2");
    expect(link!.sources).toContain("whatsapp:chat:c1");
    expect(link!.status).toBe("inbox");
    expect(link!.meta).toMatchObject({ syncProvider: "whatsapp", channelId: "acc1", chatId: "c1", profileId: "p2" });
    expect(link!.notes).toHaveLength(1);
  });
  test("returns null when no counterparty", () => {
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1", chat: chat({ participants: [prof({ isSelf: true })] }),
      messages: [], initialSync: true,
    });
    expect(link).toBeNull();
  });
  test("incremental sync omits status", () => {
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1",
      chat: chat({ participants: [prof({ isSelf: true }), prof({ id: "p2" })] }),
      messages: [msg({ senderId: "p2" })], initialSync: false,
    });
    expect(link!.status).toBeUndefined();
  });
});

describe("assembleGroupLink", () => {
  test("chat-keyed, contacts exclude self, title falls back to names", () => {
    const link = assembleGroupLink({
      provider: "instagram", channelId: "acc1",
      chat: chat({ isGroup: true, participants: [prof({ isSelf: true }), prof({ id: "p2", name: "Bob" }), prof({ id: "p3", name: "Cy" })] }),
      messages: [msg({ senderId: "p2" })], initialSync: true,
    });
    expect(link.source).toBe("instagram:chat:c1");
    expect(link.accessContacts).toHaveLength(2);
    expect(link.title).toBe("Bob, Cy");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @plotday/unipile test`
Expected: FAIL — cannot find module `./connector-helpers`.

- [ ] **Step 3: Implement `libs/unipile/src/connector-helpers.ts`**

```ts
import { ActionType } from "@plotday/twister/plot";
import type {
  Action,
  NewActor,
  NewContact,
  NewNote,
  NewReactions,
  Reactions,
} from "@plotday/twister/plot";
import type { NewLinkWithNotes } from "@plotday/twister";

import type {
  ChatAttachment,
  ChatMessage,
  ChatProfile,
  ChatThread,
  UnipileMessaging,
} from "./messaging";

/** Build a Plot contact from a provider profile, keyed on the provider id. */
export function profileToContact(profile: ChatProfile, provider: string): NewContact {
  const source = { accountId: profile.id };
  const avatar = profile.pictureUrl ?? undefined;
  if (profile.email) return { email: profile.email, name: profile.name, avatar, source };
  if (profile.handle) return { email: `${profile.handle}@${provider}.invalid`, name: profile.name, avatar, source };
  if (profile.phone) return { email: `${profile.phone}@${provider}.invalid`, name: profile.name, avatar, source };
  return { name: profile.name, avatar, source };
}

export function senderFallbackContact(msg: ChatMessage, provider: string): NewContact {
  return { name: msg.sentByMe ? "You" : `${titleCase(provider)} user`, source: { accountId: msg.senderId } };
}

function titleCase(s: string): string {
  return s.length ? s[0]!.toUpperCase() + s.slice(1) : s;
}

export function joinParticipantNames(profiles: ChatProfile[]): string {
  if (profiles.length === 0) return "Group";
  if (profiles.length === 1) return profiles[0]!.name;
  if (profiles.length === 2) return `${profiles[0]!.name}, ${profiles[1]!.name}`;
  return `${profiles[0]!.name}, ${profiles[1]!.name} +${profiles.length - 2}`;
}

/**
 * Pick the single emoji to push as the connected account's reaction, given
 * Plot's emoji→reactors map. With `allowed` (fixed-set platforms like
 * LinkedIn) iterate that order; otherwise (open-unicode) iterate the reaction
 * keys in sorted order for determinism. Returns null to signal "clear".
 */
export function pickDesiredReaction(reactions: Reactions, allowed?: readonly string[]): string | null {
  const order = allowed ?? Object.keys(reactions).sort();
  for (const emoji of order) {
    const reactors = reactions[emoji];
    if (reactors && reactors.length > 0) return emoji;
  }
  return null;
}

export function buildReactionsFromMessage(
  msg: ChatMessage,
  chat: ChatThread,
  provider: string
): NewReactions | undefined {
  if (!msg.reactions || msg.reactions.length === 0) return undefined;
  const byEmoji = new Map<string, NewActor[]>();
  for (const r of msg.reactions) {
    const participant = chat.participants.find((p) => p.id === r.senderId);
    const actor: NewActor = participant
      ? profileToContact(participant, provider)
      : { name: `${titleCase(provider)} user`, source: { accountId: r.senderId } };
    const existing = byEmoji.get(r.value);
    if (existing) existing.push(actor);
    else byEmoji.set(r.value, [actor]);
  }
  const out: NewReactions = {};
  for (const [emoji, actors] of byEmoji) out[emoji] = actors;
  return out;
}

export function buildNoteFromMessage(
  msg: ChatMessage,
  chat: ChatThread,
  provider: string,
  threadPersonId?: string
): NewNote {
  const sender = chat.participants.find((p) => p.id === msg.senderId) ?? null;
  const author = sender ? profileToContact(sender, provider) : senderFallbackContact(msg, provider);
  const actions: Action[] = msg.attachments.map((a: ChatAttachment) => ({
    type: ActionType.fileRef as typeof ActionType.fileRef,
    ref: `${msg.id}:${a.id}`,
    fileName: a.name ?? "attachment",
    fileSize: a.byteSize ?? null,
    mimeType: a.contentType ?? "application/octet-stream",
  }));
  const threadSource = threadPersonId ? `${provider}:person:${threadPersonId}` : `${provider}:chat:${chat.id}`;
  const reactions = buildReactionsFromMessage(msg, chat, provider);
  return {
    thread: { source: threadSource },
    key: `message-${msg.id}`,
    created: msg.sentAt,
    content: msg.text,
    contentType: "text",
    author,
    ...(reactions ? { reactions } : {}),
    ...(actions.length > 0 ? { actions } : {}),
  };
}

/** Assemble a 1:1 conversation link (person-keyed) from already-fetched messages. */
export function assembleConversationLink(opts: {
  provider: string;
  channelId: string;
  chat: ChatThread;
  messages: ChatMessage[];
  initialSync: boolean;
  status?: string; // defaults to "inbox" on initial sync
}): NewLinkWithNotes | null {
  const { provider, channelId, chat, messages, initialSync } = opts;
  const other = chat.participants.find((p) => !p.isSelf);
  if (!other) return null;
  const items = messages.filter((m) => m.eventType === null);
  const notes: NewNote[] = items.slice().reverse().map((m) => buildNoteFromMessage(m, chat, provider, other.id));
  const status = opts.status ?? "inbox";
  return {
    source: `${provider}:person:${other.id}`,
    sources: [`${provider}:person:${other.id}`, `${provider}:chat:${chat.id}`],
    type: "conversation",
    ...(initialSync ? { status } : {}),
    title: other.name,
    preview: chat.lastMessagePreview ?? null,
    sourceUrl: chat.url,
    created: chat.lastActivityAt,
    accessContacts: [profileToContact(other, provider)],
    notes,
    meta: { syncProvider: provider, channelId, profileId: other.id, chatId: chat.id },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}

/** Assemble a group/named-group link (chat-keyed) from already-fetched messages. */
export function assembleGroupLink(opts: {
  provider: string;
  channelId: string;
  chat: ChatThread;
  messages: ChatMessage[];
  initialSync: boolean;
}): NewLinkWithNotes {
  const { provider, channelId, chat, messages, initialSync } = opts;
  const items = messages.filter((m) => m.eventType === null);
  const others = chat.participants.filter((p) => !p.isSelf);
  const notes: NewNote[] = items.slice().reverse().map((m) => buildNoteFromMessage(m, chat, provider));
  return {
    source: `${provider}:chat:${chat.id}`,
    sources: [`${provider}:chat:${chat.id}`],
    type: "group",
    ...(initialSync ? { status: "inbox" } : {}),
    title: chat.title ?? joinParticipantNames(others),
    preview: chat.lastMessagePreview ?? null,
    sourceUrl: chat.url,
    created: chat.lastActivityAt,
    accessContacts: others.map((p) => profileToContact(p, provider)),
    notes,
    meta: { syncProvider: provider, channelId, chatId: chat.id },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}

/**
 * Fetch a chat's recent messages via the tool and assemble its link. Used by
 * both backfill and the new-message webhook. `onAttachmentMessage` is called
 * for each message that has attachments so the connector can cache
 * message→channel for downloadAttachment.
 */
export async function buildLinkForChat(opts: {
  tool: UnipileMessaging;
  provider: string;
  channelId: string;
  chat: ChatThread;
  initialSync: boolean;
  since?: Date;
  msgLimit?: number;
  onAttachmentMessage?: (messageId: string) => Promise<void>;
}): Promise<NewLinkWithNotes | null> {
  const { tool, provider, channelId, chat, initialSync, since } = opts;
  const page = await tool.listMessages({
    channelId,
    chatId: chat.id,
    limit: opts.msgLimit ?? 20,
    since: initialSync ? undefined : since,
  });
  const items = page.messages.filter((m) => m.eventType === null);
  if (opts.onAttachmentMessage) {
    for (const m of items) if (m.attachments.length > 0) await opts.onAttachmentMessage(m.id);
  }
  return chat.isGroup
    ? assembleGroupLink({ provider, channelId, chat: { ...chat }, messages: items, initialSync })
    : assembleConversationLink({ provider, channelId, chat, messages: items, initialSync });
}

/**
 * One-time backfill: page through chats and assemble links. Returns the links;
 * the connector saves them via integrations.saveLinks and tracks the
 * high-water timestamp. No recurring scheduling — webhooks drive steady state.
 */
export async function backfillChats(opts: {
  tool: UnipileMessaging;
  provider: string;
  channelId: string;
  listLimit?: number;
  msgLimit?: number;
  onAttachmentMessage?: (messageId: string) => Promise<void>;
}): Promise<{ links: NewLinkWithNotes[]; lastActivityMs: number }> {
  const { tool, provider, channelId } = opts;
  const result = await tool.listChats({ channelId, limit: opts.listLimit ?? 20 });
  const links: NewLinkWithNotes[] = [];
  let lastActivityMs = 0;
  for (const chat of result.chats) {
    const link = await buildLinkForChat({
      tool, provider, channelId, chat, initialSync: true, msgLimit: opts.msgLimit,
      onAttachmentMessage: opts.onAttachmentMessage,
    });
    if (link) links.push(link);
    const t = chat.lastActivityAt.getTime();
    if (t > lastActivityMs) lastActivityMs = t;
  }
  return { links, lastActivityMs };
}
```

> **Note on `pickDesiredReaction` open-unicode order:** `Object.keys(reactions).sort()` is a deterministic stand-in. If the connector knows which emoji the *connected account* reacted with (via `reaction.sentByMe`), prefer that — see Task 9 reaction write-back, which passes the connected user's own emoji when available.

- [ ] **Step 4: Run to verify it passes**

Run: `pnpm --filter @plotday/unipile test`
Expected: PASS (all `connector-helpers.test.ts` cases).

- [ ] **Step 5: Export from index + lint**

Add `export * from "./connector-helpers";` to `libs/unipile/src/index.ts`.
Run: `pnpm --filter @plotday/unipile lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add libs/unipile/src/connector-helpers.ts libs/unipile/src/connector-helpers.test.ts libs/unipile/src/index.ts
git commit -m "feat(unipile): shared pure connector helpers for link/note assembly + backfill

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Concrete `UnipileMessagingTool` base + `UnipileClient.startChat` fix

**Files:**
- Create: `workers/api/src/twist/tools/unipile/messaging.ts`
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Modify: `workers/api/src/twist/tools/unipile/normalize.ts`
- Create: `workers/api/src/twist/tools/unipile/messaging.test.ts`

- [ ] **Step 1: Fix `UnipileClient.startChat` (failing test first)**

Add to `workers/api/src/twist/tools/unipile/client.test.ts` (read existing file for the mock/fetch harness it uses; follow its pattern). Test that `startChat` POSTs `/chats` as multipart form with `account_id`, `attendees_ids`, `text`, and optional `title`:

```ts
test("startChat posts /chats with attendees and optional title", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const client = makeClient(async (url, init) => {
    calls.push({ url, init });
    return new Response(JSON.stringify({ id: "msg1", chat_id: "chat1" }), { status: 200 });
  });
  await client.startChat({ accountId: "acc1", attendeeProviderIds: ["a", "b"], text: "hi", title: "Crew" });
  expect(calls[0]!.url).toMatch(/\/chats$/);
  expect(calls[0]!.init.method).toBe("POST");
  const form = calls[0]!.init.body as FormData;
  expect(form.get("account_id")).toBe("acc1");
  expect(form.getAll("attendees_ids")).toEqual(["a", "b"]);
  expect(form.get("text")).toBe("hi");
  expect(form.get("title")).toBe("Crew");
});
```
(If `client.test.ts`'s harness can't inject `fetch`, add a constructor-injectable `fetchImpl` to `UnipileClient` defaulting to global `fetch`, and use it in `request`/`requestFormData`/`downloadAttachmentRaw`/`startChat`. Keep that refactor minimal.)

Run: `timeout 120 pnpm --filter @plotday/api test -- client.test.ts`
Expected: FAIL.

- [ ] **Step 2: Rewrite `UnipileClient.startChat`**

Replace the current `startChat` (the `POST /messages` TODO version) with multipart `POST /chats`:

```ts
/**
 * Start a new chat (1:1 or group) and send the first message. Unipile's
 * `POST /chats` (multipart) creates the chat if needed and returns the first
 * message. For 1:1 it reuses an existing conversation.
 *
 * @param attendeeProviderIds Provider attendee ids: LinkedIn URN, WhatsApp JID
 *   (`<digits>@s.whatsapp.net`), or Instagram user id.
 * @param title Optional group name (ignored for 1:1).
 */
async startChat(input: {
  accountId: string;
  attendeeProviderIds: string[];
  text: string;
  title?: string | null;
}): Promise<UnipileMessage> {
  const form = new FormData();
  form.append("account_id", input.accountId);
  for (const id of input.attendeeProviderIds) form.append("attendees_ids", id);
  form.append("text", input.text);
  if (input.title) form.append("title", input.title);
  return this.requestFormData<UnipileMessage>("/chats", form);
}
```

> The `POST /chats` response shape may be `{ object, chat_id, message_id }` rather than a full `UnipileMessage`. LIVE-CONFIRM (§13): if so, after the POST, `getChat`/`listMessages` to obtain the first `UnipileMessage`, or map the returned ids into a minimal `UnipileMessage`. Keep `normalizeMessage` tolerant of missing fields.

- [ ] **Step 3: Add `resolveUser` + `listChats` folder passthrough to `UnipileClient`**

```ts
/**
 * Resolve a provider identifier (username, public id, or phone) to an
 * attendee. Used by compose to turn a typed @username / phone into a
 * provider attendee id. Unipile: GET /users/{identifier}?account_id=...
 * LIVE-CONFIRM (§13): exact path/param for Instagram username resolution.
 */
getUser(input: { accountId: string; identifier: string }): Promise<UnipileAttendee> {
  return this.get<UnipileAttendee>(`/users/${encodeURIComponent(input.identifier)}`, {
    account_id: input.accountId,
  });
}
```
And extend `listChats` to pass an optional `folder` query param:
```ts
listChats(input: {
  accountId: string; cursor?: string | null; limit?: number; folder?: string | null;
}): Promise<UnipileChatList> {
  return this.get<UnipileChatList>("/chats", {
    account_id: input.accountId,
    ...(input.cursor ? { cursor: input.cursor } : {}),
    ...(input.limit ? { limit: String(input.limit) } : {}),
    ...(input.folder ? { folder: input.folder } : {}),
  });
}
```

- [ ] **Step 4: Update `normalize.ts` to return neutral types**

Read the current `normalize.ts`. Change all return types `LinkedInProfile→ChatProfile`, `LinkedInChat→ChatThread`, `LinkedInMessage→ChatMessage`, `LinkedInMessageReaction→ChatMessageReaction`, `LinkedInAttachment→ChatAttachment` (import from `@plotday/unipile`). Map the renamed fields:
- `normalizeProfile`: `fullName→name`, `publicIdentifier→handle`, `headline→subtitle`, `url→profileUrl`, add `phone: att.specifics?.phone ?? null` (LIVE-CONFIRM the WhatsApp phone field name).
- `normalizeChat`: add `folder: chat.folder ?? null` (add `folder?: string` to `UnipileChat` wire type in the workers-side `types.ts`); keep `lastMessagePreview: null`. The LinkedIn-specific `url` (`/messaging/thread/...`) stays here for now — it is correct for LinkedIn and harmless; per-provider URL differences are handled in Task 12/16 if needed.
- `normalizeInvitation`/`normalizeRelation`: update the inline profile object literals to the neutral `ChatProfile` field names (`fullName→name`, `publicIdentifier→handle`, `headline→subtitle`, `url→profileUrl`, `phone: null`). Keep `normalizeRelation` returning `ChatProfile`.

Update `normalize.test.ts` field expectations accordingly (rename in assertions). Run:
`timeout 120 pnpm --filter @plotday/api test -- normalize.test.ts` → Expected: PASS.

- [ ] **Step 5: Write `workers/api/src/twist/tools/unipile/messaging.ts` (concrete base)**

Port the bodies of the common methods from the current `workers/api/src/twist/tools/unipile/linkedin.ts` (`listChats`, `getChat`, `listMessages`, `sendMessage`, `downloadAttachment`, `setChatRead`, `setMessageReaction`, `clearMessageReaction`, `startChat`, `getProfile`, `assertAccount`), changing the hardcoded `"linkedin"` in `assertAccount`'s keys to `this.provider`:

```ts
import type { Kysely } from "kysely";
import type {
  ChatProfile, ChatThread, ChatThreadPage, ChatMessage, ChatMessagePage,
  UnipileMessaging as IUnipileMessaging,
} from "@plotday/unipile";
import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import type { StoredTokenData } from "../../../provider";
import { Store } from "../store";
import { Tool } from "../tool";
import { UnipileClient } from "./client";
import { normalizeChat, normalizeMessage, normalizeProfile } from "./normalize";

/**
 * Concrete base for all Unipile messaging tools. Routes through UnipileClient
 * and enforces auth per `provider`. Provider subclasses set `provider` and add
 * provider-specific methods (LinkedIn invitations, IG message requests).
 */
export abstract class UnipileMessagingTool extends Tool implements IUnipileMessaging {
  protected abstract readonly provider: string;
  protected store: Store;
  protected client: UnipileClient;

  constructor(
    protected options: { env: Bindings; db: Kysely<DB>; twistInstanceId: string; path: string[] }
  ) {
    super();
    this.store = new Store({
      path: options.path,
      storage: options.env.STORAGE,
      twistInstanceId: options.twistInstanceId,
    });
    this.client = new UnipileClient(options.env);
  }

  async listChats(params: { channelId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatThreadPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listChats({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    const chats: ChatThread[] = [];
    for (const raw of result.items) {
      const attendees = await this.client.listChatAttendees({ chatId: raw.id });
      const chat = normalizeChat(raw, attendees.items);
      if (params.since && chat.lastActivityAt < params.since) continue;
      chats.push(chat);
    }
    return { chats, nextCursor: result.cursor };
  }

  async getChat(params: { channelId: string; chatId: string }): Promise<ChatThread> {
    await this.assertAccount(params.channelId);
    const [raw, attendees] = await Promise.all([
      this.client.getChat({ chatId: params.chatId }),
      this.client.listChatAttendees({ chatId: params.chatId }),
    ]);
    return normalizeChat(raw, attendees.items);
  }

  async listMessages(params: { channelId: string; chatId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatMessagePage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listMessages({ chatId: params.chatId, cursor: params.cursor ?? null, limit: params.limit });
    const messages = result.items.map(normalizeMessage).filter((m) => !params.since || m.sentAt >= params.since);
    return { messages, nextCursor: result.cursor };
  }

  async sendMessage(params: { channelId: string; chatId: string; text: string; attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> }): Promise<ChatMessage> {
    await this.assertAccount(params.channelId);
    const raw = params.attachments && params.attachments.length > 0
      ? await this.client.sendMessageMultipart({ chatId: params.chatId, text: params.text, attachments: params.attachments })
      : await this.client.sendMessage({ chatId: params.chatId, text: params.text });
    return normalizeMessage(raw);
  }

  async downloadAttachment(params: { channelId: string; messageId: string; attachmentId: string }): Promise<{ body: ReadableStream; mimeType: string; fileName?: string }> {
    await this.assertAccount(params.channelId);
    const response = await this.client.downloadAttachmentRaw({ messageId: params.messageId, attachmentId: params.attachmentId });
    const contentType = response.headers.get("content-type") ?? "application/octet-stream";
    const mimeType = contentType.split(";")[0]?.trim() ?? "application/octet-stream";
    const disposition = response.headers.get("content-disposition") ?? "";
    const m = disposition.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)["']?/i);
    const fileName = m?.[1] ? decodeURIComponent(m[1].trim()) : undefined;
    return { body: response.body as ReadableStream, mimeType, fileName };
  }

  async setChatRead(params: { channelId: string; chatId: string; read: boolean }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.setChatRead({ chatId: params.chatId, read: params.read });
  }

  async setMessageReaction(params: { channelId: string; messageId: string; reaction: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.addMessageReaction({ messageId: params.messageId, reaction: params.reaction });
  }

  async clearMessageReaction(params: { channelId: string; messageId: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.removeMessageReaction({ messageId: params.messageId });
  }

  async startChat(params: { channelId: string; recipientIds: string[]; text: string; title?: string | null }): Promise<{ chatId: string; message: ChatMessage }> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.startChat({ accountId: params.channelId, attendeeProviderIds: params.recipientIds, text: params.text, title: params.title ?? null });
    const message = normalizeMessage(raw);
    return { chatId: message.chatId, message };
  }

  async getProfile(params: { channelId: string; profileId: string }): Promise<ChatProfile> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.getAttendee({ providerId: params.profileId });
    return normalizeProfile(raw);
  }

  // Default: free-form recipients unsupported (LinkedIn closed roster). Overridden by WhatsApp/Instagram.
  async resolveRecipient(_params: { channelId: string; address: string }): Promise<string | null> {
    return null;
  }

  protected async assertAccount(channelId: string): Promise<void> {
    const cfg = await this.store.get<{ enabled?: boolean; enabledBy?: string }>(`channel_config:${this.provider}:${channelId}`);
    if (!cfg?.enabledBy) throw new Error(`${this.provider} channel ${channelId} is not enabled by any actor`);
    const token = await this.store.get<StoredTokenData>(`auth_token:${this.provider}:${cfg.enabledBy}`);
    if (!token?.access_token) throw new Error(`${this.provider} channel ${channelId} has no stored credentials — reconnect`);
  }
}
```

- [ ] **Step 6: Write `messaging.test.ts` (assertAccount provider keying)**

```ts
import { describe, expect, test, vi } from "vitest";
import { UnipileMessagingTool } from "./messaging";

class TestTool extends UnipileMessagingTool {
  protected readonly provider = "testprov";
  // expose protected for the test
  public assert(channelId: string) { return this.assertAccount(channelId); }
}

function make(storeGet: (k: string) => unknown) {
  const t = Object.create(TestTool.prototype) as TestTool & { store: any; client: any };
  t.store = { get: vi.fn(async (k: string) => storeGet(k)) };
  return t;
}

describe("assertAccount provider keying", () => {
  test("reads channel_config and auth_token under this.provider", async () => {
    const seen: string[] = [];
    const t = make((k) => { seen.push(k); if (k.startsWith("channel_config:")) return { enabledBy: "actor1" }; if (k.startsWith("auth_token:")) return { access_token: "tok" }; return null; });
    await (t as any).assert("acc1");
    expect(seen).toContain("channel_config:testprov:acc1");
    expect(seen).toContain("auth_token:testprov:actor1");
  });
  test("throws when not enabled", async () => {
    const t = make(() => null);
    await expect((t as any).assert("acc1")).rejects.toThrow(/not enabled/);
  });
});
```

Run: `timeout 120 pnpm --filter @plotday/api test -- messaging.test.ts`
Expected: PASS.

- [ ] **Step 7: Lint workers/api**

Run: `timeout 300 pnpm --filter @plotday/api lint`
Expected: FAIL — concrete `linkedin.ts` still implements the old interface/types. Proceed to Task 6 before committing this phase.

---

### Task 6: Refactor concrete `linkedin.ts` onto `UnipileMessagingTool`

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/linkedin.ts`

- [ ] **Step 1: Rewrite to extend the base**

Reduce `LinkedInMessaging` to: extend `UnipileMessagingTool`, set `provider = "linkedin"`, and keep ONLY the LinkedIn-specific methods (`listReceivedInvitations`, `listRelations`, `acceptInvitation`, `ignoreInvitation`) plus the `normalizeProfile` re-export. Delete the now-inherited common methods.

```ts
import type {
  LinkedInInvitationPage, LinkedInRelationPage, LinkedInMessaging as ILinkedInMessaging,
} from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";
import { normalizeInvitation, normalizeProfile, normalizeRelation } from "./normalize";

export class LinkedInMessaging extends UnipileMessagingTool implements ILinkedInMessaging {
  protected readonly provider = "linkedin";

  async listReceivedInvitations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInInvitationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listReceivedInvitations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    return { invitations: result.items.map(normalizeInvitation), nextCursor: result.cursor };
  }

  async listRelations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInRelationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listRelations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    return { relations: result.items.map(normalizeRelation), nextCursor: result.cursor };
  }

  async acceptInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.acceptInvitation({ invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }

  async ignoreInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.ignoreInvitation({ invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }
}

export { normalizeProfile };
```

- [ ] **Step 2: Lint workers/api**

Run: `timeout 300 pnpm --filter @plotday/api lint`
Expected: PASS (factory still imports `LinkedInMessaging` from `./unipile/linkedin`; class name unchanged).

- [ ] **Step 3: Run unit tests**

Run: `timeout 180 pnpm --filter @plotday/api test -- unipile`
Expected: PASS (normalize, client, messaging tests).

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/tools/unipile/
git commit -m "refactor(api): UnipileMessagingTool base + startChat /chats fix; LinkedIn onto base

Extracts common Unipile messaging methods into a provider-parameterized base
(assertAccount keyed on this.provider), fixes startChat to POST /chats
(multipart, attendees_ids + optional title), and reduces LinkedInMessaging to
its invitation/relation extras. normalize returns neutral Chat* types.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Refactor the LinkedIn connector onto shared helpers + collapse to one composable type

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

Read the current connector in full first. The refactor: (a) one `conversation` link type (composable) replacing `conversation`+`group`+`dm`; (b) use shared `assembleConversationLink`/`assembleGroupLink`/`buildLinkForChat`/`backfillChats`/`profileToContact`/`pickDesiredReaction` from `@plotday/unipile`; (c) drop the recurring `syncBatch` poll and the relations *refresh* loop; (d) person-keyed compose.

- [ ] **Step 1: Replace link types + reactionCapabilities**

```ts
const TYPE_CONVERSATION = "conversation";
const TYPE_GROUP = "group";

const STATUS_PENDING = "pending";
const STATUS_INBOX = "inbox";
const STATUS_ARCHIVED = "archived";
const STATUS_IGNORED = "ignored";

const PROVIDER_KEY = "linkedin";
const LINKEDIN_REACTIONS = ["👍", "❤️", "👏", "💡", "😂", "😮", "😢"] as const;

readonly reactionCapabilities: ReactionCapabilities = { mode: "fixed", allowed: LINKEDIN_REACTIONS };

readonly linkTypes = [
  {
    type: TYPE_CONVERSATION,
    label: "LinkedIn conversation",
    sharingModel: "thread" as const,
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
    compose: { targets: "contacts" as const, status: STATUS_INBOX },
    statuses: [
      { status: STATUS_PENDING,  label: "Pending" },
      { status: STATUS_INBOX,    label: "Connected" },
      { status: STATUS_ARCHIVED, label: "Archived", done: true },
      { status: STATUS_IGNORED,  label: "Ignored",  done: true },
    ],
  },
  {
    type: TYPE_GROUP,
    label: "LinkedIn group",
    sharingModel: "thread" as const,
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
    statuses: [
      { status: STATUS_INBOX,    label: "Inbox" },
      { status: STATUS_ARCHIVED, label: "Archived", done: true },
    ],
  },
];
```

> Keep a separate `group` type for LinkedIn even though spec §6a says LinkedIn has "1 type"? No — spec §6a says LinkedIn collapses to **one** `conversation` covering 1:1 AND multi-person. So **remove `TYPE_GROUP` for LinkedIn**: a multi-person LinkedIn chat is just a `conversation` link whose `accessContacts` has >1 entry. Use `assembleGroupLink` only to set the title/contacts but with `type: "conversation"`. To keep the shared helper generic, pass an optional `type` override:

Update `assembleGroupLink`/`assembleConversationLink` calls: LinkedIn always uses `type: "conversation"`. Add an optional `type?: string` param to both helpers in `connector-helpers.ts` (default `"conversation"` / `"group"`) so LinkedIn can force `"conversation"` for groups. (Add this param + a test case in Task 4 if not already; if Task 4 is committed, make the small edit here and extend its test.)

So LinkedIn's final `linkTypes` is **just** the single `conversation` entry above (delete the `group` entry).

- [ ] **Step 2: Rewrite `build()` (unchanged tools) and `onChannelEnabled` (no poll, keep one-time relations backfill)**

Port `onChannelEnabled` to: store webhook callback FIRST, then run ONE backfill task (chats + invitations) and ONE relations backfill task. Remove the 30-minute reschedule at the end of `syncBatch`. Keep `syncRelationsPage` for the one-time crawl but **remove** the `refreshRelationsList` reschedule (when `nextCursor===null`, stop — do not schedule a refresh).

`syncBatch` (renamed conceptually to a one-shot backfill) becomes:
```ts
async backfill(channelId: string): Promise<void> {
  // invitations first so a follow-up chat sync converges on the same person-keyed link
  const inv = await this.tools.linkedin.listReceivedInvitations({ channelId, limit: 20 });
  const invLinks = inv.invitations.map((i) => buildInvitationLink(channelId, i, true));
  if (invLinks.length) await this.tools.integrations.saveLinks(invLinks);

  const { links } = await backfillChats({
    tool: this.tools.linkedin, provider: PROVIDER_KEY, channelId,
    onAttachmentMessage: (id) => this.set(`linkedin:msg-channel:${id}`, channelId),
  });
  if (links.length) await this.tools.integrations.saveLinks(links);
  await this.tools.integrations.channelSyncCompleted(channelId);
}
```
`onWebhookEvent` `message.received` uses `buildLinkForChat` (initialSync=false). Keep `invitation.received` and `relation.new` handlers.

- [ ] **Step 3: Rewrite `onCreateLink` (person-keyed, one type)**

```ts
override async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
  if (draft.type !== TYPE_CONVERSATION) return null;
  const recipients = draft.recipients ?? [];
  if (recipients.length === 0) { console.error("[linkedin] onCreateLink: no recipients resolved"); return null; }
  const recipientIds = recipients.map((r) => r.externalAccountId);
  const body = (draft.noteContent ?? draft.title ?? "").trim();
  if (!body) { console.error("[linkedin] onCreateLink: empty body"); return null; }
  const { chatId, message } = await this.tools.linkedin.startChat({ channelId: draft.channelId, recipientIds, text: body });
  const isGroup = recipientIds.length > 1;
  return {
    source: isGroup ? `linkedin:chat:${chatId}` : `linkedin:person:${recipientIds[0]}`,
    sources: isGroup ? [`linkedin:chat:${chatId}`] : [`linkedin:person:${recipientIds[0]}`, `linkedin:chat:${chatId}`],
    type: TYPE_CONVERSATION,
    status: STATUS_INBOX,
    title: draft.title,
    created: message.sentAt,
    channelId: draft.channelId,
    meta: { syncProvider: PROVIDER_KEY, channelId: draft.channelId, chatId, ...(isGroup ? {} : { profileId: recipientIds[0] }) },
  } satisfies NewLinkWithNotes;
}
```

- [ ] **Step 4: Rewrite `onNoteUpdated` reaction write-back using shared `pickDesiredReaction`**

Replace `pickDesiredLinkedInReaction(note.reactions)` with `pickDesiredReaction(note.reactions ?? {}, LINKEDIN_REACTIONS)`. Keep the `reaction_sent:` state + clear logic identical.

- [ ] **Step 5: Keep `onNoteCreated`, `onLinkUpdated`, `onThreadRead`, `downloadAttachment` behavior**

Port as-is, swapping local `build*`/`profileToContact` for the shared imports and `this.tools.linkedin` calls. `buildInvitationLink` stays local to the LinkedIn connector (LinkedIn-specific), but its profile→contact uses the shared `profileToContact(p, "linkedin")`, and it builds a `type: TYPE_CONVERSATION` link (person-keyed, status pending on initial).

- [ ] **Step 6: Delete dead local helpers** now provided by `@plotday/unipile` (`profileToContact`, `buildNoteFromMessage`, `buildReactionsFromMessage`, `joinParticipantNames`, `pickDesiredLinkedInReaction`, `senderFallbackContact`, the two `build*ConversationLink`/`buildGroupLink` private methods — replaced by shared `buildLinkForChat`/`assemble*`). Keep `buildInvitationLink` (LinkedIn-specific) and the relations crawl.

- [ ] **Step 7: Lint the connector**

Run: `pnpm --filter @plotday/connector-linkedin lint`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts libs/unipile/src/connector-helpers.ts libs/unipile/src/connector-helpers.test.ts
git commit -m "refactor(linkedin): single composable conversation type on shared core; drop poll

Collapses conversation+group+dm into one composable conversation type
(pending=invitation), routes sync/compose through shared @plotday/unipile
helpers, makes compose person-keyed (fixes duplicate-thread bug), and removes
the 30-min poll + relations refresh loop (webhook + one-time backfill only).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Reaction-clear endpoint (§13) + phase-1 green gate

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`

- [ ] **Step 1: Implement the best-known clear path with a tolerant fallback**

Keep `removeMessageReaction` but try the documented clear first (empty-value POST), then DELETE, swallowing 404/405:
```ts
async removeMessageReaction(input: { messageId: string }): Promise<void> {
  // LIVE-CONFIRM (§13): preferred clear is POST reactions with empty value;
  // some providers only honor DELETE. Try POST-empty, fall back to DELETE,
  // swallow 404/405 so an unsupported clear doesn't break note write-back.
  try {
    await this.post<unknown>(`/messages/${encodeURIComponent(input.messageId)}/reactions`, { reaction: "" });
    return;
  } catch (e) {
    if (!(e instanceof UnipileApiError) || (e.status !== 400 && e.status !== 404 && e.status !== 405)) throw e;
  }
  try {
    await this.request(`/messages/${encodeURIComponent(input.messageId)}/reactions`, { method: "DELETE" });
  } catch (e) {
    if (e instanceof UnipileApiError && (e.status === 404 || e.status === 405)) return;
    throw e;
  }
}
```

- [ ] **Step 2: Full phase-1 gate**

Run:
```bash
pnpm --filter @plotday/unipile lint && pnpm --filter @plotday/unipile test
pnpm --filter @plotday/connector-linkedin lint
timeout 300 pnpm --filter @plotday/api lint
timeout 180 pnpm --filter @plotday/api test -- unipile
```
Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/tools/unipile/client.ts
git commit -m "fix(unipile): clear message reaction via POST-empty then DELETE fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase 2 — Server provider wiring + reauth fix

### Task 9: `PROVIDER_CONFIGS` entries + reauth provider derivation

**Files:**
- Modify: `workers/api/src/provider.ts`
- Modify: `workers/api/src/app/hook-messaging.ts`

- [ ] **Step 1: Add WhatsApp + Instagram to `PROVIDER_CONFIGS`**

Read the `["linkedin" as AuthProvider]` entry in `provider.ts` and add two siblings, mirroring its `authMode: "hosted"` + label extractor:
```ts
["whatsapp" as AuthProvider]: {
  name: "WhatsApp",
  authMode: "hosted",
  extractAccountLabel: (d: unknown) => {
    const h = d as HostedAccountProviderData;
    return h.fullName || h.email || null;
  },
} as ProviderConfig,
["instagram" as AuthProvider]: {
  name: "Instagram",
  authMode: "hosted",
  extractAccountLabel: (d: unknown) => {
    const h = d as HostedAccountProviderData;
    return h.fullName || h.email || null;
  },
} as ProviderConfig,
```

- [ ] **Step 2: Failing test for reauth provider derivation**

In `workers/api/src/app/hook-messaging.test.ts` (create if absent; if the file would require the full worker harness, instead extract the lookup into a small pure helper `resolveConnectionByAccount(db, accountId)` and unit-test that the UPDATE is not constrained to `"linkedin"`). Minimum assertion: the needs-reauth update no longer filters `provider = "linkedin"`.

- [ ] **Step 3: Fix `handleAccountNeedsReauth`**

Remove both `.where(... "provider", "=", "linkedin")` constraints. Select the provider from the joined `twist_instance_connection` row (by `account_id`/`channel_id`) and stamp `needs_reauth_at` for that connection regardless of provider:
```ts
const row = await db
  .selectFrom("channel")
  .innerJoin("twist_instance_connection", "twist_instance_connection.twist_instance_id", "channel.twist_instance_id")
  .select(["channel.twist_instance_id", "twist_instance_connection.user_id", "twist_instance_connection.provider"])
  .where("channel.channel_id", "=", accountId)
  .executeTakeFirst();
if (!row) { /* unchanged warn + return */ }
const result = await db
  .updateTable("twist_instance_connection")
  .set({ needs_reauth_at: now, recovery_pending: true })
  .where("twist_instance_id", "=", row.twist_instance_id)
  .where("user_id", "=", row.user_id)
  .where("provider", "=", row.provider)
  .where("needs_reauth_at", "is", null)
  .executeTakeFirst();
```
Also change `handleAccountConnected`'s `accountType` default away from `"LINKEDIN"` — use `(event.provider as string) ?? null` and let the auth bridge derive from stored state (the `account.connected` path already pairs by `state`).

- [ ] **Step 4: Lint + commit**

Run: `timeout 300 pnpm --filter @plotday/api lint` → PASS.
```bash
git add workers/api/src/provider.ts workers/api/src/app/hook-messaging.ts
git commit -m "feat(api): whatsapp/instagram provider configs; derive reauth provider from channel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase 3 — WhatsApp connector

### Task 10: WhatsApp messaging tool (abstract + concrete) + phone resolution + factory

**Files:**
- Create: `libs/unipile/src/whatsapp.ts`
- Create: `workers/api/src/twist/tools/unipile/whatsapp.ts`
- Create: `workers/api/src/twist/tools/unipile/whatsapp.test.ts`
- Modify: `libs/unipile/src/index.ts`
- Modify: `workers/api/src/twist/tools/factory.ts`

- [ ] **Step 1: Abstract `libs/unipile/src/whatsapp.ts`**

```ts
import { UnipileMessaging } from "./messaging";

/** WhatsApp messaging tool. Common surface only; resolveRecipient maps a phone
 * number to a WhatsApp JID. Impl: workers/api/.../unipile/whatsapp.ts. */
export abstract class WhatsAppMessaging extends UnipileMessaging {
  static readonly toolId = "WhatsAppMessaging";
}
```
Add `export * from "./whatsapp";` to `libs/unipile/src/index.ts`.

- [ ] **Step 2: Failing test for phone→JID in `whatsapp.test.ts`**

```ts
import { describe, expect, test } from "vitest";
import { phoneToJid } from "./whatsapp";

describe("phoneToJid", () => {
  test("strips non-digits and appends domain", () => {
    expect(phoneToJid("+1 (555) 123-4567")).toBe("15551234567@s.whatsapp.net");
  });
  test("passes through an existing JID", () => {
    expect(phoneToJid("15551234567@s.whatsapp.net")).toBe("15551234567@s.whatsapp.net");
  });
  test("returns null for empty/garbage", () => {
    expect(phoneToJid("abc")).toBeNull();
  });
});
```
Run: `timeout 120 pnpm --filter @plotday/api test -- whatsapp.test.ts` → FAIL.

- [ ] **Step 3: Concrete `workers/api/src/twist/tools/unipile/whatsapp.ts`**

```ts
import type { WhatsAppMessaging as IWhatsAppMessaging } from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";

/** Convert a phone number to a WhatsApp JID. Returns null when no digits.
 * LIVE-CONFIRM (§13): whether Unipile accepts the JID directly in attendees_ids. */
export function phoneToJid(input: string): string | null {
  if (/@s\.whatsapp\.net$/.test(input.trim())) return input.trim();
  const digits = input.replace(/\D/g, "");
  if (digits.length < 5) return null;
  return `${digits}@s.whatsapp.net`;
}

export class WhatsAppMessaging extends UnipileMessagingTool implements IWhatsAppMessaging {
  protected readonly provider = "whatsapp";

  override async resolveRecipient(params: { channelId: string; address: string }): Promise<string | null> {
    await this.assertAccount(params.channelId);
    return phoneToJid(params.address);
  }
}
```

Run: `timeout 120 pnpm --filter @plotday/api test -- whatsapp.test.ts` → PASS.

- [ ] **Step 4: Register in `factory.ts`**

Add `import { WhatsAppMessaging } from "./unipile/whatsapp";`, add to `getToolClass`'s return union + `case "WhatsAppMessaging": return WhatsAppMessaging;`, and to `createTool`:
```ts
case "WhatsAppMessaging":
  return new WhatsAppMessaging({ env, db, twistInstanceId, path });
```

- [ ] **Step 5: Lint + commit**

Run: `pnpm --filter @plotday/unipile lint && pnpm --filter @plotday/unipile test && timeout 300 pnpm --filter @plotday/api lint`
```bash
git add libs/unipile/src/whatsapp.ts libs/unipile/src/index.ts workers/api/src/twist/tools/unipile/whatsapp.ts workers/api/src/twist/tools/unipile/whatsapp.test.ts workers/api/src/twist/tools/factory.ts
git commit -m "feat(unipile): WhatsApp messaging tool + phone→JID recipient resolution

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: WhatsApp connector package

**Files:**
- Create: `connectors/whatsapp/package.json`
- Create: `connectors/whatsapp/tsconfig.json`
- Create: `connectors/whatsapp/src/index.ts`
- Create: `connectors/whatsapp/src/whatsapp.ts`

- [ ] **Step 1: `package.json`** (mirror `connectors/linkedin/package.json`; new `plotTwistId` UUID)

Generate a UUID: `node -e "console.log(crypto.randomUUID())"`. Then:
```json
{
  "name": "@plotday/connector-whatsapp",
  "plotTwistId": "<GENERATED-UUID>",
  "displayName": "WhatsApp",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./dist/index.js",
  "exports": { ".": { "@plotday/connector": "./src/index.ts", "types": "./dist/index.d.ts", "default": "./dist/index.js" } },
  "scripts": { "build": "tsc", "clean": "rm -rf dist", "deploy": "plot deploy", "lint": "tsc --noEmit" },
  "dependencies": { "@plotday/twister": "workspace:*", "@plotday/unipile": "workspace:*" },
  "devDependencies": { "@plotday/tsconfig": "workspace:*", "typescript": "^5.9.3" }
}
```

- [ ] **Step 2: `tsconfig.json`** (copy `connectors/linkedin/tsconfig.json` verbatim)

```json
{ "extends": "@plotday/twister/tsconfig.base.json", "compilerOptions": { "outDir": "./dist" }, "include": ["src/**/*.ts"] }
```

- [ ] **Step 3: `src/index.ts`**

```ts
export { WhatsApp } from "./whatsapp";
export { WhatsApp as default } from "./whatsapp";
```

- [ ] **Step 4: `src/whatsapp.ts`**

Mirror the refactored `connectors/linkedin/src/linkedin.ts` minus invitations/relations. Two link types: composable `conversation` (1:1) and reply-only `group`. `provider = "whatsapp"`; `reactionCapabilities = { mode: "open-unicode", customEmoji: "none" }`. `build()` requests `WhatsAppMessaging` instead of `LinkedInMessaging`. Webhook handler only handles `message.received`. Compose resolves free-form addresses via `resolveRecipient`.

```ts
import {
  Connector, type CreateLinkDraft, type Link, type NewLinkWithNotes,
  type NoteWriteBackResult, type ReactionCapabilities, type ToolBuilder,
} from "@plotday/twister";
import type { Action, Actor, Note, Thread } from "@plotday/twister/plot";
import { ActionType } from "@plotday/twister/plot";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Files } from "@plotday/twister/tools/files";
import { type AuthToken, type Authorization, type Channel, Integrations } from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { WhatsAppMessaging, backfillChats, buildLinkForChat, pickDesiredReaction } from "@plotday/unipile";

const TYPE_CONVERSATION = "conversation";
const TYPE_GROUP = "group";
const STATUS_INBOX = "inbox";
const STATUS_ARCHIVED = "archived";
const PROVIDER_KEY = "whatsapp";
const WHATSAPP_PROVIDER = "whatsapp" as any; // AuthProvider — runtime string

export class WhatsApp extends Connector<WhatsApp> {
  static readonly PROVIDER = WHATSAPP_PROVIDER;
  static readonly SCOPES: string[] = [];
  static readonly handleReplies = true;

  readonly provider = WHATSAPP_PROVIDER;
  readonly scopes = WhatsApp.SCOPES;
  readonly singleChannel = true;
  readonly reactionCapabilities: ReactionCapabilities = { mode: "open-unicode", customEmoji: "none" };
  readonly linkTypes = [
    {
      type: TYPE_CONVERSATION, label: "WhatsApp chat", sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/whatsapp-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/whatsapp.svg",
      compose: { targets: "addresses" as const, status: STATUS_INBOX },
      statuses: [
        { status: STATUS_INBOX, label: "Inbox" },
        { status: STATUS_ARCHIVED, label: "Archived", done: true },
      ],
    },
    {
      type: TYPE_GROUP, label: "WhatsApp group", sharingModel: "thread" as const,
      logo: "https://api.iconify.design/logos/whatsapp-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/whatsapp.svg",
      statuses: [
        { status: STATUS_INBOX, label: "Inbox" },
        { status: STATUS_ARCHIVED, label: "Archived", done: true },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      whatsapp: build(WhatsAppMessaging),
      network: build(Network, { urls: [] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      files: build(Files),
    };
  }

  override async getAccountName(auth: Authorization | null, _t: AuthToken | null): Promise<string | null> {
    return auth?.actor.name ?? null;
  }

  async getChannels(auth: Authorization | null, token: AuthToken | null): Promise<Channel[]> {
    if (!token?.token) return [];
    return [{ id: token.token, title: auth?.actor.name ?? "WhatsApp" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    const cb = await this.tools.callbacks.createFromParent(this.onWebhookEvent, channel.id);
    await this.set(`webhook_callback_${channel.id}`, cb);
    const task = await this.callback(this.backfill, channel.id);
    await this.runTask(task);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`webhook_callback_${channel.id}`);
  }

  async backfill(channelId: string): Promise<void> {
    const { links } = await backfillChats({
      tool: this.tools.whatsapp, provider: PROVIDER_KEY, channelId,
      onAttachmentMessage: (id) => this.set(`whatsapp:msg-channel:${id}`, channelId),
    });
    if (links.length) await this.tools.integrations.saveLinks(links);
    await this.tools.integrations.channelSyncCompleted(channelId);
  }

  async onWebhookEvent(event: { kind: "message.received"; chatId: string; messageId: string }, channelId: string): Promise<void> {
    if (event.kind !== "message.received") return;
    const chat = await this.tools.whatsapp.getChat({ channelId, chatId: event.chatId });
    const link = await buildLinkForChat({
      tool: this.tools.whatsapp, provider: PROVIDER_KEY, channelId, chat, initialSync: false,
      onAttachmentMessage: (id) => this.set(`whatsapp:msg-channel:${id}`, channelId),
    });
    if (link) await this.tools.integrations.saveLinks([link]);
  }

  override async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    if (draft.type !== TYPE_CONVERSATION) return null;
    const body = (draft.noteContent ?? draft.title ?? "").trim();
    if (!body) { console.error("[whatsapp] onCreateLink: empty body"); return null; }
    const ids: string[] = [];
    for (const r of draft.recipients ?? []) ids.push(r.externalAccountId);
    for (const addr of (draft as any).addresses ?? []) {
      const resolved = await this.tools.whatsapp.resolveRecipient({ channelId: draft.channelId, address: addr });
      if (resolved) ids.push(resolved);
    }
    if (ids.length === 0) { console.error("[whatsapp] onCreateLink: no recipients"); return null; }
    const isGroup = ids.length > 1;
    const { chatId, message } = await this.tools.whatsapp.startChat({ channelId: draft.channelId, recipientIds: ids, text: body });
    return {
      source: isGroup ? `whatsapp:chat:${chatId}` : `whatsapp:person:${ids[0]}`,
      sources: isGroup ? [`whatsapp:chat:${chatId}`] : [`whatsapp:person:${ids[0]}`, `whatsapp:chat:${chatId}`],
      type: TYPE_CONVERSATION, status: STATUS_INBOX, title: draft.title, created: message.sentAt, channelId: draft.channelId,
      meta: { syncProvider: PROVIDER_KEY, channelId: draft.channelId, chatId, ...(isGroup ? {} : { profileId: ids[0] }) },
    } satisfies NewLinkWithNotes;
  }

  override async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;
    const fileActions = (note.actions ?? []).filter((a): a is Extract<Action, { type: typeof ActionType.file }> => a.type === ActionType.file);
    const attachments: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> = [];
    for (const a of fileActions) {
      try { const f = await this.tools.files.read(a.fileId); attachments.push({ buffer: f.data, filename: f.fileName, mimeType: f.mimeType }); }
      catch (e) { console.error("WhatsApp attachment read failed", a.fileId, e); }
    }
    const sent = await this.tools.whatsapp.sendMessage({ channelId, chatId, text: note.content ?? "", attachments: attachments.length ? attachments : undefined });
    return { key: `message-${sent.id}`, externalContent: sent.text };
  }

  override async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key?.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;
    const desired = pickDesiredReaction(note.reactions ?? {});
    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    if (desired === lastSent) return;
    try {
      if (desired) { await this.tools.whatsapp.setMessageReaction({ channelId, messageId, reaction: desired }); await this.set(stateKey, desired); }
      else { await this.tools.whatsapp.clearMessageReaction({ channelId, messageId }); await this.clear(stateKey); }
    } catch (e) { console.warn(`WhatsApp reaction write-back failed for ${messageId}`, e); }
  }

  override async onThreadRead(thread: Thread, _actor: Actor, unread: boolean): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const chatId = meta.chatId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!chatId || !channelId) return;
    try { await this.tools.whatsapp.setChatRead({ channelId, chatId, read: !unread }); }
    catch (e) { console.warn(`WhatsApp setChatRead failed for ${chatId}`, e); }
  }

  override async downloadAttachment(ref: string): Promise<{ redirectUrl: string } | { body: ReadableStream | Uint8Array; mimeType: string; fileName?: string }> {
    const colon = ref.indexOf(":");
    if (colon < 0) throw new Error(`Invalid WhatsApp attachment ref: ${ref}`);
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);
    const channelId = await this.get<string>(`whatsapp:msg-channel:${messageId}`);
    if (!channelId) throw new Error(`No WhatsApp channel cached for message ${messageId}`);
    const r = await this.tools.whatsapp.downloadAttachment({ channelId, messageId, attachmentId });
    return { body: r.body, mimeType: r.mimeType, fileName: r.fileName };
  }
}

export default WhatsApp;
```

> The `(draft as any).addresses` / `(draft as any)` casts are because the free-form address field name on `CreateLinkDraft` for `targets: "addresses"` should be confirmed against `@plotday/twister`'s `CreateLinkDraft` (it references `inviteEmails`/`addresses` — read `public/twister/src/connector.ts` lines ~150-170 and use the real field; remove the cast).

- [ ] **Step 5: Build + lint**

Run: `pnpm install` (picks up the new workspace package), then `pnpm --filter @plotday/connector-whatsapp lint`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add connectors/whatsapp pnpm-lock.yaml
git commit -m "feat(connector): WhatsApp connector (1:1 + group, two-way sync + compose)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase 4 — Instagram connector

### Task 12: Instagram messaging tool (abstract + concrete) + username resolution + message requests + factory

**Files:**
- Create: `libs/unipile/src/instagram.ts`
- Create: `workers/api/src/twist/tools/unipile/instagram.ts`
- Create: `workers/api/src/twist/tools/unipile/instagram.test.ts`
- Modify: `libs/unipile/src/index.ts`, `workers/api/src/twist/tools/factory.ts`

- [ ] **Step 1: Abstract `libs/unipile/src/instagram.ts`**

```ts
import { UnipileMessaging } from "./messaging";

export abstract class InstagramMessaging extends UnipileMessaging {
  static readonly toolId = "InstagramMessaging";

  /** Accept or ignore an Instagram message request (pending DM). */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setMessageRequestAccepted(params: { channelId: string; chatId: string; accepted: boolean }): Promise<void>;
}
```
Add `export * from "./instagram";` to `libs/unipile/src/index.ts`.

- [ ] **Step 2: Failing test for username normalization in `instagram.test.ts`**

```ts
import { describe, expect, test } from "vitest";
import { normalizeUsername } from "./instagram";

describe("normalizeUsername", () => {
  test("strips leading @ and trims", () => {
    expect(normalizeUsername("  @alice ")).toBe("alice");
  });
  test("returns null for empty", () => {
    expect(normalizeUsername("@")).toBeNull();
  });
});
```
Run: `timeout 120 pnpm --filter @plotday/api test -- instagram.test.ts` → FAIL.

- [ ] **Step 3: Concrete `workers/api/src/twist/tools/unipile/instagram.ts`**

```ts
import type { InstagramMessaging as IInstagramMessaging } from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";

export function normalizeUsername(input: string): string | null {
  const u = input.trim().replace(/^@/, "").trim();
  return u.length ? u : null;
}

export class InstagramMessaging extends UnipileMessagingTool implements IInstagramMessaging {
  protected readonly provider = "instagram";

  override async resolveRecipient(params: { channelId: string; address: string }): Promise<string | null> {
    await this.assertAccount(params.channelId);
    const username = normalizeUsername(params.address);
    if (!username) return null;
    // LIVE-CONFIRM (§13): exact Users endpoint/param for IG username → provider id.
    try {
      const att = await this.client.getUser({ accountId: params.channelId, identifier: username });
      return att.provider_id ?? null;
    } catch {
      return null;
    }
  }

  async setMessageRequestAccepted(params: { channelId: string; chatId: string; accepted: boolean }): Promise<void> {
    await this.assertAccount(params.channelId);
    // LIVE-CONFIRM (§13): IG accept/ignore message-request action on PATCH /chats/{id}.
    await this.client.setChatRequestStatus({ chatId: params.chatId, accepted: params.accepted });
  }
}
```
Add the `setChatRequestStatus` stub to `UnipileClient` (PATCH `/chats/{id}` with an action body; LIVE-CONFIRM the exact action name):
```ts
async setChatRequestStatus(input: { chatId: string; accepted: boolean }): Promise<void> {
  await this.request(`/chats/${encodeURIComponent(input.chatId)}`, {
    method: "PATCH",
    body: JSON.stringify({ action: input.accepted ? "acceptRequest" : "declineRequest" }),
    headers: { "content-type": "application/json" },
  });
}
```
Run: `timeout 120 pnpm --filter @plotday/api test -- instagram.test.ts` → PASS.

- [ ] **Step 4: Register in `factory.ts`** (same pattern as WhatsApp; `case "InstagramMessaging"`).

- [ ] **Step 5: Lint + commit**

```bash
git add libs/unipile/src/instagram.ts libs/unipile/src/index.ts workers/api/src/twist/tools/unipile/instagram.ts workers/api/src/twist/tools/unipile/instagram.test.ts workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/factory.ts
git commit -m "feat(unipile): Instagram messaging tool + username resolution + message-request action

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Instagram connector package (with message-request pending status)

**Files:**
- Create: `connectors/instagram/{package.json,tsconfig.json,src/index.ts,src/instagram.ts}`

- [ ] **Step 1–3: package.json / tsconfig.json / index.ts** — same as WhatsApp Task 11 with `@plotday/connector-instagram`, `displayName: "Instagram"`, new `plotTwistId` UUID.

- [ ] **Step 4: `src/instagram.ts`**

Mirror the WhatsApp connector with these deltas:
- `provider = "instagram"`, `PROVIDER_KEY = "instagram"`, logos `logos/instagram-icon.svg` (verify ~1:1 + dark per icon guidelines).
- `conversation` statuses include `pending`/`ignored`:
  ```ts
  statuses: [
    { status: "pending", label: "Request" },
    { status: STATUS_INBOX, label: "Inbox" },
    { status: STATUS_ARCHIVED, label: "Archived", done: true },
    { status: "ignored", label: "Ignored", done: true },
  ]
  ```
- In `backfill`/`buildLinkForChat` results, set `status: "pending"` when `chat.folder` indicates a request. Since the shared `assembleConversationLink` defaults to `inbox`, pass a computed `status`:
  ```ts
  // after building each link during backfill, override status for requests:
  // requests are chats whose folder marks them pending (LIVE-CONFIRM §13 folder value).
  ```
  Implement by NOT using `backfillChats` blindly: loop `listChats` yourself and call `assembleConversationLink({..., status: isRequest(chat) ? "pending" : "inbox"})`, where:
  ```ts
  function isRequest(chat: ChatThread): boolean {
    return (chat.folder ?? "").toUpperCase().includes("REQUEST"); // LIVE-CONFIRM (§13)
  }
  ```
- Add `override async onLinkUpdated(link: Link)`: when a `conversation` link moves `pending → inbox`, call `this.tools.instagram.setMessageRequestAccepted({ channelId, chatId, accepted: true })`; `pending → archived/ignored` → `accepted: false`. Guard idempotently with a `request_writeback:${chatId}` flag (mirror LinkedIn's `invitation_writeback` pattern).
- Compose uses `resolveRecipient` (username) exactly like WhatsApp.

> Because the per-request status override means Instagram can't use the one-shot `backfillChats` helper verbatim, the connector's `backfill` re-implements the chat loop (≈15 lines) using `buildLinkForChat` + a status override. This is acceptable thin glue; the heavy assembly stays shared.

- [ ] **Step 5: install + lint + commit**

Run: `pnpm install && pnpm --filter @plotday/connector-instagram lint`
```bash
git add connectors/instagram pnpm-lock.yaml
git commit -m "feat(connector): Instagram connector (1:1 + requests + group, two-way + compose)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Phase 5 — Site, docs, finalize

### Task 14: Site connections + verified icons

**Files:**
- Modify: `apps/site/app/data/connections.ts`

- [ ] **Step 1: Verify icons** per the AGENTS.md "Connector Icon Guidelines" — fetch the candidate SVGs and confirm ~1:1 aspect + dark-mode visibility:
  - WhatsApp: `https://api.iconify.design/logos/whatsapp-icon.svg` (multicolor, has own green; likely no dark variant needed).
  - Instagram: `https://api.iconify.design/skill-icons/instagram.svg` or `logos/instagram-icon.svg`; verify it's the gradient glyph (not a wordmark) and renders on dark. If the `logos/` entry is unsuitable, use `si("instagram", "E4405F", "E4405F")`.

- [ ] **Step 2: Add entries** in the "Available sources" block (next to LinkedIn):
```ts
{ name: "WhatsApp", logo: "https://api.iconify.design/logos/whatsapp-icon.svg", category: "Communication", entities: ["Messages", "Groups"], available: true, premium: true },
{ name: "Instagram", logo: "<verified>", logoDark: "<verified-if-needed>", category: "Communication", entities: ["Messages", "Requests"], available: true, premium: true },
```

- [ ] **Step 3: Lint + commit**

Run: `pnpm --filter @plotday/site lint` (or the site's typecheck script — check `apps/site/package.json`).
```bash
git add apps/site/app/data/connections.ts apps/site/public/assets/ 2>/dev/null
git commit -m "feat(site): list WhatsApp + Instagram as premium connections

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 15: User-facing docs

**Files:**
- Modify: `docs/updates.md`, `docs/features.md`

- [ ] **Step 1: `docs/updates.md`** — add a bullet to the top section, plain language:
  `- Connect WhatsApp and Instagram (premium): see and reply to your DMs and group chats in Plot, and start new conversations.`
- [ ] **Step 2: `docs/features.md`** — under the connectors/communication section, add WhatsApp and Instagram (two-way messaging, compose, reactions) alongside LinkedIn.
- [ ] **Step 3: Commit**
```bash
git add docs/updates.md docs/features.md
git commit -m "docs: WhatsApp + Instagram connectors in updates/features

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 16: Finalize

- [ ] **Step 1: Run the full gate**
```bash
pnpm --filter @plotday/unipile lint && pnpm --filter @plotday/unipile test
pnpm --filter @plotday/connector-linkedin lint
pnpm --filter @plotday/connector-whatsapp lint
pnpm --filter @plotday/connector-instagram lint
timeout 300 pnpm --filter @plotday/api lint
timeout 180 pnpm --filter @plotday/api test -- unipile
pnpm --filter @plotday/site lint
```
All must PASS.
- [ ] **Step 2: Invoke `/finalize`** (lint, backwards-compat, error-capture audit on new `catch` blocks, docs). No `public/` changes were made, so no changeset is required (confirm `git status` shows nothing under `public/`).
- [ ] **Step 3: Hand off for live testing** (spec §12): provide the user the list of `// LIVE-CONFIRM (§13)` sites to verify against real WhatsApp + Instagram accounts (startChat response shape, reaction-clear path, IG message-request folder value + accept/ignore action, IG username resolution endpoint, WhatsApp JID acceptance, WhatsApp phone field on profile).

---

## Self-Review (performed against the spec)

- **Spec coverage:** §3 decisions → Tasks 7/10–13 (platform-shape, open-unicode, addresses-compose) + §12 (live testing handoff). §5 shared core → Tasks 2–6, 10, 12. §6 no-poll → Task 7 (LinkedIn) + 11/13 (new connectors, webhook + one-shot backfill). §6a link-type model → Task 7 (LinkedIn 1 type), 11 (WhatsApp 2), 13 (Instagram 2 + pending). §9 LinkedIn punch-list → Task 5 (startChat), 7 (collapse + compose + drop poll/refresh), 8 (reaction-clear), 9 (reauth provider), base assertAccount (token keys). §10 wiring → Tasks 9, 10, 12, 14. §11 data model → connector-helpers (person/chat keying, meta, status-on-initial-only). §13 open items → `LIVE-CONFIRM` markers + Task 16 handoff.
- **Placeholder scan:** No "TBD"/"implement later". `LIVE-CONFIRM` markers are deliberate, code-complete best-guesses per the user's live-testing decision, not empty placeholders.
- **Type consistency:** Neutral types (`ChatProfile`/`ChatThread`/`ChatMessage`/`ChatThreadPage`/`ChatMessagePage`) defined in Task 2 are used consistently in normalize (Task 5), the concrete base (Task 5), and helpers (Task 4). `UnipileMessaging` (abstract) / `UnipileMessagingTool` (concrete) names are used consistently. `startChat(... title?)`, `resolveRecipient`, `pickDesiredReaction(reactions, allowed?)` signatures match across definition and call sites.
- **Known follow-up baked into tasks:** the `assemble*Link` `type?` override (Task 7 Step 1) and the `CreateLinkDraft` free-form-address field name (Task 11 Step 4) are called out explicitly to fix at implementation time by reading the real twister types.
