# Outlook Mail Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `@plotday/connector-outlook-mail` in `public/connectors/outlook-mail/` at full Gmail-connector parity (initial + incremental sync, contact enrichment, two-way unread/flagged sync, reply/compose, attachments, classifier facets) for personal and work Microsoft accounts.

**Architecture:** Conversation-per-thread sync driven by one mailbox-wide Graph change-notification subscription (`/me/messages`, synchronous webhook for the validationToken handshake) with per-folder delta-query catch-up inside a 60-minute self-heal cycle. Folders are channels gating backfill only. Structure, state keys, and echo-prevention discipline mirror `public/connectors/gmail/src/gmail.ts`; Graph subscription mechanics mirror `public/connectors/outlook-calendar/`.

**Tech Stack:** TypeScript, `@plotday/twister` (workspace), `@plotday/email-classifier` (workspace), Microsoft Graph v1.0, vitest.

**Spec:** `docs/superpowers/specs/2026-06-10-outlook-mail-connector-design.md`

---

## Reference files (read before each task)

| Purpose | File |
|---|---|
| Connector template (channels, sync, webhooks, write-backs, compose) | `public/connectors/gmail/src/gmail.ts` |
| Transform + parsing template | `public/connectors/gmail/src/gmail-api.ts` |
| Graph client + subscription mechanics | `public/connectors/outlook-calendar/src/graph-api.ts`, `src/outlook-calendar.ts` |
| Enrichment holder-walk pattern | `public/connectors/google-contacts/src/people-api.ts` |
| Facets | `public/connectors/gmail/src/gmail-facets.ts`, `public/libs/email-classifier/src/classify-email.ts` |
| Conventions + checklist | `public/connectors/AGENTS.md` |

## Locked design constants

- Package: `@plotday/connector-outlook-mail`, `plotTwistId: "6c3773dd-e820-4043-a5bc-f4e299ca1a19"`, displayName `Outlook Mail`, description `Send and reply to Outlook email, tracking threads for follow-up and snoozing the rest.`, category `messaging`.
- Scopes: `https://graph.microsoft.com/mail.readwrite`, `https://graph.microsoft.com/mail.send` + enrichment scopes `https://graph.microsoft.com/people.read`, `https://graph.microsoft.com/contacts.read` (merged via `Integrations.MergeScopes`).
- `source` = `outlook-mail:{accountEmailLower}:{conversationId}` (mailbox-qualified, immutable). `note.key` = `internetMessageId` (survives folder moves; identical for the sent-echo). All Graph calls send `Prefer: IdType="ImmutableId"` so stored Graph message ids (attachment refs, msg-channel cache) survive folder moves.
- Subscription: resource `/me/messages`, changeTypes `created,updated`, lifetime 3 days, renewal lead 24h, preemptive renew window 36h, self-heal every 60 min, max 20 delta pages per heal per folder.
- Excluded well-known folders (never channels, never synced): `junkemail`, `deleteditems`, `drafts`, `outbox`, `conversationhistory`. Default-enabled channels: `inbox`, `sentitems`.
- Avatar enrichment is **names-only** in v1: Graph photo endpoints return auth-gated binary (no public URL to put in `contact.avatar`). Documented in README; Gravatar fallback covers the rest.
- Attachments: direct `fileAttachment` POST ≤ 3 MB; upload session above (chunks of 3,276,800 bytes = 10×320 KiB). Inline attachments (`isInline`) skipped on sync-in.
- No core-repo (`workers/api`) changes. No Twister changes → **no changeset**.

## Workspace setup (before Task 1)

Work in the main repo. The `public/` submodule is on `main` (clean). Create the feature branch **inside the submodule** (purely additive — safe for concurrent agents):

```bash
cd /Users/kris.braun/code/plot/public && git checkout -b outlook-mail-connector
```

All commits for Tasks 1–7 happen inside `public/` on this branch. `pnpm-workspace.yaml` globs (`public/connectors/*` in both root and public workspaces) already cover the new package — no workspace edits.

---

### Task 1: Package scaffold

**Files:**
- Create: `public/connectors/outlook-mail/package.json`
- Create: `public/connectors/outlook-mail/tsconfig.json`
- Create: `public/connectors/outlook-mail/vitest.config.ts`
- Create: `public/connectors/outlook-mail/src/index.ts`
- Create: `public/connectors/outlook-mail/README.md`
- Create: `public/connectors/outlook-mail/LICENSE`

- [ ] **Step 1.1: Write package.json**

```json
{
  "name": "@plotday/connector-outlook-mail",
  "plotTwistId": "6c3773dd-e820-4043-a5bc-f4e299ca1a19",
  "displayName": "Outlook Mail",
  "description": "Send and reply to Outlook email, tracking threads for follow-up and snoozing the rest.",
  "category": "messaging",
  "logoUrl": "https://api.iconify.design/simple-icons/microsoftoutlook.svg",
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
    "@plotday/email-classifier": "workspace:^",
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": {
    "typescript": "^5.9.3",
    "vitest": "^2.1.8"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/plotday/plot.git",
    "directory": "connectors/outlook-mail"
  },
  "homepage": "https://plot.day",
  "bugs": { "url": "https://github.com/plotday/plot/issues" },
  "keywords": ["plot", "connector", "outlook", "microsoft", "email", "messaging"]
}
```

- [ ] **Step 1.2: tsconfig.json + vitest.config.ts** — copy verbatim from `public/connectors/gmail/tsconfig.json` and `public/connectors/gmail/vitest.config.ts` (8 + 10 lines, no edits).

- [ ] **Step 1.3: src/index.ts**

```typescript
export { default, OutlookMail } from "./outlook-mail";
```

- [ ] **Step 1.4: LICENSE** — copy `public/connectors/gmail/LICENSE` (or `outlook-calendar`'s) verbatim. **README.md** — short: what it syncs (mail folders → threads, one note per message), scopes table (incl. why People.Read/Contacts.Read), two-way behaviors (unread ↔ isRead, To Do ↔ flag), the names-only avatar limitation, personal-vs-work degradation notes.

- [ ] **Step 1.5: Install + verify scaffold**

Run from repo root: `pnpm install`
Expected: lockfile picks up `@plotday/connector-outlook-mail`, no errors. (`src/outlook-mail.ts` doesn't exist yet so don't build.)

- [ ] **Step 1.6: Commit** (in `public/`): `git add connectors/outlook-mail && git commit -m "feat(outlook-mail): scaffold connector package"`

---

### Task 2: Quote-stripping helpers (`email-parsing.ts`)

Graph returns structured recipients (no RFC 5322 header parsing needed) and JSON-bodied sends (no MIME building, no header-injection surface). The only Gmail parsing code we need is quote stripping.

**Files:**
- Create: `public/connectors/outlook-mail/src/email-parsing.ts`
- Test: `public/connectors/outlook-mail/src/email-parsing.test.ts`

- [ ] **Step 2.1: Copy helpers.** Create `email-parsing.ts` with a header comment `// Quote-stripping helpers shared with the Gmail connector (copied from gmail/src/gmail-api.ts — keep in sync).` and copy **verbatim** from `public/connectors/gmail/src/gmail-api.ts`:
  - `findOutlookHeaderTagAgnostic` (lines 522–528, keep `export`)
  - `stripQuotedReply` (lines 535–637, keep `export`)
  - `isForwardedMessage` (lines 646–654, not exported)

- [ ] **Step 2.2: Write sanity tests** (`email-parsing.test.ts`):

```typescript
import { describe, expect, it } from "vitest";
import { stripQuotedReply } from "./email-parsing";

describe("stripQuotedReply", () => {
  it("cuts Outlook appendonsend reply chains", () => {
    const html =
      `<div>New content</div><div id="appendonsend"></div><div>From: A<br>Sent: B<br>To: C<br>Subject: D</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>New content</div>");
  });

  it("cuts gmail_quote blocks from cross-client replies", () => {
    const html = `<p>Reply</p><div class="gmail_quote">old</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<p>Reply</p>");
  });

  it("preserves forwarded messages", () => {
    const text = "FYI\n---------- Forwarded message ---------\nFrom: x";
    expect(stripQuotedReply(text, "text")).toBe(text);
  });

  it("cuts plain-text 'On ... wrote:' quotes", () => {
    const text = "Thanks!\nOn Tue, Jun 10, 2026, Kris wrote:\n> earlier";
    expect(stripQuotedReply(text, "text")).toBe("Thanks!");
  });
});
```

- [ ] **Step 2.3: Run** `cd public/connectors/outlook-mail && pnpm test` → 4 passing.

- [ ] **Step 2.4: Commit**: `git commit -m "feat(outlook-mail): quote-stripping helpers (from gmail)"` (add both files).

---

### Task 3: Graph mail client + conversation transform (`graph-mail-api.ts`)

**Files:**
- Create: `public/connectors/outlook-mail/src/graph-mail-api.ts`
- Test: `public/connectors/outlook-mail/src/graph-mail-api.test.ts`

- [ ] **Step 3.1: Types + error + client.** Write `graph-mail-api.ts`:

```typescript
import { ActionType } from "@plotday/twister/plot";
import type { Action, NewActor, NewContact, NewLinkWithNotes } from "@plotday/twister/plot";
import { stripQuotedReply } from "./email-parsing";

export type GraphRecipient = { emailAddress?: { name?: string; address?: string } };
export type GraphHeader = { name: string; value: string };

export type GraphMessage = {
  id: string;
  conversationId?: string;
  internetMessageId?: string;
  subject?: string;
  bodyPreview?: string;
  body?: { contentType: "text" | "html"; content?: string };
  from?: GraphRecipient;
  toRecipients?: GraphRecipient[];
  ccRecipients?: GraphRecipient[];
  replyTo?: GraphRecipient[];
  receivedDateTime?: string;
  sentDateTime?: string;
  isRead?: boolean;
  isDraft?: boolean;
  flag?: { flagStatus?: "notFlagged" | "complete" | "flagged" };
  importance?: string;
  inferenceClassification?: "focused" | "other";
  parentFolderId?: string;
  hasAttachments?: boolean;
  webLink?: string;
  internetMessageHeaders?: GraphHeader[];
};

export type GraphMailFolder = {
  id: string;
  displayName: string;
  parentFolderId?: string;
  totalItemCount?: number;
  isHidden?: boolean;
};

export type GraphAttachmentMeta = {
  id: string;
  name: string;
  contentType: string | null;
  size: number | null;
  isInline: boolean;
  odataType: string; // "#microsoft.graph.fileAttachment" | itemAttachment | referenceAttachment
};

/** Well-known folder name → folder id map (only the ones we care about). */
export type WellKnownFolders = Partial<Record<
  "inbox" | "sentitems" | "archive" | "junkemail" | "deleteditems" | "drafts" | "outbox" | "conversationhistory",
  string
>>;

export const EXCLUDED_WELL_KNOWN = [
  "junkemail", "deleteditems", "drafts", "outbox", "conversationhistory",
] as const;

export class GraphMailApiError extends Error {
  constructor(public status: number, public statusText: string, body: string) {
    super(`Graph API error: ${status} ${statusText} - ${body}`);
    this.name = "GraphMailApiError";
  }
}

/** OData string-literal quoting: single quotes double inside '...'. */
export function odataQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

const GRAPH = "https://graph.microsoft.com/v1.0";

/**
 * $select used wherever full message content is needed. internetMessageHeaders
 * is intentionally absent — Graph only reliably returns it on single-message
 * GETs, so facets fetch it separately (getInternetMessageHeaders).
 */
export const MESSAGE_SELECT = [
  "id", "conversationId", "internetMessageId", "subject", "bodyPreview", "body",
  "from", "toRecipients", "ccRecipients", "replyTo", "receivedDateTime",
  "sentDateTime", "isRead", "isDraft", "flag", "importance",
  "inferenceClassification", "parentFolderId", "hasAttachments", "webLink",
].join(",");

export class GraphMailApi {
  constructor(public accessToken: string) {}

  /**
   * Generic Graph call. Sends Prefer: ImmutableId (stable message ids across
   * folder moves) + html body. Returns null on 404 (deleted upstream).
   * Retries once on 429/503 honoring Retry-After (capped 15s).
   */
  public async call(
    method: string,
    url: string,
    params?: Record<string, string>,
    body?: unknown,
    extraHeaders?: Record<string, string>,
  ): Promise<any> { /* full implementation in step */ }

  async getProfile(): Promise<{ email: string }>
  async getMailFolders(): Promise<GraphMailFolder[]>           // pages /me/mailFolders?$top=100 via @odata.nextLink
  async getWellKnownFolderIds(): Promise<WellKnownFolders>     // GET /me/mailFolders/{name} per name, 404-tolerant
  async getMessagesPage(args: { folderId?: string; nextLink?: string; top?: number; since?: Date }):
    Promise<{ messages: GraphMessage[]; nextLink: string | null }>
  async getMessage(id: string, select?: string): Promise<GraphMessage | null>
  async getConversationMessages(conversationId: string): Promise<GraphMessage[]> // /me/messages?$filter=conversationId eq '<q>'&$top=100, sorted asc client-side (no $orderby with this $filter)
  async getInternetMessageHeaders(messageId: string): Promise<GraphHeader[] | null>
  async listAttachments(messageId: string): Promise<GraphAttachmentMeta[]>
  async getAttachment(messageId: string, attachmentId: string):
    Promise<{ contentBytes?: string; contentType?: string; name?: string } | null>
  async updateMessage(id: string, patch: Record<string, unknown>): Promise<void>  // PATCH /me/messages/{id}
  async createDraft(draft: Record<string, unknown>): Promise<GraphMessage>        // POST /me/messages
  async createReplyDraft(messageId: string): Promise<GraphMessage>                // POST /me/messages/{id}/createReply
  async send(messageId: string): Promise<void>                                    // POST /me/messages/{id}/send (202)
  async addFileAttachment(messageId: string, att: { name: string; contentType: string; contentBytes: string }): Promise<void>
  async uploadLargeAttachment(messageId: string, att: { name: string; contentType: string; data: Uint8Array }): Promise<void>
  async createSubscription(args: { notificationUrl: string; clientState: string; expirationDateTime: Date }):
    Promise<{ id: string; expirationDateTime: string }>                            // resource "/me/messages", changeType "created,updated"
  async renewSubscription(id: string, expirationDateTime: Date): Promise<void>
  async deleteSubscription(id: string): Promise<void>
  async deltaPage(url: string): Promise<{ messages: GraphMessage[]; nextLink: string | null; deltaLink: string | null }>
  buildInitialDeltaUrl(folderId: string, since: Date): string
  // `${GRAPH}/me/mailFolders/${encodeURIComponent(folderId)}/messages/delta?$filter=receivedDateTime ge ${since.toISOString()}&$select=id,conversationId,parentFolderId,isDraft`
}
```

Implementation requirements for `call()` (write in full):

```typescript
  public async call(
    method: string,
    url: string,
    params?: Record<string, string>,
    body?: unknown,
    extraHeaders?: Record<string, string>,
  ): Promise<any> {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      // ImmutableId keeps message ids stable across folder moves (attachment
      // refs + msg-channel cache depend on it). html body-content keeps the
      // transform's contentType handling deterministic.
      Prefer: `IdType="ImmutableId", outlook.body-content-type="html"`,
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...extraHeaders,
    };
    for (let attempt = 0; ; attempt++) {
      const response = await fetch(url + query, {
        method,
        headers,
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
      if (response.status === 404) return null;
      if ((response.status === 429 || response.status === 503) && attempt === 0) {
        const retryAfter = Number(response.headers.get("Retry-After") ?? "2");
        await new Promise((r) => setTimeout(r, Math.min(retryAfter, 15) * 1000));
        continue;
      }
      if (!response.ok) {
        throw new GraphMailApiError(response.status, response.statusText, await response.text());
      }
      if (response.status === 202 || response.status === 204) return {};
      const text = await response.text();
      return text ? JSON.parse(text) : {};
    }
  }
```

Other method notes (each ~5–15 lines, follow `outlook-calendar/src/graph-api.ts` shapes):
- `getProfile`: GET `/me` → `{ email: (data.mail || data.userPrincipalName || "").toLowerCase() }`.
- `getWellKnownFolderIds`: loop the 8 names, `GET ${GRAPH}/me/mailFolders/${name}` — `call` returns null on 404 (e.g. no `archive` on some consumer accounts); collect `{ name: id }`.
- `getMessagesPage`: if `nextLink` given, `call("GET", nextLink)` raw; else build `${GRAPH}/me/mailFolders/${encodeURIComponent(folderId)}/messages` with params `$top` (default "20"), `$orderby: "receivedDateTime desc"`, `$select: MESSAGE_SELECT`, and `$filter: \`receivedDateTime ge ${since.toISOString()}\`` when `since` set. Return `{ messages: data?.value ?? [], nextLink: data?.["@odata.nextLink"] ?? null }`.
- `getConversationMessages`: `$filter=conversationId eq ${odataQuote(conversationId)}`, `$top: "100"`, `$select: MESSAGE_SELECT`; sort ascending by `receivedDateTime ?? sentDateTime` before returning. Follow `@odata.nextLink` up to 5 pages.
- `getInternetMessageHeaders`: GET `/me/messages/{id}?$select=internetMessageHeaders` → `data?.internetMessageHeaders ?? null`.
- `listAttachments`: GET `/me/messages/{id}/attachments?$select=id,name,contentType,size,isInline` → map with `odataType: a["@odata.type"]`.
- `createSubscription`: POST `${GRAPH}/subscriptions` body `{ changeType: "created,updated", notificationUrl, resource: "/me/messages", expirationDateTime: ISO, clientState }`.
- `uploadLargeAttachment`: POST `/me/messages/{id}/attachments/createUploadSession` body `{ AttachmentItem: { attachmentType: "file", name, size: data.length, contentType } }` → `uploadUrl`; PUT chunks of `3276800` bytes with `Content-Range: bytes start-end/total` (no auth header on the upload URL; use bare `fetch`, throw on !ok).
- `deltaPage`: GET url (already absolute); 410 `GraphMailApiError` propagates to caller (caller reseeds).

- [ ] **Step 3.2: Pure helpers + transform** (same file):

```typescript
/** Lowercased addresses from structured recipients (skips blanks). */
export function recipientEmails(recipients: GraphRecipient[] | undefined): string[] {
  return (recipients ?? [])
    .map((r) => r.emailAddress?.address?.trim())
    .filter((a): a is string => !!a);
}

/**
 * Mailing-list "Name via List" display-name decoration — the only rewrite
 * signal available without per-message internetMessageHeaders. Suppress the
 * display name on the From contact when it fires (see gmail's
 * isFromAddressRewritten for the full rationale).
 */
export function isViaRewrittenName(name: string | undefined): boolean {
  return !!name && /\svia\s/i.test(name);
}

function recipientToContact(r: GraphRecipient, suppressName = false): NewContact | null {
  const address = r.emailAddress?.address?.trim();
  if (!address) return null;
  const name = suppressName ? undefined : r.emailAddress?.name || undefined;
  return {
    email: address,
    ...(name ? { name } : {}),
    // Graph messages don't expose the counterparty's AAD object id, so key
    // contact_external_account on the lowercased address (same tradeoff and
    // rationale as gmail's parseEmailAddressesToContacts).
    source: { accountId: address.toLowerCase() },
  };
}

export function isConversationUnread(messages: GraphMessage[]): boolean {
  return messages.some((m) => !m.isDraft && m.isRead === false);
}

export function isConversationFlagged(messages: GraphMessage[]): boolean {
  return messages.some((m) => !m.isDraft && m.flag?.flagStatus === "flagged");
}

export function conversationSource(accountEmail: string, conversationId: string): string {
  return `outlook-mail:${accountEmail.toLowerCase()}:${conversationId}`;
}

export function messageDate(m: GraphMessage): Date {
  return new Date(m.receivedDateTime ?? m.sentDateTime ?? Date.now());
}

/** Sort a conversation oldest-first. */
export function sortConversation(messages: GraphMessage[]): GraphMessage[] {
  return [...messages].sort((a, b) => messageDate(a).getTime() - messageDate(b).getTime());
}

export function transformOutlookConversation(opts: {
  messages: GraphMessage[];
  attachmentsByMessageId: Map<string, GraphAttachmentMeta[]>;
  accountEmail: string;
}): NewLinkWithNotes {
  // 1. sort; drop isDraft (Outlook autosaves would churn notes, same as gmail).
  // 2. empty → { type: "email", title: "", notes: [] }.
  // 3. parent = first; source = conversationSource(accountEmail, parent.conversationId!).
  // 4. participants: Map<lowerEmail, NewContact> over every message's
  //    from (suppressName = isViaRewrittenName) + toRecipients + ccRecipients.
  // 5. per-message note:
  //    - key: m.internetMessageId ?? m.id
  //    - author: { email: from.address, name? (via-suppressed) }
  //    - content: stripQuotedReply(m.body?.content ?? "", ct) || m.bodyPreview || ""
  //    - contentType: m.body?.contentType === "html" ? "html" : "text"
  //    - actions: fileRef per non-inline "#microsoft.graph.fileAttachment"
  //      → { type: ActionType.fileRef, ref: `${m.id}:${att.id}`, fileName: att.name,
  //          fileSize: att.size, mimeType: att.contentType ?? "application/octet-stream" }
  //      (actions.length ? actions : null)
  //    - accessContacts: from + to + cc of THIS message
  //    - created: messageDate(m); checkForTasks: true
  // 6. link: { source, type: "email", title: parent.subject || "Email",
  //    created: messageDate(parent), access: "private",
  //    accessContacts: [...participants.values()],
  //    meta: { conversationId: parent.conversationId },
  //    sourceUrl: lastNonDraft.webLink ?? null, preview: parent.bodyPreview || null,
  //    notes }
}
```

Write the transform body in full following the comment skeleton — it is a direct structural port of `transformGmailThread` (`gmail-api.ts:688–827`) with structured recipients instead of header parsing.

- [ ] **Step 3.3: Write tests** (`graph-mail-api.test.ts`) — pure functions only, no fetch mocks:

```typescript
import { describe, expect, it } from "vitest";
import {
  conversationSource, isConversationFlagged, isConversationUnread,
  isViaRewrittenName, odataQuote, recipientEmails, sortConversation,
  transformOutlookConversation, type GraphAttachmentMeta, type GraphMessage,
} from "./graph-mail-api";

const msg = (over: Partial<GraphMessage>): GraphMessage => ({
  id: "id-1", conversationId: "conv-1", internetMessageId: "<m1@x>",
  subject: "Hello", bodyPreview: "preview",
  body: { contentType: "html", content: "<p>Hi</p>" },
  from: { emailAddress: { name: "Ann", address: "ann@x.com" } },
  toRecipients: [{ emailAddress: { name: "Bob", address: "bob@y.com" } }],
  ccRecipients: [], receivedDateTime: "2026-06-01T10:00:00Z",
  isRead: true, isDraft: false, flag: { flagStatus: "notFlagged" },
  parentFolderId: "f-inbox", hasAttachments: false, webLink: "https://outlook.office.com/owa/x",
  ...over,
});

describe("transformOutlookConversation", () => {
  const base = {
    attachmentsByMessageId: new Map<string, GraphAttachmentMeta[]>(),
    accountEmail: "Me@Work.com",
  };

  it("maps a two-message conversation to one link with imid-keyed notes", () => {
    const link = transformOutlookConversation({ ...base, messages: [
      msg({}),
      msg({ id: "id-2", internetMessageId: "<m2@x>", receivedDateTime: "2026-06-01T11:00:00Z",
        from: { emailAddress: { name: "Bob", address: "bob@y.com" } } }),
    ]});
    expect(link.source).toBe("outlook-mail:me@work.com:conv-1");
    expect(link.title).toBe("Hello");
    expect(link.notes).toHaveLength(2);
    expect((link.notes![0] as { key: string }).key).toBe("<m1@x>");
    expect((link.notes![1] as { key: string }).key).toBe("<m2@x>");
    expect((link.notes![0] as { contentType: string }).contentType).toBe("html");
    const emails = (link.accessContacts as Array<{ email: string }>).map((c) => c.email).sort();
    expect(emails).toEqual(["ann@x.com", "bob@y.com"]);
  });

  it("skips drafts and returns empty link when only drafts exist", () => {
    const link = transformOutlookConversation({ ...base, messages: [msg({ isDraft: true })] });
    expect(link.notes).toHaveLength(0);
  });

  it("suppresses via-rewritten display names on the From contact", () => {
    const link = transformOutlookConversation({ ...base, messages: [
      msg({ from: { emailAddress: { name: "Cloudflare via Plot Team", address: "team@plot.day" } } }),
    ]});
    const team = (link.accessContacts as Array<{ email: string; name?: string }>)
      .find((c) => c.email === "team@plot.day");
    expect(team?.name).toBeUndefined();
  });

  it("emits fileRef actions for non-inline file attachments only", () => {
    const atts = new Map([["id-1", [
      { id: "a1", name: "doc.pdf", contentType: "application/pdf", size: 123, isInline: false,
        odataType: "#microsoft.graph.fileAttachment" },
      { id: "a2", name: "logo.png", contentType: "image/png", size: 5, isInline: true,
        odataType: "#microsoft.graph.fileAttachment" },
      { id: "a3", name: "evt", contentType: null, size: null, isInline: false,
        odataType: "#microsoft.graph.itemAttachment" },
    ]]]);
    const link = transformOutlookConversation({ ...base, attachmentsByMessageId: atts,
      messages: [msg({ hasAttachments: true })] });
    const actions = (link.notes![0] as { actions: Array<{ ref: string }> }).actions;
    expect(actions).toHaveLength(1);
    expect(actions[0].ref).toBe("id-1:a1");
  });
});

describe("conversation state helpers", () => {
  it("unread when any non-draft message is unread", () => {
    expect(isConversationUnread([msg({}), msg({ isRead: false })])).toBe(true);
    expect(isConversationUnread([msg({}), msg({ isRead: false, isDraft: true })])).toBe(false);
  });
  it("flagged when any message is flagged", () => {
    expect(isConversationFlagged([msg({ flag: { flagStatus: "flagged" } })])).toBe(true);
    expect(isConversationFlagged([msg({})])).toBe(false);
  });
});

describe("small helpers", () => {
  it("odataQuote doubles single quotes", () => {
    expect(odataQuote("a'b")).toBe("'a''b'");
  });
  it("recipientEmails skips blanks", () => {
    expect(recipientEmails([{ emailAddress: { address: " a@b.c " } }, { emailAddress: {} }]))
      .toEqual(["a@b.c"]);
  });
  it("isViaRewrittenName", () => {
    expect(isViaRewrittenName("X via Team")).toBe(true);
    expect(isViaRewrittenName("Xavier")).toBe(false);
  });
  it("sortConversation orders oldest first", () => {
    const out = sortConversation([
      msg({ id: "b", receivedDateTime: "2026-06-02T00:00:00Z" }),
      msg({ id: "a", receivedDateTime: "2026-06-01T00:00:00Z" }),
    ]);
    expect(out.map((m) => m.id)).toEqual(["a", "b"]);
  });
  it("conversationSource lowercases the mailbox", () => {
    expect(conversationSource("A@B.com", "c1")).toBe("outlook-mail:a@b.com:c1");
  });
});
```

- [ ] **Step 3.4: Run tests** `pnpm test` → all passing. Fix transform until green.
- [ ] **Step 3.5: Commit**: `git commit -m "feat(outlook-mail): Graph mail client and conversation transform"`.

---

### Task 4: Facets (`outlook-facets.ts`)

**Files:**
- Create: `public/connectors/outlook-mail/src/outlook-facets.ts`
- Test: `public/connectors/outlook-mail/src/outlook-facets.test.ts`

- [ ] **Step 4.1: Implement** (port of `gmail-facets.ts` over Graph shapes):

```typescript
import { classifyEmail, type EmailSignals } from "@plotday/email-classifier";
import type { ThreadFacets } from "@plotday/twister/facets";
import type { GraphHeader, GraphMessage } from "./graph-mail-api";

function header(headers: GraphHeader[] | null, name: string): string | null {
  const h = headers?.find((x) => x.name.toLowerCase() === name.toLowerCase());
  return h?.value || null;
}

/**
 * Compute facets for an Outlook conversation's parent message. `headers` is
 * the parent's internetMessageHeaders (separate single-message fetch; null
 * when that fetch failed — header-driven signals just stay null).
 * `inferenceClassification === "other"` (Focused Inbox's bulk bucket) maps to
 * the classifier's CATEGORY_UPDATES slot so short automated "Other" mail
 * classifies as notification, mirroring Gmail's category labels.
 */
export function outlookFacets(
  headers: GraphHeader[] | null,
  message: GraphMessage,
  bodyText: string,
): ThreadFacets {
  const signals: EmailSignals = {
    listId: header(headers, "List-Id"),
    listUnsubscribe: header(headers, "List-Unsubscribe"),
    precedence: header(headers, "Precedence"),
    autoSubmitted: header(headers, "Auto-Submitted"),
    returnPath: header(headers, "Return-Path"),
    importance: message.importance ?? header(headers, "Importance") ?? header(headers, "X-Priority"),
    fromAddress: message.from?.emailAddress?.address?.toLowerCase() ?? null,
    recipientCount: (message.toRecipients?.length ?? 0) + (message.ccRecipients?.length ?? 0),
    isReply:
      header(headers, "In-Reply-To") !== null ||
      header(headers, "References") !== null ||
      /^re:/i.test(message.subject ?? ""),
    subject: message.subject ?? null,
    bodyLength: bodyText.length,
    gmailCategories: message.inferenceClassification === "other" ? ["CATEGORY_UPDATES"] : [],
  };
  return classifyEmail(signals);
}
```

- [ ] **Step 4.2: Tests** (`outlook-facets.test.ts`):

```typescript
import { describe, expect, it } from "vitest";
import { outlookFacets } from "./outlook-facets";
import type { GraphMessage } from "./graph-mail-api";

const m = (over: Partial<GraphMessage>): GraphMessage => ({
  id: "1", subject: "Hi", from: { emailAddress: { address: "ann@x.com" } },
  toRecipients: [{ emailAddress: { address: "me@y.com" } }], ccRecipients: [],
  ...over,
});

describe("outlookFacets", () => {
  it("newsletter with List-Id → automated/list", () => {
    const f = outlookFacets(
      [{ name: "List-Id", value: "<news.example.com>" }],
      m({}),
      "x".repeat(2000),
    );
    expect(f.automation).toBe("automated");
    expect(f.reach).toBe("list");
    expect(f.format).toBe("reading");
  });

  it("plain human reply → human/direct/message", () => {
    const f = outlookFacets([{ name: "In-Reply-To", value: "<a@b>" }], m({ subject: "Re: Hi" }), "short");
    expect(f.automation).toBe("human");
    expect(f.reach).toBe("direct");
    expect(f.format).toBe("message");
  });

  it("short Other-inbox automated mail → notification (no headers available)", () => {
    const f = outlookFacets(null, m({
      inferenceClassification: "other",
      from: { emailAddress: { address: "noreply@svc.com" } },
    }), "tiny");
    expect(f.automation).toBe("automated");
    expect(f.format).toBe("notification");
  });

  it("null headers degrade gracefully", () => {
    const f = outlookFacets(null, m({}), "hello there");
    expect(f.automation).toBe("human");
    expect(f.reach).toBe("direct");
  });
});
```

- [ ] **Step 4.3: Run** `pnpm test` → passing. **Step 4.4: Commit** `git commit -m "feat(outlook-mail): classifier facets from Graph signals"`.

---

### Task 5: Contact enrichment (`enrich.ts`)

**Files:**
- Create: `public/connectors/outlook-mail/src/enrich.ts`
- Test: `public/connectors/outlook-mail/src/enrich.test.ts`

- [ ] **Step 5.1: Implement.** Names-only enrichment (avatar limitation documented at top of file). Mirror the holder-walk of `enrichLinkContactsFromGoogle` (`google-contacts/src/people-api.ts:343–386`) and the per-email lookup of `lookupGooglePeople`:

```typescript
/**
 * Contact enrichment from Microsoft Graph People + Contacts APIs.
 *
 * Names only: Graph photos ( /me/contacts/{id}/photo/$value ) are auth-gated
 * binary with no public URL, so they can't populate `contact.avatar` (a URL
 * field). Client-side Gravatar remains the avatar fallback.
 *
 * Scope behavior: each lookup path is attempted only when its scope was
 * granted; 403s (work-tenant admin-consent denials, consumer People API
 * limitations) are swallowed per-email — enrichment is always best-effort.
 */
import type { NewActor, NewContact, NewLinkWithNotes } from "@plotday/twister/plot";

const GRAPH = "https://graph.microsoft.com/v1.0";
const SCOPE_PEOPLE = "https://graph.microsoft.com/people.read";
const SCOPE_CONTACTS = "https://graph.microsoft.com/contacts.read";

export const OUTLOOK_PEOPLE_SCOPES = [SCOPE_PEOPLE, SCOPE_CONTACTS];

type GraphPerson = {
  displayName?: string;
  scoredEmailAddresses?: Array<{ address?: string }>;
  emailAddresses?: Array<{ address?: string }>;
};

async function graphGet(token: string, url: string, params: Record<string, string>): Promise<any | null> {
  try {
    const response = await fetch(`${url}?${new URLSearchParams(params)}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    });
    if (!response.ok) return null; // 403/404/429 — per-email best effort
    return await response.json();
  } catch {
    return null;
  }
}

function personMatches(p: GraphPerson, email: string): boolean {
  const all = [
    ...(p.scoredEmailAddresses ?? []).map((e) => e.address),
    ...(p.emailAddresses ?? []).map((e) => e.address),
  ];
  return all.some((a) => a?.toLowerCase().trim() === email);
}

/** Per-email name lookup: /me/people $search first, /me/contacts $filter fallback. */
export async function lookupOutlookPeople(
  token: string,
  scopes: string[],
  emails: string[],
): Promise<Record<string, { name?: string }>> {
  const result: Record<string, { name?: string }> = {};
  const unique = Array.from(new Set(emails.map((e) => e.toLowerCase().trim()).filter(Boolean)));
  const hasPeople = scopes.includes(SCOPE_PEOPLE);
  const hasContacts = scopes.includes(SCOPE_CONTACTS);
  if (unique.length === 0 || (!hasPeople && !hasContacts)) return result;

  await Promise.all(unique.map(async (email) => {
    let name: string | undefined;
    if (hasPeople) {
      const data = await graphGet(token, `${GRAPH}/me/people`, {
        $search: `"${email}"`,
        $select: "displayName,scoredEmailAddresses",
        $top: "5",
      });
      const match = (data?.value as GraphPerson[] | undefined)?.find((p) => personMatches(p, email));
      if (match?.displayName) name = match.displayName;
    }
    if (!name && hasContacts) {
      const data = await graphGet(token, `${GRAPH}/me/contacts`, {
        $filter: `emailAddresses/any(a:a/address eq '${email.replace(/'/g, "''")}')`,
        $select: "displayName,emailAddresses",
        $top: "5",
      });
      const match = (data?.value as GraphPerson[] | undefined)?.find((p) => personMatches(p, email));
      if (match?.displayName) name = match.displayName;
    }
    if (name) result[email] = { name };
  }));
  return result;
}

/**
 * Fill missing contact names across a batch of links (thread accessContacts +
 * note authors + note accessContacts). Mutates in place; existing names win.
 */
export async function enrichLinkContactsFromOutlook(
  links: NewLinkWithNotes[],
  token: string,
  scopes: string[],
): Promise<void> {
  type Holder = { email: string; name?: string };
  const holders: Holder[] = [];
  const visit = (c: unknown) => {
    if (!c || typeof c !== "object") return;
    const cc = c as { email?: string };
    if (typeof cc.email !== "string" || cc.email.length === 0) return;
    holders.push(cc as Holder);
  };
  for (const link of links) {
    visit((link as { author?: NewActor }).author);
    for (const c of link.accessContacts ?? []) visit(c);
    for (const note of link.notes ?? []) {
      const n = note as { author?: NewActor; accessContacts?: Array<NewContact | string> };
      visit(n.author);
      for (const c of n.accessContacts ?? []) visit(c);
    }
  }
  const needing = holders.filter((h) => !h.name).map((h) => h.email);
  if (needing.length === 0) return;
  const map = await lookupOutlookPeople(token, scopes, needing);
  if (Object.keys(map).length === 0) return;
  for (const holder of holders) {
    const found = map[holder.email.toLowerCase().trim()];
    if (!holder.name && found?.name) holder.name = found.name;
  }
}
```

- [ ] **Step 5.2: Tests** (`enrich.test.ts`) using `vi.stubGlobal("fetch", ...)`:

```typescript
import { afterEach, describe, expect, it, vi } from "vitest";
import { enrichLinkContactsFromOutlook, lookupOutlookPeople, OUTLOOK_PEOPLE_SCOPES } from "./enrich";
import type { NewLinkWithNotes } from "@plotday/twister/plot";

afterEach(() => vi.unstubAllGlobals());

function stubFetch(handler: (url: string) => unknown) {
  vi.stubGlobal("fetch", vi.fn(async (input: string | URL) => {
    const url = String(input);
    const body = handler(url);
    if (body === null) return new Response("denied", { status: 403 });
    return Response.json(body);
  }));
}

describe("lookupOutlookPeople", () => {
  it("resolves names via the People API", async () => {
    stubFetch((url) => url.includes("/me/people")
      ? { value: [{ displayName: "Ann Example", scoredEmailAddresses: [{ address: "ann@x.com" }] }] }
      : { value: [] });
    const map = await lookupOutlookPeople("tok", OUTLOOK_PEOPLE_SCOPES, ["Ann@X.com"]);
    expect(map["ann@x.com"]).toEqual({ name: "Ann Example" });
  });

  it("falls back to /me/contacts and swallows 403s", async () => {
    stubFetch((url) => url.includes("/me/people")
      ? null // 403 — e.g. consumer account limitation
      : { value: [{ displayName: "Bob Contact", emailAddresses: [{ address: "bob@y.com" }] }] });
    const map = await lookupOutlookPeople("tok", OUTLOOK_PEOPLE_SCOPES, ["bob@y.com"]);
    expect(map["bob@y.com"]).toEqual({ name: "Bob Contact" });
  });

  it("skips lookups when scopes are missing", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const map = await lookupOutlookPeople("tok", [], ["a@b.c"]);
    expect(map).toEqual({});
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe("enrichLinkContactsFromOutlook", () => {
  it("fills missing names in place, preserving existing ones", async () => {
    stubFetch((url) => url.includes("/me/people")
      ? { value: [{ displayName: "Ann Example", scoredEmailAddresses: [{ address: "ann@x.com" }] }] }
      : { value: [] });
    const link: NewLinkWithNotes = {
      type: "email", title: "t",
      accessContacts: [
        { email: "ann@x.com" },
        { email: "bob@y.com", name: "Keep Me" },
      ],
      notes: [{ author: { email: "ann@x.com" }, content: "x" }],
    };
    await enrichLinkContactsFromOutlook([link], "tok", OUTLOOK_PEOPLE_SCOPES);
    expect((link.accessContacts![0] as { name?: string }).name).toBe("Ann Example");
    expect((link.accessContacts![1] as { name?: string }).name).toBe("Keep Me");
    expect((link.notes![0] as { author: { name?: string } }).author.name).toBe("Ann Example");
  });
});
```

- [ ] **Step 5.3: Run** `pnpm test` → passing. **Step 5.4: Commit** `git commit -m "feat(outlook-mail): name enrichment from Graph People/Contacts"`.

---

### Task 6: Connector class (`outlook-mail.ts`) — the big one

**Files:**
- Create: `public/connectors/outlook-mail/src/outlook-mail.ts`
- Test: `public/connectors/outlook-mail/src/outlook-mail.test.ts`

This file is a method-by-method port of `gmail.ts` with Graph subscription mechanics from `outlook-calendar.ts`. Build it in three commits (6A lifecycle, 6B sync/process/status, 6C reply/compose) but design the whole class up front.

**Module-level (top of file):**

```typescript
import {
  Connector, type CreateLinkDraft, type NoteWriteBackResult, type ToolBuilder,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type { Actor, ActorId, NewLinkWithNotes, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider, type AuthToken, type Authorization, type Channel,
  Integrations, type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";

import { enrichLinkContactsFromOutlook, OUTLOOK_PEOPLE_SCOPES } from "./enrich";
import {
  EXCLUDED_WELL_KNOWN, GraphMailApi, GraphMailApiError, MESSAGE_SELECT,
  conversationSource, isConversationFlagged, isConversationUnread,
  recipientEmails, sortConversation, transformOutlookConversation,
  type GraphAttachmentMeta, type GraphHeader, type GraphMessage, type WellKnownFolders,
} from "./graph-mail-api";
import { outlookFacets } from "./outlook-facets";

const SELF_HEAL_INTERVAL_MS = 60 * 60 * 1000;
const SUB_PREEMPTIVE_RENEW_MS = 36 * 60 * 60 * 1000;
const RENEWAL_LEAD_MS = 24 * 60 * 60 * 1000;
const SUBSCRIPTION_DURATION_DAYS = 3;
const MAX_MESSAGE_FETCH_ATTEMPTS = 5;
const MAX_DELTA_PAGES_PER_HEAL = 20;
const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;
const DIRECT_ATTACH_MAX_BYTES = 3 * 1024 * 1024;

type PendingMessage = { id: string; attempts: number };
type SubscriptionState = {
  subscriptionId: string;
  clientState: string;
  webhookUrl: string;
  expiration: Date;
  created: string;
};
type IncrementalState = { pendingMessageIds?: PendingMessage[] };
type InitialSyncState = { nextLink?: string | null; lastSyncTime?: Date };
type DeltaState = { url: string }; // nextLink mid-walk or deltaLink at rest
```

Copy **verbatim from `gmail.ts`**: `fnv1aHex` (lines 104–111) and `recipientsFor` (lines 134–147, exported, JSDoc included).

**`pickChannelForConversation`** (module-level, exported for tests):

```typescript
/**
 * Pick which enabled channel (folder) a conversation files under. Custom
 * folders are most specific so they win; then inbox; then sentitems; then
 * archive. Returns null when no enabled folder holds any of the
 * conversation's messages (mailbox-wide change irrelevant to enabled
 * channels — skipped, same as gmail).
 */
export function pickChannelForConversation(
  messages: GraphMessage[],
  enabledChannels: Set<string>,
  wellKnown: WellKnownFolders,
): string | null {
  const folders = new Set<string>();
  for (const m of messages) {
    if (m.parentFolderId) folders.add(m.parentFolderId);
  }
  const system = new Set(
    [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive].filter(Boolean) as string[],
  );
  const customMatches = [...enabledChannels]
    .filter((id) => !system.has(id) && folders.has(id))
    .sort();
  if (customMatches.length > 0) return customMatches[0];
  for (const id of [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive]) {
    if (id && enabledChannels.has(id) && folders.has(id)) return id;
  }
  return null;
}
```

**Class skeleton** (all state keys listed here are the complete set):

```typescript
export class OutlookMail extends Connector<OutlookMail> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://graph.microsoft.com/mail.readwrite",
    "https://graph.microsoft.com/mail.send",
  ];

  readonly provider = AuthProvider.Microsoft;
  readonly scopes = Integrations.MergeScopes(OutlookMail.SCOPES, OUTLOOK_PEOPLE_SCOPES);
  readonly linkTypes = [
    {
      type: "email",
      label: "Thread",
      noteLabel: "Reply",
      sharingModel: "message" as const,
      composePlaceholder: "Send an Outlook email",
      composeVerb: "Send",
      replyPlaceholder: "Reply",
      replyVerb: "Send",
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/microsoft-icon.svg",
      logoDark: "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
      logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg",
      contactRoles: [
        { id: "to", label: "To", default: true },
        { id: "cc", label: "CC" },
        { id: "bcc", label: "BCC", hidden: true },
      ],
      supportsContactChanges: true,
      compose: { targets: "addresses" as const },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      files: build(Files),
    };
  }
  // ... methods below
}
export default OutlookMail;
```

**Storage keys** (mirror gmail's table):
`auth_actor_id`, `user_email`, `wellknown_folders`, `enabled_channels`, `mailbox_subscription` (SubscriptionState), `incremental_state` (IncrementalState), `initial_state_{folderId}`, `sync_history_min_{folderId}`, `delta_{folderId}` (DeltaState), `mailbox_renewal_task`, `mailbox_self_heal_task`, `last_webhook_received_at`, `unread:{conversationId}`, `flagged:{conversationId}`, `skip_todo_writeback:{conversationId}`, `outlook:msg-channel:{messageId}`, `sent:{internetMessageId}`, `send_note:{noteId}`, `compose:{hash}`.

#### Task 6A: lifecycle (channels, subscription, renewal, self-heal, teardown)

- [ ] **Step 6A.1:** Implement, porting each from the named source:

| Method | Port from | Outlook deltas |
|---|---|---|
| `activate` | `gmail.ts:244–246` | identical |
| `getChannels(_auth, token)` | `gmail.ts:385–408` | `api.getMailFolders()` + `api.getWellKnownFolderIds()`; `await this.set("wellknown_folders", wellKnown)`; exclude folders whose id matches an `EXCLUDED_WELL_KNOWN` entry and `isHidden`; `enabledByDefault: id === wellKnown.inbox \|\| id === wellKnown.sentitems` |
| `onChannelEnabled` | `gmail.ts:410–458` | same shape; recovery also clears `delta_{channel.id}`; queues `initialSyncBatch(channel.id, 1)` + `ensureMailboxSubscription` via `runTask` |
| `onChannelDisabled` | `gmail.ts:460–471` | also clear `delta_{channel.id}`; teardown when last |
| `getApi(channelId)` / `getApiAny()` | `gmail.ts:473–479, 1919–1926` | `new GraphMailApi(token.token)` |
| `getEnabledChannels`/`add`/`remove`/`isChannelEnabled` | `gmail.ts:1887–1912` | identical |
| `ensureUserEmail()` | `outlook-calendar.ts:406–419` | store key `user_email`; uses `api.getProfile()` |
| `ensureMailboxSubscription` | `gmail.ts:568–580` | sentinel `mailbox_subscription` |
| `setupMailboxSubscription` | `gmail.ts:582–671` + `outlook-calendar.ts:656–711` | see code below |
| `teardownMailboxSubscription` | `gmail.ts:678–719` | cancels both tasks; `api.deleteSubscription`; `this.tools.network.deleteWebhook(state.webhookUrl)` best-effort; clears `mailbox_subscription`, `incremental_state`, `last_webhook_received_at` |
| `scheduleMailboxRenewal(expiration)` | `gmail.ts:725–751` | identical pattern |
| `renewMailboxSubscription` | `gmail.ts:759–816` + `outlook-calendar.ts:595–654` | primary = `api.renewSubscription(id, now+3d)` PATCH; update stored expiration + reschedule; fallback = `setupMailboxSubscription()` (which deletes the old sub first) |
| `scheduleSelfHealCheck` | `gmail.ts:1009–1027` | identical |
| `selfHealCheck` | `gmail.ts:845–1002` | step 1 becomes per-folder delta catch-up (below); step 2 checks `mailbox_subscription` expiry against `SUB_PREEMPTIVE_RENEW_MS` → `renewMailboxSubscription()`; heartbeat fields adapted |

`setupMailboxSubscription` core (write in full):

```typescript
  private async setupMailboxSubscription(): Promise<void> {
    // Replace any prior subscription: delete server-side sub + webhook token,
    // then create fresh (mirrors gmail's setupMailboxWebhook cleanup).
    const existing = await this.get<SubscriptionState>("mailbox_subscription");
    await this.clear("mailbox_subscription");
    if (existing?.subscriptionId) {
      const cleanupApi = await this.getApiAny();
      if (cleanupApi) {
        try { await cleanupApi.deleteSubscription(existing.subscriptionId); }
        catch (error) { console.warn(`OutlookMail setup [${this.id}]: stale sub delete failed`, error); }
      }
    }
    if (existing?.webhookUrl) {
      try { await this.tools.network.deleteWebhook(existing.webhookUrl); }
      catch (error) { console.warn(`OutlookMail setup [${this.id}]: stale webhook delete failed`, error); }
    }

    // Synchronous webhook: Graph validates the endpoint inline by POSTing
    // ?validationToken=... and expecting a text/plain echo — the async queue
    // default would reply { queued: true } and creation would fail.
    const webhookUrl = await this.tools.network.createWebhook(
      { async: false },
      this.onOutlookMailWebhook,
    );
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
      console.log(`OutlookMail setup [${this.id}]: localhost webhook — skipping subscription`);
      return;
    }

    const api = await this.getApiAny();
    if (!api) {
      console.warn(`OutlookMail setup [${this.id}]: no enabled channel to source auth from`);
      return;
    }

    const clientState = crypto.randomUUID();
    const expirationDateTime = new Date(Date.now() + SUBSCRIPTION_DURATION_DAYS * 24 * 60 * 60 * 1000);
    const sub = await api.createSubscription({ notificationUrl: webhookUrl, clientState, expirationDateTime });

    const expiration = new Date(sub.expirationDateTime);
    await this.set<SubscriptionState>("mailbox_subscription", {
      subscriptionId: sub.id, clientState, webhookUrl, expiration,
      created: new Date().toISOString(),
    });
    await this.scheduleMailboxRenewal(expiration);
    await this.scheduleSelfHealCheck();
    console.log(`OutlookMail setup [${this.id}]: subscription established`, {
      subscriptionId: sub.id, expiration: expiration.toISOString(),
    });
  }
```

Self-heal step 1 — per-folder delta catch-up (write in full):

```typescript
  /**
   * Delta catch-up for one enabled folder. First run seeds the delta baseline
   * filtered to `now` (cheap — establishes a cursor without walking history;
   * the initial backfill already imported history). Subsequent runs walk
   * changes since the stored link. Returns changed message ids. On 410 the
   * cursor is reseeded (bounded gap; the next webhook still covers new mail).
   */
  private async folderDeltaCatchUp(api: GraphMailApi, folderId: string): Promise<string[]> {
    const stored = await this.get<DeltaState>(`delta_${folderId}`);
    let url = stored?.url ?? api.buildInitialDeltaUrl(folderId, new Date());
    const seeding = !stored;
    const changed: string[] = [];
    for (let page = 0; page < MAX_DELTA_PAGES_PER_HEAL; page++) {
      let result;
      try {
        result = await api.deltaPage(url);
      } catch (error) {
        if (error instanceof GraphMailApiError && error.status === 410) {
          await this.clear(`delta_${folderId}`); // reseed next cycle
          return changed;
        }
        throw error;
      }
      if (!seeding) {
        for (const m of result.messages) {
          if (m.id && !(m as Record<string, unknown>)["@removed"]) changed.push(m.id);
        }
      }
      if (result.deltaLink) {
        await this.set<DeltaState>(`delta_${folderId}`, { url: result.deltaLink });
        return changed;
      }
      if (!result.nextLink) return changed;
      url = result.nextLink;
      await this.set<DeltaState>(`delta_${folderId}`, { url }); // resume mid-walk next heal if page cap hits
    }
    return changed;
  }
```

In `selfHealCheck`, replace gmail's history-check block with: loop enabled folders → `folderDeltaCatchUp`; union ids; if any → `action = "missed_history"` (gmail's name kept for log continuity? no — use `"missed_delta"`) and `await this.incrementalSyncBatch(ids)` directly (already in a task context). Keep gmail's structure: best-effort try/catch per folder, then subscription verification, heartbeat log, always-reschedule, rethrow unrecoverable.

- [ ] **Step 6A.2: Build:** `pnpm build` in the package (class compiles with 6B/6C method stubs that `throw new Error("not implemented")` — remove in 6B/6C). Run `pnpm test` (Tasks 2–5 still green).
- [ ] **Step 6A.3: Commit** `git commit -m "feat(outlook-mail): connector lifecycle, Graph subscription, self-heal"`.

#### Task 6B: sync pipeline, status sync, webhook, attachments

- [ ] **Step 6B.1:** Implement:

**`initialSyncBatch(channelId, batchNumber)`** — port `gmail.ts:1034–1100`:
1. Disabled-channel + missing-cursor guards identical.
2. `api = new GraphMailApi(token.token)`; first batch also `await this.ensureUserEmail()`.
3. Page: `cursor.nextLink ? api.getMessagesPage({ nextLink }) : api.getMessagesPage({ folderId: channelId, top: 20, since: storedSyncHistoryMin })` where `storedSyncHistoryMin` = `sync_history_min_{channelId}` parsed, else undefined.
4. `const conversationIds = [...new Set(page.messages.filter((m) => !m.isDraft && m.conversationId).map((m) => m.conversationId!))]` (cross-page duplicate conversations are possible — upsert by `source`/`note.key` makes the re-save idempotent; accepted).
5. `const items = await this.fetchConversations(api, conversationIds)`; `await this.processConversations(items, true, channelId)`.
6. `page.nextLink` → persist cursor `{ nextLink, lastSyncTime }`, queue `initialSyncBatch(channelId, batchNumber + 1)`. Else clear cursor + `channelSyncCompleted(channelId)`.

**`fetchConversations(api, conversationIds)`** (private):

```typescript
  private async fetchConversations(
    api: GraphMailApi,
    conversationIds: string[],
  ): Promise<Array<{
    messages: GraphMessage[];
    attachmentsByMessageId: Map<string, GraphAttachmentMeta[]>;
    parentHeaders: GraphHeader[] | null;
  }>> {
    const items = [];
    for (const conversationId of conversationIds) {
      try {
        const messages = await api.getConversationMessages(conversationId);
        if (messages.length === 0) continue;
        const attachmentsByMessageId = new Map<string, GraphAttachmentMeta[]>();
        for (const m of messages) {
          if (!m.isDraft && m.hasAttachments) {
            try { attachmentsByMessageId.set(m.id, await api.listAttachments(m.id)); }
            catch (error) { console.warn(`[outlook-mail] attachments fetch failed for ${m.id}:`, error); }
          }
        }
        const parent = sortConversation(messages).find((m) => !m.isDraft);
        let parentHeaders: GraphHeader[] | null = null;
        if (parent) {
          try { parentHeaders = await api.getInternetMessageHeaders(parent.id); }
          catch { /* facets degrade to header-less signals */ }
        }
        items.push({ messages, attachmentsByMessageId, parentHeaders });
      } catch (error) {
        console.error(`[outlook-mail] failed to fetch conversation ${conversationId}:`, error);
      }
    }
    return items;
  }
```

**`onOutlookMailWebhook(request: WebhookRequest)`**:

```typescript
  async onOutlookMailWebhook(request: WebhookRequest): Promise<string | void> {
    // Graph endpoint validation handshake — echo as text/plain (sync route).
    if (request.params?.validationToken) return request.params.validationToken as string;

    await this.set("last_webhook_received_at", new Date().toISOString());
    const selfHealTask = await this.get<string>("mailbox_self_heal_task");
    if (!selfHealTask) {
      try { await this.scheduleSelfHealCheck(); }
      catch (error) { console.error(`OutlookMail webhook [${this.id}]: self-heal bootstrap failed`, error); }
    }

    const body = request.body as { value?: Array<{
      clientState?: string;
      lifecycleEvent?: string;
      resourceData?: { id?: string };
    }> } | null;
    const notifications = body?.value ?? [];
    if (notifications.length === 0) return;

    const stored = await this.get<SubscriptionState>("mailbox_subscription");
    const ids = new Set<string>();
    let lifecycleAction = false;
    for (const n of notifications) {
      // clientState is Graph's only authenticity signal for notifications.
      if (!stored?.clientState || n.clientState !== stored.clientState) {
        console.warn(`OutlookMail webhook [${this.id}]: clientState mismatch, dropping notification`);
        continue;
      }
      if (n.lifecycleEvent === "subscriptionRemoved" || n.lifecycleEvent === "reauthorizationRequired") {
        lifecycleAction = true;
        continue;
      }
      if (n.resourceData?.id) ids.add(n.resourceData.id);
    }
    if (lifecycleAction) {
      await this.runTask(await this.callback(this.renewMailboxSubscription));
    }
    if (ids.size > 0) {
      await this.runTask(await this.callback(this.incrementalSyncBatch, [...ids]));
    }
  }
```

**`incrementalSyncBatch(messageIds: string[])`**:

```typescript
  async incrementalSyncBatch(messageIds: string[]): Promise<void> {
    try {
      const enabled = await this.getEnabledChannels();
      if (enabled.size === 0) return;
      const api = await this.getApiAny();
      if (!api) { console.warn("[outlook-mail] incremental: no auth"); return; }

      const state = (await this.get<IncrementalState>("incremental_state")) ?? {};
      const pending = state.pendingMessageIds ?? [];
      const toFetch = [...new Set([...messageIds, ...pending.map((p) => p.id)])];

      const wellKnown = (await this.get<WellKnownFolders>("wellknown_folders")) ?? {};
      const excludedFolderIds = new Set(
        EXCLUDED_WELL_KNOWN.map((n) => wellKnown[n]).filter(Boolean) as string[],
      );

      const conversationIds = new Set<string>();
      const failedIds: string[] = [];
      for (const id of toFetch) {
        try {
          const m = await api.getMessage(id, "id,conversationId,parentFolderId,isDraft");
          if (!m) continue; // 404 — hard-deleted upstream; nothing to ingest
          if (m.isDraft) continue;
          if (m.parentFolderId && excludedFolderIds.has(m.parentFolderId)) continue;
          if (m.conversationId) conversationIds.add(m.conversationId);
        } catch (error) {
          console.error(`[outlook-mail] message probe failed for ${id}:`, error);
          failedIds.push(id);
        }
      }

      const items = await this.fetchConversations(api, [...conversationIds]);
      if (items.length > 0) await this.processConversations(items, false);

      await this.set<IncrementalState>("incremental_state", {
        pendingMessageIds: this.mergePendingMessages(pending, failedIds),
      });
    } catch (error) {
      console.error("[outlook-mail] incremental sync batch failed:", error);
      throw error;
    }
  }
```

**`mergePendingMessages(prior, failedIds)`** — port `mergePendingThreads` (`gmail.ts:1181–1198`) renaming thread→message.

**`processConversations(items, initialSync, forceChannelId?)`** — port `processEmailThreads` (`gmail.ts:1242–1416`) with these substitutions (write in full; the structure is identical):
- Transform: `transformOutlookConversation({ messages: item.messages, attachmentsByMessageId: item.attachmentsByMessageId, accountEmail })` where `accountEmail = await this.ensureUserEmail()` once at top.
- Channel pick: `forceChannelId ?? pickChannelForConversation(item.messages, enabledChannels, wellKnown)`; `wellknown_folders` loaded once at top (if missing — e.g. pre-getChannels edge — refresh via `api.getWellKnownFolderIds()` and store).
- Enrichment: `enrichLinkContactsFromOutlook(transformed.map((t) => t.plot), token.token, token.scopes)` in one batch, try/catch warn (`token` from any channel id, same comment as gmail about per-account auth).
- Per-item: `conversationId = plot.meta!.conversationId as string`; msg-channel cache `outlook:msg-channel:{m.id}` for each non-draft message; `sent:{noteKey}` filter identical; unread block identical with `isUnread = isConversationUnread(item.messages)` and store key `unread:{conversationId}`; meta injection `{ ...plot.meta, syncProvider: "microsoft", syncableId: channelId, channelId }` + `plot.channelId = channelId`.
- Facets: parent = first non-draft of `sortConversation(item.messages)`; `facetBody` = matching note content (find note whose key === parent.internetMessageId) ?? preview ?? ""; `plot.facets = outlookFacets(item.parentHeaders, parent, facetBody)`.
- Flag block (gmail's star block): `isFlagged = isConversationFlagged(item.messages)`; `wasFlagged = await this.get<boolean>(\`flagged:${conversationId}\`)`; `saveLink` → skip when null; when `isFlagged !== !!wasFlagged` → `setThreadToDo(plot.source as string, actorId, isFlagged)` + `skip_todo_writeback:{conversationId}` + cache update. (`plot.source` is the canonical `outlook-mail:{mailbox}:{convId}` string — same value gmail passes: the link's source key.)

**`onThreadRead(thread, _actor, unread)`**:

```typescript
  async onThreadRead(thread: Thread, _actor: Actor, unread: boolean): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    const conversationId = meta.conversationId as string;
    if (!channelId || !conversationId) return;

    const api = await this.getApi(channelId);
    // Cache before the Graph writes so the resulting change notifications
    // see state === cache and don't re-propagate (gmail's echo discipline).
    await this.set(`unread:${conversationId}`, unread);

    const messages = sortConversation(
      await api.getConversationMessages(conversationId),
    ).filter((m) => !m.isDraft);
    if (messages.length === 0) return;

    if (unread) {
      // Mark the latest message unread — matches Outlook's own conversation
      // unread affordance without resurrecting every old message.
      await api.updateMessage(messages[messages.length - 1].id, { isRead: false });
    } else {
      for (const m of messages) {
        if (m.isRead === false) await api.updateMessage(m.id, { isRead: true });
      }
    }
  }
```

**`onThreadToDo(thread, _actor, todo, _options)`** — same skeleton: guard `skip_todo_writeback:{conversationId}` (clear + return); `await this.set(\`flagged:${conversationId}\`, todo)` BEFORE; fetch conversation; `todo` → PATCH latest non-draft `{ flag: { flagStatus: "flagged" } }`; `!todo` → PATCH every message with `flagStatus === "flagged"` to `"notFlagged"`.

**`downloadAttachment(ref)`** — port `gmail.ts:1968–2007`: split ref on first `:` (Graph ImmutableIds are URL-safe base64, never contain `:`); channel = `outlook:msg-channel:{messageId}` cache, fallback `getApiAny()` directly (single mailbox — no per-channel probing needed, unlike Gmail); `api.getAttachment` → decode `contentBytes` standard base64 (`atob` + byte loop, no url-safe replacement needed); return `{ body, mimeType: att.contentType ?? "application/octet-stream" }`.

- [ ] **Step 6B.2: Tests** (`outlook-mail.test.ts`) for the exported pure functions:

```typescript
import { describe, expect, it } from "vitest";
import { pickChannelForConversation, recipientsFor } from "./outlook-mail";
import type { GraphMessage, WellKnownFolders } from "./graph-mail-api";

const inFolder = (parentFolderId: string): GraphMessage =>
  ({ id: `m-${parentFolderId}`, parentFolderId }) as GraphMessage;
const wk: WellKnownFolders = { inbox: "f-inbox", sentitems: "f-sent", archive: "f-arch" };

describe("pickChannelForConversation", () => {
  it("prefers enabled custom folders over inbox", () => {
    expect(pickChannelForConversation(
      [inFolder("f-custom"), inFolder("f-inbox")],
      new Set(["f-inbox", "f-custom"]), wk,
    )).toBe("f-custom");
  });
  it("falls back inbox → sentitems", () => {
    expect(pickChannelForConversation([inFolder("f-sent")], new Set(["f-inbox", "f-sent"]), wk))
      .toBe("f-sent");
    expect(pickChannelForConversation([inFolder("f-inbox"), inFolder("f-sent")],
      new Set(["f-inbox", "f-sent"]), wk)).toBe("f-inbox");
  });
  it("returns null when nothing matches", () => {
    expect(pickChannelForConversation([inFolder("f-other")], new Set(["f-inbox"]), wk)).toBeNull();
  });
});

describe("recipientsFor", () => {
  it("excludes self always", () => {
    expect(recipientsFor({ accessContactEmails: null, candidates: ["a@b.com", "me@b.com"], self: "ME@b.com" }))
      .toEqual(["a@b.com"]);
  });
  it("empty constraint set sends to nobody (private note)", () => {
    expect(recipientsFor({ accessContactEmails: new Set(), candidates: ["a@b.com"], self: "me@b.com" }))
      .toEqual([]);
  });
  it("constraint filters to allowed", () => {
    expect(recipientsFor({
      accessContactEmails: new Set(["a@b.com"]),
      candidates: ["a@b.com", "c@d.com"], self: "me@b.com",
    })).toEqual(["a@b.com"]);
  });
});
```

- [ ] **Step 6B.3:** `pnpm build && pnpm test` → green. **Step 6B.4: Commit** `git commit -m "feat(outlook-mail): sync pipeline, two-way unread/flag, webhook, attachments"`.

#### Task 6C: reply (`onNoteCreated`) + compose (`onCreateLink`)

- [ ] **Step 6C.1: `onNoteCreated`** — port `gmail.ts:1418–1594` with the Graph send flow:
1. Resolve `channelId` (`meta.channelId ?? meta.syncableId`) and `conversationId` from meta; bail with `console.error` when missing.
2. Idempotency guard `send_note:{note.id}` → return `{ key: prior.key }`.
3. `api.getConversationMessages(conversationId)` sorted, non-draft; bail when empty.
4. Target message: `meta.reNoteKey` matched against `internetMessageId` (fallback last message).
5. Recipients: `self = await this.ensureUserEmail()`; To-candidates = `recipientEmails([target.from]) + recipientEmails(target.toRecipients)` deduped lowercase; Cc-candidates = `recipientEmails(target.ccRecipients)`; build `accessContactEmails` from `note.accessContacts` × `thread.accessContacts` exactly as gmail (copy lines 1491–1500); apply `recipientsFor` per role; zero recipients → gmail's two log branches, return.
6. `const draft = await api.createReplyDraft(target.id)` (Graph threads the reply: In-Reply-To/References/subject handled server-side).
7. `await api.updateMessage(draft.id, { body: { contentType: "text", content: note.content ?? "" }, toRecipients: to.map(addr), ccRecipients: cc.map(addr) })` where `const addr = (address: string) => ({ emailAddress: { address } })`. (PATCHing body intentionally drops Outlook's quoted-history block — Plot threads carry the history as notes, and Gmail replies are likewise unquoted.)
8. Attachments: for each `note.actions` of `ActionType.file` → `this.tools.files.read(action.fileId)`; ≤3 MB → `api.addFileAttachment(draft.id, { name, contentType, contentBytes: base64(data) })` (chunked btoa helper — copy `uint8ArrayToBase64Lines`' chunk loop shape from `gmail-api.ts:1136–1145` but join without line breaks); larger → `api.uploadLargeAttachment`. Per-attachment try/catch like gmail (skip, don't fail the send).
9. `const sent = await api.getMessage(draft.id, "id,internetMessageId,conversationId")`; `const key = sent?.internetMessageId ?? draft.internetMessageId ?? draft.id;`
10. `await api.send(draft.id)`; then `send_note:{note.id}` = `{ key }`; `sent:{key}` = true; return `{ key }` — no `externalContent` (Graph's send returns 202 with no stored body; first sync-in establishes the baseline, same documented tradeoff as Gmail).

- [ ] **Step 6C.2: `onCreateLink`** — port `gmail.ts:1665–1802`:
1. `draft.type !== "email"` → null. Recipient splitting: copy `addRecipient` role logic verbatim (lines 1679–1699).
2. `const api = await this.getApiAny()`; `const fromEmail = await this.ensureUserEmail()`; `channelId` = first enabled channel.
3. `linkFor(conversationId)` returns `{ source: conversationSource(fromEmail, conversationId), type: "email", title: subject || undefined, status: null, created: new Date(), sourceUrl: null, channelId, meta: { syncProvider: "microsoft", syncableId: channelId, channelId, conversationId } }`.
4. Dedup `compose:{fnv1aHex(JSON.stringify([draft.type, subject, body, sortedTo, sortedCc, sortedBcc]))}` storing `{ conversationId, at }`, 10-minute window — copy gmail's flow.
5. Send: `const created = await api.createDraft({ subject, body: { contentType: "text", content: body }, toRecipients: toEmails.map(addr), ccRecipients: ccEmails.map(addr), bccRecipients: bccEmails.map(addr) })` → has `id`, `conversationId`, `internetMessageId` (POST /me/messages returns the full draft). `await api.send(created.id)`.
6. Store dedup + `sent:{created.internetMessageId}`; return `{ ...linkFor(created.conversationId!), originatingNote: { key: created.internetMessageId ?? created.id } }`.

- [ ] **Step 6C.3:** `pnpm build && pnpm test` → green. **Step 6C.4: Commit** `git commit -m "feat(outlook-mail): reply and compose via Graph drafts"`.

---

### Task 7: Full verification + PR

- [ ] **Step 7.1:** From `public/`: `pnpm install` (refresh lockfile if needed), then `cd connectors/outlook-mail && pnpm build && pnpm test && pnpm lint` — all green. `plot lint` requires the twister CLI build: if it fails on missing dist, run `cd public/twister && pnpm build` first.
- [ ] **Step 7.2:** Cross-package sanity: `cd public && pnpm -r build` (confirm nothing else broke). Root repo: `pnpm install` so the root lockfile records the new workspace package; confirm `git -C /Users/kris.braun/code/plot status` shows only expected changes (`public` pointer, root `pnpm-lock.yaml`, docs).
- [ ] **Step 7.3:** Run `/finalize` checklist (lint done above; no API/back-compat surface — new package; `catch` blocks use `console.error` per twist-sandbox rule, NOT captureException; **no changeset** — connector-only change, validate with `cd public && pnpm validate-changesets`; docs/updates.md: skip until deployed — connector isn't user-visible yet).
- [ ] **Step 7.4:** Manual E2E test plan: append a `## Manual E2E test plan` section to the README covering: Azure app scope additions (Mail.ReadWrite, Mail.Send, People.Read, Contacts.Read delegated), tunnel setup (`pnpm tunnel:start`), connect personal (outlook.com) + work accounts, verify backfill/folders, live reply both directions, unread + flag round-trips (Plot→Outlook and Outlook→Plot), attachment send/receive, subscription renewal (check logs after 60-min self-heal).
- [ ] **Step 7.5:** Push + PR (public repo): `git push -u origin outlook-mail-connector` then `gh pr create` against `plotday/plot-public` main (title "Outlook Mail connector", body summarizing scope + test plan, PR-body footer per repo convention).
- [ ] **Step 7.6:** Core repo: commit the spec/plan docs and (only if the submodule PR is merged or the user wants the pointer early — default NOT) leave the submodule pointer on the branch; report state to user. Do NOT flip `available` in `apps/site/app/data/connections.ts`.

---

## Self-review notes

- **Spec coverage:** channels (T6A getChannels), initial sync (T6B initialSyncBatch), incremental + subscription + self-heal (T6A/6B), entity mapping + facets (T3/T4), enrichment (T5), two-way statuses (T6B), reply/compose (T6C), teardown (T6A), error handling (client retry T3, pending retries T6B, self-heal T6A), tests + E2E plan (each task + T7). Avatar enrichment narrowed to names-only with documented reason (Graph photos have no public URLs) — deviation from spec's "photos best-effort" recorded here and in README.
- **Type consistency:** `GraphMessage`/`GraphAttachmentMeta`/`WellKnownFolders` defined once in T3, consumed in T4–T6; `conversationSource` used by transform (T3), processConversations + linkFor (T6); note keys are `internetMessageId` everywhere (sync-in T3, echo suppression T6B, write-backs T6C).
- **No placeholders:** copy instructions reference exact source files/lines; all novel logic has inline code.
