# Trello Connector Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the bidirectional `@plotday/connector-trello` package — sync Trello boards/cards into Plot as threads (lists→statuses, description/comments/members/attachments) and write changes back (move/archive cards, post/edit comments, create cards) — on top of the Trello auth provider from Plan 1.

**Architecture:** A `Connector<Trello>` subclass modeled on `public/connectors/linear/`. **board → channel**, **card → link of type `card`**, **list → per-board dynamic status** (Linear's `dynamicLinkTypes` pattern). A thin `trello-api.ts` REST client (key+token query auth, HMAC-SHA1 webhook verify) and a pure `trello-sync.ts` transform (`transformCard → NewLinkWithNotes`) keep logic testable. Per-board webhooks drive incremental sync; the ~1000-request execution budget is respected by paginating cards across `runTask`-queued batches.

**Tech Stack:** TypeScript, `@plotday/twister` (workspace), Cloudflare Workers runtime (`fetch`, `crypto.subtle`), vitest. No third-party SDK — Trello's REST API is called directly.

## Global Constraints

- **This is Plan 2 of the Trello effort**, building on Plan 1 (auth provider, already merged on this branch). Spec: `docs/superpowers/specs/2026-06-25-trello-connector-design.md` (Part 2). **Checklists are OUT of scope** (Plan 4) — do not sync `checklists`/`checkItems`.
- **Work in the worktree** `/Users/kris.braun/code/plot/.claude/worktrees/trello-connector`. The connector lives in the `public/` submodule at `public/connectors/trello/` — commit there (the submodule is already on branch `trello-connector`). The `connections.ts` availability flips (Task 11) are in the MAIN repo.
- **No connector changeset** (connectors deploy via `plot deploy`, not npm — only `public/twister/` changes get changesets).
- **`provider = AuthProvider.Trello`**, **`scopes = ["read", "write"]`**, **`static handleReplies = true`**.
- **Auth at sync time:** `const token = await this.tools.integrations.get(channelId)` returns `{ token, scopes, provider }` where (from Plan 1) `provider.key` = Trello app key, `provider.secret` = app secret (for HMAC), and `token` = the user token. Build API calls with `?key={provider.key}&token={token}`.
- **`source` format:** `trello:card:{cardId}` (Trello card id is an immutable 24-hex — globally unique). Always set `link.channelId = boardId` and `link.meta = { syncProvider: "trello", boardId, cardId, idList }`.
- **Initial vs incremental:** set `unread: false` (and `archived: false` for open cards) ONLY on initial sync; omit on incremental. A `closed` card always maps to `archived: true`. Propagate the `initialSync` flag through every batch.
- **Done detection:** a list whose name matches `/done|complete|closed|shipped|finished/i` → status `done: true` + icon `"done"`; otherwise the first list → icon `"todo"`, the rest → icon `"inProgress"`.
- **Note keys:** `"description"`, `comment-{actionId}`, `attachment-{attachmentId}`.
- **HTML/markdown:** Trello `desc` and comment text are markdown → `contentType: "markdown"` (the default; can omit).
- **Webhook security:** verify `x-trello-webhook` = `base64(HMAC-SHA1(appSecret, rawBody + callbackURL))` before processing. Localhost guard before registering.
- **Error handling:** connector write-back/ webhook helpers log expected failures with `console.error`/`console.warn` (matching linear); do not throw on expected external errors. (Connectors don't have `captureException`.)
- **Test command:** `cd public/connectors/trello && pnpm test` (vitest, tests live next to source as `src/*.test.ts`).
- **Reference, don't reinvent:** `public/connectors/linear/src/{linear.ts,linear-sync.ts,linear.test.ts,linear-sync.test.ts}` is the canonical pattern for every method below.

---

### Task 1: Scaffold the `trello` connector package

**Files:**
- Create: `public/connectors/trello/package.json`, `tsconfig.json`, `vitest.config.ts`, `LICENSE`, `README.md`
- Create: `public/connectors/trello/src/index.ts`, `src/trello.ts` (skeleton)

**Interfaces:**
- Produces: `class Trello extends Connector<Trello>` with `provider`, `scopes`, `linkTypes` (base `card` type), `static handleReplies = true`, `build()`. Default-exported.

- [ ] **Step 1: Generate a stable plotTwistId**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
node -e "console.log(crypto.randomUUID())"
```
Record the printed UUID; use it as `plotTwistId` in Step 2.

- [ ] **Step 2: Create `package.json`** (mirror linear; swap name/id/logo, drop the `@linear/sdk` dep — Trello uses raw fetch)

`public/connectors/trello/package.json`:
```json
{
  "name": "@plotday/connector-trello",
  "plotTwistId": "<UUID FROM STEP 1>",
  "displayName": "Trello",
  "description": "Track your Trello cards and check them off as work moves forward.",
  "logoUrl": "https://api.iconify.design/logos/trello.svg",
  "publisher": "Plot",
  "publisherUrl": "https://plot.day",
  "author": "Plot <team@plot.day> (https://plot.day)",
  "license": "MIT",
  "version": "0.1.0",
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
    "lint": "plot lint",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": {
    "@types/node": "^25.0.3",
    "typescript": "^5.9.3",
    "vitest": "^2.1.8"
  },
  "repository": { "type": "git", "url": "https://github.com/plotday/plot.git", "directory": "connectors/trello" },
  "homepage": "https://plot.day",
  "bugs": { "url": "https://github.com/plotday/plot/issues" },
  "keywords": ["plot", "connector", "trello", "project-management"]
}
```

- [ ] **Step 3: Create `tsconfig.json` and copy `vitest.config.ts` + `LICENSE` from linear**

`public/connectors/trello/tsconfig.json`:
```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": { "outDir": "./dist" },
  "include": ["src/**/*.ts"]
}
```
```bash
cp public/connectors/linear/vitest.config.ts public/connectors/trello/vitest.config.ts
cp public/connectors/linear/LICENSE public/connectors/trello/LICENSE
```
Write a one-paragraph `public/connectors/trello/README.md` describing the connector (what it syncs, that it's bidirectional).

- [ ] **Step 4: Create the class skeleton**

`public/connectors/trello/src/index.ts`:
```typescript
export { default, Trello } from "./trello";
```

`public/connectors/trello/src/trello.ts`:
```typescript
import { Connector, type ToolBuilder } from "@plotday/twister";
import { AuthProvider, Integrations, type StatusIcon } from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

export class Trello extends Connector<Trello> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Trello;
  readonly scopes = ["read", "write"];
  readonly dynamicLinkTypes = true; // per-board statuses are attached in getChannels
  readonly access = [
    "Reads your boards, cards, comments, and attachments",
    "Creates and updates cards and posts comments you make in Plot",
    "Keeps Plot up to date as cards change in Trello",
  ];
  readonly linkTypes = [
    {
      type: "card",
      label: "Card",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      composePlaceholder: "Create a Trello card",
      composeVerb: "Create",
      replyPlaceholder: "Add a comment",
      replyVerb: "Comment",
      logo: "https://api.iconify.design/logos/trello.svg",
      supportsAssignee: false,
      // statuses + compose are attached per-board in getChannels()
      statuses: [
        { status: "todo", label: "To Do", icon: "todo" as StatusIcon },
        { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
      ],
      compose: { status: "todo" },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.trello.com/*"] }),
    };
  }

  // Lifecycle + sync + write-back methods are added in later tasks.
  async getChannels(): Promise<import("@plotday/twister/tools/integrations").Channel[]> {
    return [];
  }
  async onChannelEnabled(): Promise<void> {}
  async onChannelDisabled(): Promise<void> {}
}

export default Trello;
```

- [ ] **Step 5: Install + verify build**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector && pnpm install
cd public/connectors/trello && pnpm build
```
Expected: `pnpm install` links the new workspace package; `tsc` compiles with no errors. (If `pnpm-workspace.yaml` doesn't already glob `public/connectors/*`, add it — check first with `grep -n connectors pnpm-workspace.yaml`.)

- [ ] **Step 6: Commit** (in the submodule)

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public
git add connectors/trello
git commit -m "feat(trello): scaffold connector package"
```

---

### Task 2: `trello-api.ts` — REST client + webhook HMAC verify

**Files:**
- Create: `public/connectors/trello/src/trello-api.ts`
- Test: `public/connectors/trello/src/trello-api.test.ts`

**Interfaces:**
- Produces:
  - `type TrelloBoard = { id: string; name: string }`
  - `type TrelloList = { id: string; name: string; pos: number }`
  - `type TrelloMember = { id: string; fullName: string | null; username: string | null; avatarUrl: string | null }`
  - `type TrelloAttachment = { id: string; name: string; url: string; bytes: number | null; mimeType: string | null }`
  - `type TrelloCommentAction = { id: string; type: "commentCard"; date: string; memberCreator: TrelloMember | null; data: { text: string } }`
  - `type TrelloCard = { id: string; name: string; desc: string; idList: string; idBoard: string; closed: boolean; url: string; idMembers: string[]; members?: TrelloMember[]; attachments?: TrelloAttachment[]; actions?: TrelloCommentAction[]; dateLastActivity: string }`
  - `class TrelloApi` with: `getBoards()`, `getLists(boardId)`, `getCards(boardId, opts: { limit: number; before?: string })`, `getCard(cardId)`, `createCard(p)`, `updateCard(cardId, fields)`, `addComment(cardId, text)`, `updateComment(actionId, text)`, `createWebhook(boardId, callbackURL)`, `deleteWebhook(webhookId)`.
  - `verifyTrelloWebhook(secret: string, rawBody: string, callbackURL: string, signature: string): Promise<boolean>`
  - `cardCreatedAt(cardId: string): Date` (Trello ids encode creation time: first 8 hex = unix seconds).

- [ ] **Step 1: Write the failing tests**

`public/connectors/trello/src/trello-api.test.ts`:
```typescript
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrelloApi, verifyTrelloWebhook, cardCreatedAt } from "./trello-api";

afterEach(() => vi.restoreAllMocks());

function mockFetchOnce(json: unknown, ok = true, status = 200) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(json), { status: ok ? status : 400 }),
  );
}

describe("TrelloApi request shaping", () => {
  const api = new TrelloApi("KEY", "TOK");

  it("getBoards calls /members/me/boards with key+token", async () => {
    const f = mockFetchOnce([{ id: "b1", name: "Board" }]);
    const boards = await api.getBoards();
    expect(boards).toEqual([{ id: "b1", name: "Board" }]);
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("https://api.trello.com/1/members/me/boards");
    expect(url).toContain("key=KEY");
    expect(url).toContain("token=TOK");
    expect(url).toContain("filter=open");
  });

  it("getCards passes limit + before for pagination", async () => {
    const f = mockFetchOnce([]);
    await api.getCards("b1", { limit: 50, before: "card9" });
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("/boards/b1/cards");
    expect(url).toContain("limit=50");
    expect(url).toContain("before=card9");
    expect(url).toContain("actions=commentCard");
    expect(url).toContain("attachments=true");
    expect(url).toContain("members=true");
  });

  it("addComment POSTs to /cards/{id}/actions/comments and returns the action", async () => {
    const f = mockFetchOnce({ id: "act1", type: "commentCard", date: "2026-01-01T00:00:00Z", data: { text: "hi" } });
    const action = await api.addComment("c1", "hi");
    expect(action.id).toBe("act1");
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("/cards/c1/actions/comments");
    expect(url).toContain("text=hi");
    expect(init.method).toBe("POST");
  });

  it("createWebhook POSTs idModel + callbackURL", async () => {
    const f = mockFetchOnce({ id: "wh1" });
    const res = await api.createWebhook("b1", "https://api.plot.test/hook/abc");
    expect(res.id).toBe("wh1");
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("/webhooks");
    expect(init.method).toBe("POST");
    const body = String(init.body);
    expect(body).toContain("idModel=b1");
    expect(body).toContain("callbackURL=");
  });
});

describe("cardCreatedAt", () => {
  it("decodes the timestamp from the first 8 hex chars of the id", () => {
    // 0x5f000000 = 1593817600 → 2020-07-03T...; assert it parses to that epoch.
    const d = cardCreatedAt("5f000000aaaaaaaaaaaaaaaa");
    expect(d.getTime()).toBe(0x5f000000 * 1000);
  });
});

describe("verifyTrelloWebhook", () => {
  it("accepts a correct HMAC-SHA1 signature and rejects a wrong one", async () => {
    const secret = "shh";
    const body = '{"action":{"type":"updateCard"}}';
    const callbackURL = "https://api.plot.test/hook/abc";
    // Compute the expected signature with the same primitive the impl uses.
    const key = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
    );
    const sigBuf = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body + callbackURL));
    const good = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
    expect(await verifyTrelloWebhook(secret, body, callbackURL, good)).toBe(true);
    expect(await verifyTrelloWebhook(secret, body, callbackURL, "wrong")).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd public/connectors/trello && pnpm test
```
Expected: FAIL — `trello-api` module / exports don't exist.

- [ ] **Step 3: Implement `trello-api.ts`**

```typescript
// Cloudflare Workers provide Buffer/crypto globally; we use Web Crypto + btoa.
export type TrelloBoard = { id: string; name: string };
export type TrelloList = { id: string; name: string; pos: number };
export type TrelloMember = {
  id: string;
  fullName: string | null;
  username: string | null;
  avatarUrl: string | null;
};
export type TrelloAttachment = {
  id: string;
  name: string;
  url: string;
  bytes: number | null;
  mimeType: string | null;
};
export type TrelloCommentAction = {
  id: string;
  type: "commentCard";
  date: string;
  memberCreator: TrelloMember | null;
  data: { text: string };
};
export type TrelloCard = {
  id: string;
  name: string;
  desc: string;
  idList: string;
  idBoard: string;
  closed: boolean;
  url: string;
  idMembers: string[];
  members?: TrelloMember[];
  attachments?: TrelloAttachment[];
  actions?: TrelloCommentAction[];
  dateLastActivity: string;
};

const BASE = "https://api.trello.com/1";
const CARD_FIELDS = "id,name,desc,idList,idBoard,closed,url,idMembers,dateLastActivity";
const MEMBER_FIELDS = "id,fullName,username,avatarUrl";

export class TrelloApi {
  constructor(
    private readonly key: string,
    private readonly token: string,
  ) {}

  private auth(extra = ""): string {
    const sep = extra ? "&" : "";
    return `key=${encodeURIComponent(this.key)}&token=${encodeURIComponent(this.token)}${sep}${extra}`;
  }

  private async req<T>(method: string, path: string, query = ""): Promise<T> {
    const url = `${BASE}${path}?${this.auth(query)}`;
    const res = await fetch(url, { method, headers: { Accept: "application/json" } });
    if (!res.ok) {
      throw new Error(`Trello ${method} ${path} failed: ${res.status} ${await res.text()}`);
    }
    return (await res.json()) as T;
  }

  getBoards(): Promise<TrelloBoard[]> {
    return this.req("GET", "/members/me/boards", "filter=open&fields=id,name");
  }

  getLists(boardId: string): Promise<TrelloList[]> {
    return this.req("GET", `/boards/${boardId}/lists`, "filter=open&fields=id,name,pos");
  }

  getCards(boardId: string, opts: { limit: number; before?: string }): Promise<TrelloCard[]> {
    const q = [
      "filter=open",
      `fields=${CARD_FIELDS}`,
      "members=true",
      `member_fields=${MEMBER_FIELDS}`,
      "attachments=true",
      "attachment_fields=id,name,url,bytes,mimeType",
      "actions=commentCard",
      "actions_limit=50",
      `limit=${opts.limit}`,
      ...(opts.before ? [`before=${opts.before}`] : []),
    ].join("&");
    return this.req("GET", `/boards/${boardId}/cards`, q);
  }

  getCard(cardId: string): Promise<TrelloCard> {
    const q = [
      `fields=${CARD_FIELDS}`,
      "members=true",
      `member_fields=${MEMBER_FIELDS}`,
      "attachments=true",
      "attachment_fields=id,name,url,bytes,mimeType",
      "actions=commentCard",
      "actions_limit=50",
    ].join("&");
    return this.req("GET", `/cards/${cardId}`, q);
  }

  createCard(p: { idList: string; name: string; desc?: string }): Promise<TrelloCard> {
    const q = [
      `idList=${encodeURIComponent(p.idList)}`,
      `name=${encodeURIComponent(p.name)}`,
      ...(p.desc ? [`desc=${encodeURIComponent(p.desc)}`] : []),
    ].join("&");
    return this.req("POST", "/cards", q);
  }

  updateCard(
    cardId: string,
    fields: { idList?: string; closed?: boolean; name?: string; desc?: string },
  ): Promise<TrelloCard> {
    const parts: string[] = [];
    if (fields.idList !== undefined) parts.push(`idList=${encodeURIComponent(fields.idList)}`);
    if (fields.closed !== undefined) parts.push(`closed=${fields.closed}`);
    if (fields.name !== undefined) parts.push(`name=${encodeURIComponent(fields.name)}`);
    if (fields.desc !== undefined) parts.push(`desc=${encodeURIComponent(fields.desc)}`);
    return this.req("PUT", `/cards/${cardId}`, parts.join("&"));
  }

  addComment(cardId: string, text: string): Promise<TrelloCommentAction> {
    return this.req("POST", `/cards/${cardId}/actions/comments`, `text=${encodeURIComponent(text)}`);
  }

  updateComment(actionId: string, text: string): Promise<{ id: string; data: { text: string } }> {
    return this.req("PUT", `/actions/${actionId}`, `text=${encodeURIComponent(text)}`);
  }

  createWebhook(boardId: string, callbackURL: string): Promise<{ id: string }> {
    const q = `idModel=${encodeURIComponent(boardId)}&callbackURL=${encodeURIComponent(callbackURL)}&description=${encodeURIComponent("Plot Trello sync")}`;
    return this.req("POST", "/webhooks", q);
  }

  deleteWebhook(webhookId: string): Promise<unknown> {
    return this.req("DELETE", `/webhooks/${webhookId}`);
  }
}

/** Trello object ids encode their creation time in the first 8 hex chars (unix seconds). */
export function cardCreatedAt(cardId: string): Date {
  const seconds = parseInt(cardId.substring(0, 8), 16);
  return new Date(seconds * 1000);
}

/** Verify a Trello webhook: base64(HMAC-SHA1(appSecret, rawBody + callbackURL)) === header. */
export async function verifyTrelloWebhook(
  secret: string,
  rawBody: string,
  callbackURL: string,
  signature: string,
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-1" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody + callbackURL));
    const expected = btoa(String.fromCharCode(...new Uint8Array(sig)));
    return expected === signature;
  } catch {
    return false;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd public/connectors/trello && pnpm test
```
Expected: PASS (all trello-api tests). Then `pnpm exec tsc --noEmit` clean.

- [ ] **Step 5: Commit** (submodule)

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public
git add connectors/trello/src/trello-api.ts connectors/trello/src/trello-api.test.ts
git commit -m "feat(trello): REST client + webhook HMAC verify"
```

---

### Task 3: `trello-sync.ts` — `transformCard` pure transform

**Files:**
- Create: `public/connectors/trello/src/trello-sync.ts`
- Test: `public/connectors/trello/src/trello-sync.test.ts`

**Interfaces:**
- Consumes: `TrelloCard`, `TrelloMember`, `cardCreatedAt` (Task 2); `NewLinkWithNotes`, `NewContact` (twister).
- Produces: `transformCard(card: TrelloCard, boardId: string, initialSync: boolean): NewLinkWithNotes`. Mirrors linear's `buildIssueLink`.

- [ ] **Step 1: Write the failing test** (model on `linear-sync.test.ts`)

`public/connectors/trello/src/trello-sync.test.ts`:
```typescript
import { describe, expect, it } from "vitest";
import { transformCard } from "./trello-sync";
import type { TrelloCard } from "./trello-api";

function card(overrides: Partial<TrelloCard> = {}): TrelloCard {
  return {
    id: "5f000000aaaaaaaaaaaaaaaa", // encodes 0x5f000000 epoch
    name: "Ship the thing",
    desc: "Steps to repro",
    idList: "list-todo",
    idBoard: "board-1",
    closed: false,
    url: "https://trello.com/c/abc/1-ship",
    idMembers: ["m1"],
    members: [{ id: "m1", fullName: "Ada", username: "ada", avatarUrl: "https://img/ada" }],
    attachments: [{ id: "att1", name: "spec.pdf", url: "https://t.co/spec", bytes: 10, mimeType: "application/pdf" }],
    actions: [
      {
        id: "act1",
        type: "commentCard",
        date: "2026-01-03T00:00:00.000Z",
        memberCreator: { id: "m2", fullName: "Bob", username: "bob", avatarUrl: null },
        data: { text: "looks good" },
      },
    ],
    dateLastActivity: "2026-01-04T00:00:00.000Z",
    ...overrides,
  };
}

describe("transformCard", () => {
  it("maps a full card to a link with description, comment, attachment notes and member contacts", () => {
    const link = transformCard(card(), "board-1", false);
    expect(link.source).toBe("trello:card:5f000000aaaaaaaaaaaaaaaa");
    expect(link.type).toBe("card");
    expect(link.title).toBe("Ship the thing");
    expect(link.status).toBe("list-todo");
    expect(link.channelId).toBe("board-1");
    expect(link.sourceUrl).toBe("https://trello.com/c/abc/1-ship");
    expect(link.created).toEqual(new Date(0x5f000000 * 1000));
    expect(link.meta).toEqual({ syncProvider: "trello", boardId: "board-1", cardId: "5f000000aaaaaaaaaaaaaaaa", idList: "list-todo" });
    // members → accessContacts
    expect(link.accessContacts).toEqual([{ name: "Ada", avatar: "https://img/ada", source: { accountId: "m1" } }]);
    // notes: description + comment + attachment
    const keys = (link.notes ?? []).map((n) => n.key);
    expect(keys).toEqual(["description", "comment-act1", "attachment-att1"]);
    const comment = link.notes!.find((n) => n.key === "comment-act1")!;
    expect(comment.content).toBe("looks good");
    expect(comment.created).toEqual(new Date("2026-01-03T00:00:00.000Z"));
    expect(comment.author).toEqual({ name: "Bob", avatar: undefined, source: { accountId: "m2" } });
    const att = link.notes!.find((n) => n.key === "attachment-att1")!;
    expect(att.content).toBe("[spec.pdf](https://t.co/spec)");
  });

  it("sets unread:false + archived:false only on initial sync for open cards", () => {
    const initial = transformCard(card(), "b", true);
    expect(initial.unread).toBe(false);
    expect(initial.archived).toBe(false);
    const incremental = transformCard(card(), "b", false);
    expect(incremental).not.toHaveProperty("unread");
    expect(incremental).not.toHaveProperty("archived");
  });

  it("maps a closed card to archived:true on both initial and incremental", () => {
    expect(transformCard(card({ closed: true }), "b", true).archived).toBe(true);
    expect(transformCard(card({ closed: true }), "b", false).archived).toBe(true);
  });

  it("omits the description note content when desc is empty", () => {
    const link = transformCard(card({ desc: "" }), "b", false);
    const desc = link.notes!.find((n) => n.key === "description")!;
    expect(desc.content).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd public/connectors/trello && pnpm test trello-sync
```
Expected: FAIL — `trello-sync` doesn't exist.

- [ ] **Step 3: Implement `trello-sync.ts`**

```typescript
import type { NewContact, NewLinkWithNotes } from "@plotday/twister";
import { type TrelloCard, type TrelloMember, cardCreatedAt } from "./trello-api";

function memberContact(m: TrelloMember): NewContact {
  return {
    name: m.fullName ?? m.username ?? "",
    avatar: m.avatarUrl ?? undefined,
    source: { accountId: m.id },
  };
}

export function transformCard(
  card: TrelloCard,
  boardId: string,
  initialSync: boolean,
): NewLinkWithNotes {
  const created = cardCreatedAt(card.id);
  const hasDesc = (card.desc ?? "").trim().length > 0;

  type CardNote = NonNullable<NewLinkWithNotes["notes"]>[number];
  const notes: CardNote[] = [];
  notes.push({ key: "description", content: hasDesc ? card.desc : null, created } as CardNote);

  for (const action of card.actions ?? []) {
    if (action.type !== "commentCard") continue;
    notes.push({
      key: `comment-${action.id}`,
      content: action.data.text,
      created: new Date(action.date),
      author: action.memberCreator ? memberContact(action.memberCreator) : undefined,
    } as CardNote);
  }

  for (const att of card.attachments ?? []) {
    notes.push({
      key: `attachment-${att.id}`,
      content: `[${att.name}](${att.url})`,
      created,
    } as CardNote);
  }

  const contacts = (card.members ?? []).map(memberContact);

  return {
    source: `trello:card:${card.id}`,
    type: "card",
    title: card.name,
    created,
    status: card.idList,
    channelId: boardId,
    sourceUrl: card.url,
    preview: hasDesc ? card.desc : card.name,
    meta: { syncProvider: "trello", boardId, cardId: card.id, idList: card.idList },
    ...(contacts.length > 0 ? { accessContacts: contacts } : {}),
    notes,
    // closed → always archived; open → archived:false on initial only
    ...(card.closed
      ? { archived: true }
      : initialSync
        ? { archived: false }
        : {}),
    ...(initialSync ? { unread: false } : {}),
  };
}
```

- [ ] **Step 4: Run test to verify it passes** — `cd public/connectors/trello && pnpm test trello-sync` → PASS. Then `pnpm exec tsc --noEmit`.

- [ ] **Step 5: Commit** (submodule): `git add connectors/trello/src/trello-sync.ts connectors/trello/src/trello-sync.test.ts && git commit -m "feat(trello): transformCard card→link"`

---

### Task 4: `getChannels` — boards → channels with per-board dynamic statuses

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Create: `public/connectors/trello/src/trello-channels.ts` (pure `buildCardLinkType(lists)` helper)
- Test: `public/connectors/trello/src/trello-channels.test.ts`

**Interfaces:**
- Consumes: `TrelloList` (Task 2); `Channel`, `LinkTypeConfig`, `StatusIcon` (twister).
- Produces:
  - `buildCardLinkType(lists: TrelloList[]): LinkTypeConfig` — pure: lists → statuses (done-heuristic + icons) + `compose.status` = first non-done list id.
  - `Trello.getChannels` returns one `Channel` per board with `linkTypes: [buildCardLinkType(lists)]`.
  - private `getApi(channelId)` helper on the class.

- [ ] **Step 1: Write the failing test**

`public/connectors/trello/src/trello-channels.test.ts`:
```typescript
import { describe, expect, it } from "vitest";
import { buildCardLinkType, DONE_LIST_RE } from "./trello-channels";
import type { TrelloList } from "./trello-api";

const lists: TrelloList[] = [
  { id: "l1", name: "To Do", pos: 1 },
  { id: "l2", name: "Doing", pos: 2 },
  { id: "l3", name: "Done", pos: 3 },
];

describe("buildCardLinkType", () => {
  it("maps lists to statuses: first=todo, middle=inProgress, done-name=done+done:true", () => {
    const lt = buildCardLinkType(lists);
    expect(lt.type).toBe("card");
    expect(lt.statuses).toEqual([
      { status: "l1", label: "To Do", icon: "todo" },
      { status: "l2", label: "Doing", icon: "inProgress" },
      { status: "l3", label: "Done", icon: "done", done: true },
    ]);
    // compose defaults to the first non-done list
    expect(lt.compose).toEqual({ status: "l1" });
  });

  it("DONE_LIST_RE matches common done-column names", () => {
    expect(DONE_LIST_RE.test("Done")).toBe(true);
    expect(DONE_LIST_RE.test("Shipped")).toBe(true);
    expect(DONE_LIST_RE.test("Complete")).toBe(true);
    expect(DONE_LIST_RE.test("Backlog")).toBe(false);
  });

  it("falls back to the first list for compose when no non-done list exists", () => {
    const lt = buildCardLinkType([{ id: "d", name: "Done", pos: 1 }]);
    expect(lt.compose).toEqual({ status: "d" });
  });
});
```

- [ ] **Step 2: Run test to verify it fails** — `pnpm test trello-channels` → FAIL.

- [ ] **Step 3: Implement `trello-channels.ts`**

```typescript
import type { LinkTypeConfig, StatusIcon } from "@plotday/twister/tools/integrations";
import type { TrelloList } from "./trello-api";

export const DONE_LIST_RE = /done|complete|closed|shipped|finished/i;

export function buildCardLinkType(lists: TrelloList[]): LinkTypeConfig {
  const sorted = [...lists].sort((a, b) => a.pos - b.pos);
  const statuses = sorted.map((list, i) => {
    const isDone = DONE_LIST_RE.test(list.name);
    const icon: StatusIcon = isDone ? "done" : i === 0 ? "todo" : "inProgress";
    return {
      status: list.id,
      label: list.name,
      icon,
      ...(isDone ? { done: true as const } : {}),
    };
  });
  const firstOpen = sorted.find((l) => !DONE_LIST_RE.test(l.name)) ?? sorted[0];
  return {
    type: "card",
    label: "Card",
    noteLabel: "Comment",
    sharingModel: "channel",
    composePlaceholder: "Create a Trello card",
    composeVerb: "Create",
    replyPlaceholder: "Add a comment",
    replyVerb: "Comment",
    logo: "https://api.iconify.design/logos/trello.svg",
    supportsAssignee: false,
    statuses,
    ...(firstOpen ? { compose: { status: firstOpen.id } } : {}),
  };
}
```

- [ ] **Step 4: Implement `getChannels` + `getApi` in `trello.ts`**

Add imports and replace the skeleton `getChannels`:
```typescript
import { TrelloApi } from "./trello-api";
import { buildCardLinkType } from "./trello-channels";
import type { Channel } from "@plotday/twister/tools/integrations";

// private helper:
private async getApi(channelId: string): Promise<TrelloApi> {
  const token = await this.tools.integrations.get(channelId);
  if (!token?.token || !token.provider?.key) {
    throw new Error(`No Trello credentials for channel ${channelId}`);
  }
  return new TrelloApi(token.provider.key, token.token);
}

async getChannels(): Promise<Channel[]> {
  // getChannels runs before any channel is enabled; resolve creds via the
  // provider (any channel id works — the token is account-scoped). Use a
  // throwaway id; integrations.get falls back to the account token.
  const api = await this.getApi("");
  const boards = await api.getBoards();
  return Promise.all(
    boards.map(async (board) => {
      const lists = await api.getLists(board.id);
      return { id: board.id, title: board.name, linkTypes: [buildCardLinkType(lists)] };
    }),
  );
}
```
> NOTE for implementer: confirm how a no-channel `integrations.get("")` resolves the account token during `getChannels` — check how `attio`/`fellow` (API-key connectors) or `linear` obtain the token inside `getChannels` (linear uses the `token` arg passed to `getChannels(auth, token)`). If the runtime passes a usable `token` arg to `getChannels`, prefer `getChannels(_auth, token)` and build `new TrelloApi(token.provider.key, token.token)` directly instead of `getApi("")`. Adjust to whichever the runtime actually provides; the test below injects the api so it's agnostic.

- [ ] **Step 5: Add a getChannels test to `trello.test.ts`** (created here; the harness factory is reused by later tasks)

`public/connectors/trello/src/trello.test.ts` (model the store/factory on `linear.test.ts:10-70`):
```typescript
import { describe, expect, it, vi } from "vitest";
import { Trello } from "./trello";

export function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => void map.set(k, v)),
    clear: vi.fn(async (k: string) => void map.delete(k)),
    list: vi.fn(async (p: string) => [...map.keys()].filter((k) => k.startsWith(p))),
  };
}

export function makeTrello(opts: {
  store?: ReturnType<typeof makeStore>;
  integrations?: Record<string, unknown>;
  network?: Record<string, unknown>;
} = {}): Trello {
  const tools = {
    store: opts.store ?? makeStore(),
    integrations: {
      get: vi.fn().mockResolvedValue({ token: "tok", provider: { key: "KEY", secret: "SEC" } }),
      saveLink: vi.fn().mockResolvedValue("thread-1"),
      channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      archiveLinks: vi.fn().mockResolvedValue(undefined),
      ...opts.integrations,
    },
    network: { createWebhook: vi.fn(), deleteWebhook: vi.fn(), ...opts.network },
  };
  return new Trello("twist-1" as never, { getTools: () => tools } as never);
}

describe("getChannels", () => {
  it("returns one channel per board with per-board statuses from lists", async () => {
    const trello = makeTrello();
    const api = {
      getBoards: vi.fn().mockResolvedValue([{ id: "b1", name: "Board One" }]),
      getLists: vi.fn().mockResolvedValue([
        { id: "l1", name: "To Do", pos: 1 },
        { id: "l2", name: "Done", pos: 2 },
      ]),
    };
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue(api);

    const channels = await trello.getChannels();
    expect(channels).toHaveLength(1);
    expect(channels[0].id).toBe("b1");
    expect(channels[0].title).toBe("Board One");
    expect(channels[0].linkTypes![0].statuses).toEqual([
      { status: "l1", label: "To Do", icon: "todo" },
      { status: "l2", label: "Done", icon: "done", done: true },
    ]);
  });
});
```

- [ ] **Step 6: Run tests** — `cd public/connectors/trello && pnpm test` → all pass; `pnpm exec tsc --noEmit` clean.

- [ ] **Step 7: Commit** (submodule): `git add connectors/trello/src/{trello.ts,trello-channels.ts,trello-channels.test.ts,trello.test.ts} && git commit -m "feat(trello): getChannels with per-board dynamic statuses"`

---

### Task 5: Sync orchestration — `onChannelEnabled` + `startBatchSync` + `syncBatch`

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `transformCard` (Task 3), `getApi` (Task 4), `this.callback`/`this.runTask`/`this.set`/`this.get`/`this.clear`.
- Produces:
  - `onChannelEnabled(channel, context?)` — idempotent: stores `sync_enabled_{boardId}`, queues `setupWebhook` via `runTask`, then `startBatchSync` (unless `context?.observeOnly`).
  - private `startBatchSync(boardId)` — sets `sync_state_{boardId} = { before: null, batchNumber: 1, initialSync: true }`, queues `syncBatch`.
  - private `syncBatch(boardId)` — fetches a page (`CARDS_PER_PAGE`), `transformCard` + `saveLink` each, paginates via last card id (`before`), else `channelSyncCompleted` (if initial) + clears state.
  - const `CARDS_PER_PAGE = 100`.

- [ ] **Step 1: Write the failing tests** (mirror `linear.test.ts:72-141` completion + pagination tests)

Append to `trello.test.ts`:
```typescript
import { makeStore, makeTrello } from "./trello.test"; // (same file; for illustration the helpers above are in-module)

describe("syncBatch", () => {
  const bid = "b1";
  function withApi(trello: Trello, cards: unknown[]) {
    const api = { getCards: vi.fn().mockResolvedValue(cards) };
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue(api);
    return api;
  }

  it("saves each card and signals channelSyncCompleted when the last page is reached", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { channelSyncCompleted, saveLink } });
    withApi(trello, [
      { id: "5f000000aaaaaaaaaaaaaaaa", name: "C1", desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z" },
    ]); // fewer than CARDS_PER_PAGE → last page

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(saveLink).toHaveBeenCalledTimes(1);
    const saved = saveLink.mock.calls[0][0];
    expect(saved.source).toBe("trello:card:5f000000aaaaaaaaaaaaaaaa");
    expect(saved.unread).toBe(false); // initialSync
    expect(channelSyncCompleted).toHaveBeenCalledWith(bid);
    expect(store.map.has(`sync_state_${bid}`)).toBe(false);
  });

  it("queues the next batch and advances `before` while a full page is returned", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const channelSyncCompleted = vi.fn();
    const trello = makeTrello({ store, integrations: { channelSyncCompleted } });
    const fullPage = Array.from({ length: 100 }, (_, i) => ({
      id: `5f0000${String(i).padStart(2, "0")}aaaaaaaaaaaaaaaa`.slice(0, 24),
      name: `C${i}`, desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
    }));
    withApi(trello, fullPage);
    (trello as unknown as { callback: unknown }).callback = vi.fn().mockResolvedValue("cb");
    (trello as unknown as { runTask: unknown }).runTask = vi.fn().mockResolvedValue(undefined);

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(channelSyncCompleted).not.toHaveBeenCalled();
    expect((trello as unknown as { runTask: ReturnType<typeof vi.fn> }).runTask).toHaveBeenCalledTimes(1);
    const state = store.map.get(`sync_state_${bid}`) as { before: string };
    expect(state.before).toBe(fullPage[fullPage.length - 1].id); // paginate before the last card
  });
});
```

- [ ] **Step 2: Run tests → FAIL** (`syncBatch` not implemented).

- [ ] **Step 3: Implement in `trello.ts`**

```typescript
import { transformCard } from "./trello-sync";
import type { SyncContext } from "@plotday/twister/tools/integrations";

const CARDS_PER_PAGE = 100;
type TrelloSyncState = { before: string | null; batchNumber: number; initialSync: boolean };

async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
  await this.set(`sync_enabled_${channel.id}`, true);

  // Queue webhook setup as a separate task (never inline — blocks the HTTP response).
  const webhookCb = await this.callback(this.setupWebhook, channel.id);
  await this.runTask(webhookCb);

  if (!context?.observeOnly) {
    await this.startBatchSync(channel.id);
  }
}

private async startBatchSync(boardId: string): Promise<void> {
  await this.set(`sync_state_${boardId}`, { before: null, batchNumber: 1, initialSync: true } as TrelloSyncState);
  const cb = await this.callback(this.syncBatch, boardId);
  await this.runTask(cb);
}

private async syncBatch(boardId: string): Promise<void> {
  const state = await this.get<TrelloSyncState>(`sync_state_${boardId}`);
  if (!state) throw new Error(`Trello sync state not found for board ${boardId}`);

  const api = await this.getApi(boardId);
  const cards = await api.getCards(boardId, { limit: CARDS_PER_PAGE, before: state.before ?? undefined });

  for (const card of cards) {
    await this.tools.integrations.saveLink(transformCard(card, boardId, state.initialSync));
  }

  if (cards.length === CARDS_PER_PAGE) {
    // Full page → more cards remain; paginate before the last (oldest) card id.
    await this.set(`sync_state_${boardId}`, {
      before: cards[cards.length - 1].id,
      batchNumber: state.batchNumber + 1,
      initialSync: state.initialSync,
    } as TrelloSyncState);
    const cb = await this.callback(this.syncBatch, boardId);
    await this.runTask(cb);
  } else {
    if (state.initialSync) await this.tools.integrations.channelSyncCompleted(boardId);
    await this.clear(`sync_state_${boardId}`);
  }
}
```

- [ ] **Step 4: Run tests → PASS**; `pnpm exec tsc --noEmit` clean. (`setupWebhook` is referenced by `onChannelEnabled` — add a temporary `async setupWebhook(_boardId: string) {}` stub so it compiles; Task 6 fills it in. Note the stub in your report.)

- [ ] **Step 5: Commit** (submodule): `git add connectors/trello/src/{trello.ts,trello.test.ts} && git commit -m "feat(trello): batch sync orchestration + pagination"`

---

### Task 6: Webhooks — `setupWebhook` + `onWebhook`

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `this.tools.network.createWebhook`, `verifyTrelloWebhook` (Task 2), `getApi`, `transformCard`.
- Produces:
  - `setupWebhook(boardId)` — `createWebhook({}, this.onWebhook, boardId)` → URL; localhost guard; `api.createWebhook(boardId, url)`; store `webhook_id_{boardId}` + `webhook_url_{boardId}`.
  - `onWebhook(req: WebhookRequest, boardId)` — read `x-trello-webhook` header + `req.rawBody`; verify HMAC with the app secret (`token.provider.secret`) and the stored callback URL; on a card action, re-fetch the card and `saveLink(transformCard(card, boardId, false))`.

- [ ] **Step 1: Write the failing tests**

Append to `trello.test.ts`:
```typescript
describe("setupWebhook", () => {
  it("skips registration for localhost URLs (dev guard)", async () => {
    const createWebhook = vi.fn().mockResolvedValue("http://localhost:8787/hook/x");
    const store = makeStore();
    const trello = makeTrello({ store, network: { createWebhook } });
    const apiCreate = vi.fn();
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createWebhook: apiCreate });

    await (trello as unknown as { setupWebhook: (b: string) => Promise<void> }).setupWebhook("b1");
    expect(apiCreate).not.toHaveBeenCalled();
    expect(store.map.has("webhook_id_b1")).toBe(false);
  });

  it("registers the webhook and stores id + callback url for non-localhost", async () => {
    const url = "https://api.plot.test/hook/abc";
    const createWebhook = vi.fn().mockResolvedValue(url);
    const store = makeStore();
    const trello = makeTrello({ store, network: { createWebhook } });
    const apiCreate = vi.fn().mockResolvedValue({ id: "wh1" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createWebhook: apiCreate });

    await (trello as unknown as { setupWebhook: (b: string) => Promise<void> }).setupWebhook("b1");
    expect(apiCreate).toHaveBeenCalledWith("b1", url);
    expect(store.map.get("webhook_id_b1")).toBe("wh1");
    expect(store.map.get("webhook_url_b1")).toBe(url);
  });
});

describe("onWebhook", () => {
  const url = "https://api.plot.test/hook/abc";
  const body = JSON.stringify({ action: { type: "updateCard", data: { card: { id: "card9" } } } });

  async function sign(secret: string, raw: string, cb: string) {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
    const s = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw + cb));
    return btoa(String.fromCharCode(...new Uint8Array(s)));
  }

  it("re-fetches the card and saves it when the signature is valid", async () => {
    const store = makeStore({ webhook_url_b1: url });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { saveLink } });
    const getCard = vi.fn().mockResolvedValue({ id: "card9", name: "C", desc: "", idList: "l1", idBoard: "b1", closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ getCard });
    const sig = await sign("SEC", body, url);

    await (trello as unknown as { onWebhook: (r: unknown, b: string) => Promise<void> }).onWebhook(
      { method: "POST", headers: { "x-trello-webhook": sig }, params: {}, body: JSON.parse(body), rawBody: body }, "b1",
    );
    expect(getCard).toHaveBeenCalledWith("card9");
    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(saveLink.mock.calls[0][0].source).toBe("trello:card:card9");
  });

  it("ignores a webhook with an invalid signature", async () => {
    const store = makeStore({ webhook_url_b1: url });
    const saveLink = vi.fn();
    const trello = makeTrello({ store, integrations: { saveLink } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ getCard: vi.fn() });

    await (trello as unknown as { onWebhook: (r: unknown, b: string) => Promise<void> }).onWebhook(
      { method: "POST", headers: { "x-trello-webhook": "bad" }, params: {}, body: JSON.parse(body), rawBody: body }, "b1",
    );
    expect(saveLink).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run tests → FAIL.**

- [ ] **Step 3: Implement in `trello.ts`** (replace the Task-5 `setupWebhook` stub)

```typescript
import { TrelloApi, verifyTrelloWebhook } from "./trello-api";
import type { WebhookRequest } from "@plotday/twister/tools/network";

async setupWebhook(boardId: string): Promise<void> {
  try {
    const webhookUrl = await this.tools.network.createWebhook({}, this.onWebhook, boardId);
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) return; // dev guard
    const api = await this.getApi(boardId);
    const webhook = await api.createWebhook(boardId, webhookUrl);
    if (webhook?.id) {
      await this.set(`webhook_id_${boardId}`, webhook.id);
      await this.set(`webhook_url_${boardId}`, webhookUrl);
    }
  } catch (error) {
    console.error("Failed to set up Trello webhook — real-time updates will not work:", error);
  }
}

private async onWebhook(request: WebhookRequest, boardId: string): Promise<void> {
  // Trello sends a HEAD to verify the callback URL on creation; nothing to do.
  if (request.method === "HEAD") return;
  if (!request.rawBody) return;

  const signature = request.headers["x-trello-webhook"];
  const callbackUrl = await this.get<string>(`webhook_url_${boardId}`);
  const token = await this.tools.integrations.get(boardId);
  const secret = token?.provider?.secret;
  if (!signature || !callbackUrl || !secret) return;

  const valid = await verifyTrelloWebhook(secret, request.rawBody, callbackUrl, signature);
  if (!valid) {
    console.warn("Trello webhook signature verification failed");
    return;
  }

  const action = (request.body as { action?: { data?: { card?: { id?: string } } } })?.action;
  const cardId = action?.data?.card?.id;
  if (!cardId) return;

  // Re-fetch the card for fresh, complete data (webhook payloads are partial).
  const api = await this.getApi(boardId);
  const card = await api.getCard(cardId);
  await this.tools.integrations.saveLink(transformCard(card, boardId, false));
}
```

- [ ] **Step 4: Run tests → PASS**; `pnpm exec tsc --noEmit` clean.

- [ ] **Step 5: Commit** (submodule): `git add connectors/trello/src/{trello.ts,trello.test.ts} && git commit -m "feat(trello): per-board webhooks with HMAC verify"`

---

### Task 7: `onLinkUpdated` — status / archive / title write-back

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `Link` (twister), `getApi`, `api.updateCard`.
- Produces: `onLinkUpdated(link)` — reads `link.meta.cardId`/`boardId`; maps `link.status` (a list id) → `updateCard(cardId, { idList })`; `link.archived` → `{ closed: true }`; `link.title` → `{ name }`.

- [ ] **Step 1: Write the failing test**

```typescript
describe("onLinkUpdated", () => {
  function linkWith(over: Record<string, unknown>) {
    return { meta: { cardId: "c1", boardId: "b1", idList: "l1" }, status: "l2", title: "C", archived: false, ...over } as any;
  }
  it("moves the card to the new list", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn().mockResolvedValue({});
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    await trello.onLinkUpdated(linkWith({ status: "l3" }));
    expect(updateCard).toHaveBeenCalledWith("c1", expect.objectContaining({ idList: "l3" }));
  });
  it("archives the card when archived=true", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn().mockResolvedValue({});
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    await trello.onLinkUpdated(linkWith({ archived: true }));
    expect(updateCard).toHaveBeenCalledWith("c1", expect.objectContaining({ closed: true }));
  });
  it("no-ops when meta.cardId is missing", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn();
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    await trello.onLinkUpdated({ meta: {}, status: "l2" } as any);
    expect(updateCard).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement**

```typescript
import type { Link } from "@plotday/twister";

async onLinkUpdated(link: Link): Promise<void> {
  const cardId = link.meta?.cardId as string | undefined;
  const boardId = link.meta?.boardId as string | undefined;
  if (!cardId || !boardId) return;
  const fields: { idList?: string; closed?: boolean; name?: string } = {};
  if (link.archived) fields.closed = true;
  if (link.status) fields.idList = link.status; // status === Trello list id
  if (link.title) fields.name = link.title;
  if (Object.keys(fields).length === 0) return;
  try {
    const api = await this.getApi(boardId);
    await api.updateCard(cardId, fields);
  } catch (error) {
    console.error("[trello] onLinkUpdated write-back failed:", error);
  }
}
```

- [ ] **Step 4: Run → PASS**; tsc clean.
- [ ] **Step 5: Commit** (submodule): `git commit -am "feat(trello): onLinkUpdated status/archive write-back"`

---

### Task 8: `onNoteCreated` + `onNoteUpdated` — comment write-back

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `Note`, `Thread`, `NoteWriteBackResult` (twister); `getApi`; `api.addComment`/`updateComment`/`updateCard`.
- Produces:
  - `onNoteCreated(note, thread)` → `addComment(cardId, note.content)`; return `{ key: "comment-"+action.id, externalContent: action.data.text }`.
  - `onNoteUpdated(note, thread)` → for `description` key: `updateCard(cardId, { desc })` → `{ externalContent }`; for `comment-{id}`: `updateComment(id, content)` → `{ externalContent }`.

- [ ] **Step 1: Write the failing test**

```typescript
describe("comment write-back", () => {
  const thread = { meta: { cardId: "c1", boardId: "b1" } } as any;
  it("onNoteCreated posts a comment and returns the keyed baseline", async () => {
    const trello = makeTrello();
    const addComment = vi.fn().mockResolvedValue({ id: "act5", data: { text: "hello" } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ addComment });
    const res = await trello.onNoteCreated({ content: "hello" } as any, thread);
    expect(addComment).toHaveBeenCalledWith("c1", "hello");
    expect(res).toEqual({ key: "comment-act5", externalContent: "hello" });
  });
  it("onNoteUpdated edits an existing comment", async () => {
    const trello = makeTrello();
    const updateComment = vi.fn().mockResolvedValue({ id: "act5", data: { text: "edited" } });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateComment });
    const res = await trello.onNoteUpdated({ key: "comment-act5", content: "edited" } as any, thread);
    expect(updateComment).toHaveBeenCalledWith("act5", "edited");
    expect(res).toEqual({ externalContent: "edited" });
  });
  it("onNoteUpdated maps the description note to the card desc", async () => {
    const trello = makeTrello();
    const updateCard = vi.fn().mockResolvedValue({ desc: "new desc" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCard });
    const res = await trello.onNoteUpdated({ key: "description", content: "new desc" } as any, thread);
    expect(updateCard).toHaveBeenCalledWith("c1", { desc: "new desc" });
    expect(res).toEqual({ externalContent: "new desc" });
  });
});
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement**

```typescript
import type { Note, Thread, NoteWriteBackResult } from "@plotday/twister";

async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  const cardId = thread.meta?.cardId as string | undefined;
  const boardId = thread.meta?.boardId as string | undefined;
  if (!cardId || !boardId) return;
  const api = await this.getApi(boardId);
  const action = await api.addComment(cardId, note.content ?? "");
  if (!action?.id) return;
  return { key: `comment-${action.id}`, externalContent: action.data.text };
}

async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  if (!note.key) return;
  const cardId = thread.meta?.cardId as string | undefined;
  const boardId = thread.meta?.boardId as string | undefined;
  if (!cardId || !boardId) return;
  const api = await this.getApi(boardId);
  if (note.key === "description") {
    const card = await api.updateCard(cardId, { desc: note.content ?? "" });
    return { externalContent: card.desc ?? note.content ?? "" };
  }
  const m = note.key.match(/^comment-(.+)$/);
  if (!m) return;
  const updated = await api.updateComment(m[1], note.content ?? "");
  return { externalContent: updated.data.text };
}
```

- [ ] **Step 4: Run → PASS**; tsc clean.
- [ ] **Step 5: Commit** (submodule): `git commit -am "feat(trello): comment write-back with baseline"`

---

### Task 9: `onCreateLink` — create a card from Plot

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `CreateLinkDraft`, `NewLinkWithNotes` (twister); `getApi`; `api.createCard`; `cardCreatedAt`.
- Produces: `onCreateLink(draft)` — if `draft.type !== "card"` return null; `createCard({ idList: draft.status, name: draft.title, desc: draft.noteContent })`; return the synced `NewLinkWithNotes` with `originatingNote { key: "description", externalContent: card.desc }`.

- [ ] **Step 1: Write the failing test**

```typescript
describe("onCreateLink", () => {
  it("creates a card in the chosen list and returns the synced link", async () => {
    const trello = makeTrello();
    const createCard = vi.fn().mockResolvedValue({
      id: "5f000000bbbbbbbbbbbbbbbb", name: "New card", desc: "body", idList: "l1", idBoard: "b1", closed: false, url: "https://trello.com/c/x", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
    });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ createCard });
    const link = await trello.onCreateLink({ channelId: "b1", type: "card", status: "l1", title: "New card", noteContent: "body", contacts: [] } as any);
    expect(createCard).toHaveBeenCalledWith({ idList: "l1", name: "New card", desc: "body" });
    expect(link!.source).toBe("trello:card:5f000000bbbbbbbbbbbbbbbb");
    expect(link!.status).toBe("l1");
    expect(link!.channelId).toBe("b1");
    expect(link!.originatingNote).toEqual({ key: "description", externalContent: "body" });
  });
  it("returns null for a non-card type", async () => {
    const trello = makeTrello();
    expect(await trello.onCreateLink({ type: "other" } as any)).toBeNull();
  });
});
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement**

```typescript
import type { CreateLinkDraft, NewLinkWithNotes } from "@plotday/twister";
import { cardCreatedAt } from "./trello-api";

async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
  if (draft.type !== "card") return null;
  const boardId = draft.channelId;
  const api = await this.getApi(boardId);
  const card = await api.createCard({
    idList: draft.status ?? "",
    name: draft.title,
    ...(draft.noteContent ? { desc: draft.noteContent } : {}),
  });
  if (!card?.id) return null;
  return {
    source: `trello:card:${card.id}`,
    type: "card",
    title: card.name,
    status: card.idList,
    created: cardCreatedAt(card.id),
    channelId: boardId,
    sourceUrl: card.url,
    meta: { syncProvider: "trello", boardId, cardId: card.id, idList: card.idList },
    // Bind the opening note to the card description so edits round-trip via onNoteUpdated.
    originatingNote: { key: "description", externalContent: card.desc ?? undefined },
  };
}
```

- [ ] **Step 4: Run → PASS**; tsc clean.
- [ ] **Step 5: Commit** (submodule): `git commit -am "feat(trello): onCreateLink create card"`

---

### Task 10: `onChannelDisabled` — teardown

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts` (extend)

**Interfaces:**
- Consumes: `getApi`, `api.deleteWebhook`, `this.tools.integrations.archiveLinks`, `this.clear`.
- Produces: `onChannelDisabled(channel)` — delete the Trello webhook (if stored), clear `webhook_id_/webhook_url_/sync_state_/sync_enabled_` keys, and `archiveLinks({ channelId: boardId })`.

- [ ] **Step 1: Write the failing test**

```typescript
describe("onChannelDisabled", () => {
  it("deletes the webhook, archives links, and clears state", async () => {
    const store = makeStore({ webhook_id_b1: "wh1", webhook_url_b1: "u", sync_enabled_b1: true });
    const archiveLinks = vi.fn().mockResolvedValue(undefined);
    const trello = makeTrello({ store, integrations: { archiveLinks } });
    const deleteWebhook = vi.fn().mockResolvedValue({});
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ deleteWebhook });

    await trello.onChannelDisabled({ id: "b1", title: "B" } as any);
    expect(deleteWebhook).toHaveBeenCalledWith("wh1");
    expect(archiveLinks).toHaveBeenCalledWith({ channelId: "b1" });
    expect(store.map.has("webhook_id_b1")).toBe(false);
    expect(store.map.has("sync_enabled_b1")).toBe(false);
  });
});
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** (replace the skeleton `onChannelDisabled`)

```typescript
async onChannelDisabled(channel: Channel): Promise<void> {
  const boardId = channel.id;
  const webhookId = await this.get<string>(`webhook_id_${boardId}`);
  if (webhookId) {
    try {
      const api = await this.getApi(boardId);
      await api.deleteWebhook(webhookId);
    } catch (error) {
      console.warn("Failed to delete Trello webhook:", error);
    }
  }
  await this.clear(`webhook_id_${boardId}`);
  await this.clear(`webhook_url_${boardId}`);
  await this.clear(`sync_state_${boardId}`);
  await this.clear(`sync_enabled_${boardId}`);
  await this.tools.integrations.archiveLinks({ channelId: boardId });
}
```

- [ ] **Step 4: Run → PASS**; tsc clean.
- [ ] **Step 5: Commit** (submodule): `git commit -am "feat(trello): onChannelDisabled teardown"`

---

### Task 11: Registration + finalize

**Files:**
- Modify: `apps/site/app/data/connections.ts` (MAIN repo)
- Modify: `workers/api/src/app/connections.ts` (MAIN repo)
- Verification only otherwise.

**Interfaces:** none (registration + sweep).

- [ ] **Step 1: Flip Trello to available in both connection registries**

In `apps/site/app/data/connections.ts` find the Trello entry (`name: "Trello"`, ~line 244-250) and change `available: false` → `available: true`.
In `workers/api/src/app/connections.ts` find the Trello entry (~line 147) and change `available: false` → `available: true` (add the field if the shape uses it; match the neighbors like Monday/Linear).

> NOTE: read both neighbors (e.g. the Linear entry) first to match the exact field shape — some entries carry `available`, others omit it to mean available. Mirror whatever makes Trello appear as connectable alongside Linear.

- [ ] **Step 2: Full connector test + build sweep**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/connectors/trello
pnpm test && pnpm exec tsc --noEmit && pnpm build
```
Expected: all tests pass, tsc clean, build emits `dist/`.

- [ ] **Step 3: Lint the connector + the changed main-repo files**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/connectors/trello && pnpm lint
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector && pnpm --filter @plotday/site lint 2>/dev/null || (cd apps/site && pnpm lint)
```
Fix any lint errors in the Trello files / the two connections.ts edits. (If site lint surfaces unrelated pre-existing errors, note them, don't fix.)

- [ ] **Step 4: Commit** — connector dist is gitignored; commit the source + the main-repo flips separately.

```bash
# main repo: the availability flips
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
git add apps/site/app/data/connections.ts workers/api/src/app/connections.ts
git commit -m "feat(trello): mark Trello connection available"
# submodule: any final lint fixups
cd public && git add connectors/trello && git commit -m "chore(trello): lint fixups" --allow-empty
```

---

## Out of scope (handled elsewhere)

- **Checklists** (card `checkItems`) → Plan 4 (structured-items model). `transformCard` deliberately does not read `card.checklists`.
- **Due dates, labels** → deferred (spec non-goals).
- **Provisioning** (`AUTH_TRELLO_ID`/`SECRET` → 1Password → `sync-github-secrets`) and **deploy** (`plot deploy` reads `plotTwistId`) → human-gated OPS, out of plan scope. The connector can't run end-to-end until provisioned.
- **Submodule gitlink bump + PRs** → finishing step (the submodule branch must merge/PR first, then the main-repo gitlink is re-pointed).

## Self-Review

**Spec coverage (Part 2):** board→channel + getChannels (T4) ✓ · card→link + source/meta/status (T3) ✓ · lists→dynamic statuses + done-heuristic (T4) ✓ · onChannelEnabled→runTask webhook+sync (T5,T6) ✓ · syncBatch pagination + initialSync + channelSyncCompleted (T5) ✓ · description/comment/attachment notes (T3) ✓ · members→contacts (T3) ✓ · webhooks + HMAC (T2,T6) ✓ · onLinkUpdated status/archive (T7) ✓ · onNoteCreated/Updated comments + baseline (T8) ✓ · onCreateLink + compose (T1 linkType, T9) ✓ · onChannelDisabled + archiveLinks (T10) ✓ · connections.ts flips (T11) ✓ · source `trello:card:{id}` + `syncProvider` meta (T3) ✓ · contentType markdown (default, T3) ✓.

**Type consistency:** `TrelloCard`/`TrelloMember`/`TrelloCommentAction` defined in T2, consumed identically in T3/T5/T6/T9. `transformCard(card, boardId, initialSync)` signature stable across T3/T5/T6. `getApi(channelId)` defined T4, used T4–T10. `meta` shape `{ syncProvider, boardId, cardId, idList }` written in T3/T9 and read in T6/T7/T8/T10. `sync_state_{boardId}` / `webhook_id_{boardId}` / `webhook_url_{boardId}` / `sync_enabled_{boardId}` key names consistent across T5/T6/T10.

**Placeholder scan:** the `getChannels` token-resolution NOTE (T4) and the `connections.ts` shape NOTE (T11) are verification instructions with a concrete default + a fallback, not unfilled blanks. The `setupWebhook` stub in T5 is explicitly temporary and filled in T6.
