# LinkedIn Connection-Request Note + Accept/Ignore Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every inbound LinkedIn connection request a legible, actionable thread — a connector-authored note stating who requested to connect (name → profile link + headline) with **Accept** and **Ignore** buttons.

**Architecture:** Purely a change to the private `connectors/linkedin` connector. `buildInvitationLink` gains a connector-authored system note carrying two `ActionType.callback` actions. Two new callback handlers (`onAcceptInvitation`, `onIgnoreInvitation`) perform the write-back (`acceptInvitation` / the already-present-but-unused `ignoreInvitation`), reflect the outcome in Plot (status→`inbox` / archive), and rewrite the note to clear its buttons. The `relation.new` webhook reconciles requests the user accepted directly on LinkedIn. All state changes are guarded by the existing per-invitation `invitation_writeback:` flag so every path is idempotent.

**Tech Stack:** TypeScript, `@plotday/twister` SDK, `@plotday/unipile` shared lib, Vitest.

## Global Constraints

- **Connector-only.** No changes to `public/twister` (SDK) or `workers/api` built-in tools — `acceptInvitation`, `ignoreInvitation`, `saveNote`, and `Note.actions` all already exist.
- **No changeset.** Private connector packages (`connectors/*`) never take a changeset (see `public/AGENTS.md` "Changesets: Only for `twister/`").
- **Idempotency flag** is `invitation_writeback:${invitationId}`, value `"accept"` or `"ignore"` (reuses the flag already read/written by `onLinkUpdated`).
- **System-note key** is `invite-request-${invitationId}`. It is authored by the connector (omit `author` → "use the twist as author").
- **Link source** for an invitation is `linkedin:person:${profileId}`, type `TYPE_CONVERSATION` (`"conversation"`). Statuses: `STATUS_PENDING` (`"pending"`), `STATUS_INBOX` (`"inbox"`, = "Connected").
- **Callback handler arg order:** an `ActionType.callback` handler is invoked as `(action: Action, ...storedArgs)` — the runtime prepends the `Action` object, then appends the args passed to `this.callback(method, ...storedArgs)`. Verified in `workers/api/src/twist/invoke-webhook.ts:190-195`.
- **`saveLinks` upsert-merges** by `source` (re-saving with a subset of fields merges; it does not wipe untouched fields — see `pollPostComments` at `connectors/linkedin/src/linkedin.ts:391`). `saveNote` upserts by `(thread, key)`; provide `content` + `actions` + `key` to avoid clobbering.

---

## File Structure

- `connectors/linkedin/src/linkedin.ts` — all connector logic. Add the pure `invitationNoteContent` helper, extend `buildInvitationLink`, add `buildInvitationActions` + the two handlers + `relation.new` reconciliation, and update the two `buildInvitationLink` call sites (`backfill`, `onWebhookEvent`).
- `connectors/linkedin/src/linkedin.test.ts` — **create**. Vitest tests for the pure helper, note assembly, and the handlers (via a mocked tools tree, mirroring `public/connectors/linear/src/linear.test.ts`).
- `connectors/linkedin/vitest.config.ts` — **create**. Copy of linear's config so tests resolve workspace packages from source.
- `connectors/linkedin/package.json` — **modify**. Add `vitest` devDependency + `test`/`test:watch` scripts.

---

## Task 1: Test harness + pure note-content helper

Stand up Vitest for the connector and TDD the pure markdown-content function.

**Files:**
- Create: `connectors/linkedin/vitest.config.ts`
- Modify: `connectors/linkedin/package.json`
- Modify: `connectors/linkedin/src/linkedin.ts` (add + export `invitationNoteContent`)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Produces: `export function invitationNoteContent(inviter: { name: string; subtitle: string | null; profileUrl: string | null }): string` — the markdown body for the system note.

- [ ] **Step 1: Add Vitest config**

Create `connectors/linkedin/vitest.config.ts`:

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // Resolve workspace packages from their TypeScript source using the
    // @plotday/connector export condition (same as the build path).
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
```

- [ ] **Step 2: Add vitest dependency + test scripts**

In `connectors/linkedin/package.json`, add to `scripts`:

```json
    "test": "vitest run",
    "test:watch": "vitest"
```

and add to `devDependencies`:

```json
    "vitest": "^2.1.8"
```

Then install:

Run: `pnpm install --filter @plotday/connector-linkedin`
Expected: completes; `vitest` resolves in the package.

- [ ] **Step 3: Write the failing test**

Create `connectors/linkedin/src/linkedin.test.ts`:

```typescript
import { describe, it, expect } from "vitest";

import { invitationNoteContent } from "./linkedin";

describe("invitationNoteContent", () => {
  it("links the name to the profile and appends the headline", () => {
    const md = invitationNoteContent({
      name: "Héctor Hernán Godoy",
      subtitle: "Designer | Product/Investment Manager",
      profileUrl: "https://www.linkedin.com/in/hector",
    });
    expect(md).toBe(
      "**[Héctor Hernán Godoy](https://www.linkedin.com/in/hector)** requested to connect.\n" +
        "Designer | Product/Investment Manager"
    );
  });

  it("omits the headline line when there is no subtitle", () => {
    const md = invitationNoteContent({
      name: "Arijit Banerjee",
      subtitle: null,
      profileUrl: "https://www.linkedin.com/in/arijit",
    });
    expect(md).toBe(
      "**[Arijit Banerjee](https://www.linkedin.com/in/arijit)** requested to connect."
    );
  });

  it("renders bold plain text (no link) when profileUrl is null", () => {
    const md = invitationNoteContent({
      name: "Samuel Hebeisen",
      subtitle: null,
      profileUrl: null,
    });
    expect(md).toBe("**Samuel Hebeisen** requested to connect.");
  });

  it("escapes markdown link brackets in the name", () => {
    const md = invitationNoteContent({
      name: "Jane [Doe]",
      subtitle: null,
      profileUrl: "https://example.com/jane",
    });
    expect(md).toBe(
      "**[Jane \\[Doe\\]](https://example.com/jane)** requested to connect."
    );
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — `invitationNoteContent` is not exported.

- [ ] **Step 5: Implement the helper**

In `connectors/linkedin/src/linkedin.ts`, add near the other module-level helpers at the bottom of the file (just above `buildInvitationLink`):

```typescript
/**
 * Markdown body for the connector-authored connection-request note. The name
 * links to the inviter's LinkedIn profile (bold plain text when no URL), and
 * the inviter's headline (`subtitle`) is appended on a second line when
 * present. Link brackets in the name are escaped so an unusual name can't
 * break the markdown link.
 */
export function invitationNoteContent(inviter: {
  name: string;
  subtitle: string | null;
  profileUrl: string | null;
}): string {
  const name = inviter.name.replace(/[[\]]/g, (c) => `\\${c}`);
  const nameMd = inviter.profileUrl
    ? `[${name}](${inviter.profileUrl})`
    : name;
  let content = `**${nameMd}** requested to connect.`;
  if (inviter.subtitle) content += `\n${inviter.subtitle}`;
  return content;
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add connectors/linkedin/vitest.config.ts connectors/linkedin/package.json pnpm-lock.yaml connectors/linkedin/src/linkedin.test.ts connectors/linkedin/src/linkedin.ts
git commit -m "test(linkedin): vitest harness + invitationNoteContent helper"
```

---

## Task 2: System note with actions in `buildInvitationLink`

`buildInvitationLink` gains an `actions` parameter and always emits the connector-authored system note (with those actions) as the first note, keeping the inviter's message note (when present) below it.

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (`buildInvitationLink`, ~line 1001; export it for testing)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Consumes: `invitationNoteContent` (Task 1).
- Produces: `export function buildInvitationLink(channelId: string, inv: LinkedInInvitation, initialSync: boolean, actions: Action[]): NewLinkWithNotes` — now takes `actions` and attaches them to the system note keyed `invite-request-${inv.id}`.

- [ ] **Step 1: Write the failing test**

Append to `connectors/linkedin/src/linkedin.test.ts`:

```typescript
import { ActionType } from "@plotday/twister/plot";
import type { Action } from "@plotday/twister/plot";
import type { LinkedInInvitation } from "@plotday/unipile";
import { buildInvitationLink } from "./linkedin";

function fakeInvitation(over: Partial<LinkedInInvitation> = {}): LinkedInInvitation {
  return {
    id: "inv-1",
    message: null,
    sentAt: new Date("2026-07-01T00:00:00Z"),
    inviter: {
      id: "prof-1",
      isSelf: false,
      name: "Héctor Hernán Godoy",
      handle: "hector",
      subtitle: "Designer",
      email: null,
      phone: null,
      pictureUrl: null,
      profileUrl: "https://www.linkedin.com/in/hector",
    },
    ...over,
  } as LinkedInInvitation;
}

const fakeActions: Action[] = [
  { type: ActionType.callback, title: "Accept", callback: "cb-accept" as never },
  { type: ActionType.callback, title: "Ignore", callback: "cb-ignore" as never },
];

describe("buildInvitationLink", () => {
  it("emits the system note first with the two actions", () => {
    const link = buildInvitationLink("chan-1", fakeInvitation(), true, fakeActions);
    expect(link.notes).toHaveLength(1);
    const sys = link.notes![0];
    expect(sys.key).toBe("invite-request-inv-1");
    expect(sys.content).toContain("requested to connect");
    expect(sys.actions).toEqual(fakeActions);
    // Connector-authored: no human author.
    expect(sys.author).toBeUndefined();
  });

  it("keeps the inviter's message note below the system note", () => {
    const link = buildInvitationLink(
      "chan-1",
      fakeInvitation({ message: "Hi, let's connect!" }),
      false,
      fakeActions
    );
    expect(link.notes).toHaveLength(2);
    expect(link.notes![0].key).toBe("invite-request-inv-1");
    expect(link.notes![0].actions).toEqual(fakeActions);
    expect(link.notes![1].key).toBe("invitation-inv-1");
    expect(link.notes![1].content).toBe("Hi, let's connect!");
    // Message note stays authored by the inviter, no actions.
    expect(link.notes![1].actions ?? null).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — `buildInvitationLink` is not exported and/or signature has no `actions`.

- [ ] **Step 3: Update `buildInvitationLink`**

In `connectors/linkedin/src/linkedin.ts`, replace the existing `function buildInvitationLink(...)` (starting ~line 1001) with:

```typescript
export function buildInvitationLink(
  channelId: string,
  inv: LinkedInInvitation,
  initialSync: boolean,
  actions: Action[]
): NewLinkWithNotes {
  const contact = profileToContact(inv.inviter);

  const notes: NewNote[] = [];
  // Connector-authored system note: who requested + headline, plus the
  // Accept/Ignore action buttons. `author` omitted → authored by the twist.
  notes.push({
    thread: { source: `linkedin:person:${inv.inviter.id}` },
    key: `invite-request-${inv.id}`,
    content: invitationNoteContent(inv.inviter),
    contentType: "markdown",
    created: inv.sentAt,
    actions,
  });
  // Personalized message the inviter attached, if any (unchanged).
  if (inv.message) {
    notes.push({
      thread: { source: `linkedin:person:${inv.inviter.id}` },
      key: `invitation-${inv.id}`,
      content: inv.message,
      contentType: "text",
      created: inv.sentAt,
      author: contact,
    });
  }

  return {
    source: `linkedin:person:${inv.inviter.id}`,
    sources: [
      `linkedin:person:${inv.inviter.id}`,
      `linkedin:invitation:${inv.id}`,
    ],
    type: TYPE_CONVERSATION,
    ...(initialSync ? { status: STATUS_PENDING } : {}),
    title: inv.inviter.name,
    preview: inv.message ?? inv.inviter.subtitle ?? null,
    sourceUrl: inv.inviter.profileUrl,
    created: inv.sentAt,
    accessContacts: [contact],
    notes,
    meta: {
      syncProvider: PROVIDER_KEY,
      channelId,
      profileId: inv.inviter.id,
      invitationId: inv.id,
    },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS (all Task 1 + Task 2 tests). Note: the two `buildInvitationLink` **call sites** now fail to typecheck (missing `actions` arg) — that is expected and fixed in Task 3. Do not run `lint` yet.

- [ ] **Step 5: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts connectors/linkedin/src/linkedin.test.ts
git commit -m "feat(linkedin): connection-request system note with action slots"
```

---

## Task 3: `buildInvitationActions` + wire into backfill & webhook

Add the method that mints the Accept/Ignore callbacks (and records the pending marker), then pass its result into both `buildInvitationLink` call sites.

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (`backfill` ~line 427, `onWebhookEvent` ~line 585, new `buildInvitationActions` method)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Consumes: `buildInvitationLink` (Task 2).
- Produces:
  - `buildInvitationActions(channelId: string, inv: LinkedInInvitation): Promise<Action[]>` — creates the two callbacks (each stores `channelId, inv.id, inv.inviter.id`), sets `pending_invitation:${inv.inviter.id}` → `{ invitationId: inv.id }`, and returns the two `ActionType.callback` actions (`title` "Accept" / "Ignore").
  - Handler stubs `onAcceptInvitation` / `onIgnoreInvitation` (bodies filled in Tasks 4–5) so `this.callback(this.onAcceptInvitation, …)` type-checks.

- [ ] **Step 1: Write the failing test**

Append to `connectors/linkedin/src/linkedin.test.ts`. First add a store helper + connector factory near the top of the file (below imports):

```typescript
import { vi } from "vitest";
import { LinkedIn } from "./linkedin";

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => {
      map.set(k, v);
    }),
    clear: vi.fn(async (k: string) => {
      map.delete(k);
    }),
    list: vi.fn(async (p: string) => [...map.keys()].filter((k) => k.startsWith(p))),
  };
}

function makeLinkedIn(over: {
  store?: ReturnType<typeof makeStore>;
  linkedin?: Record<string, unknown>;
  integrations?: Record<string, unknown>;
} = {}) {
  const store = over.store ?? makeStore();
  const tools = {
    store,
    integrations: {
      saveLinks: vi.fn().mockResolvedValue(["t1"]),
      saveNote: vi.fn().mockResolvedValue("n1"),
      saveContacts: vi.fn().mockResolvedValue([]),
      ...over.integrations,
    },
    linkedin: {
      acceptInvitation: vi.fn().mockResolvedValue(undefined),
      ignoreInvitation: vi.fn().mockResolvedValue(undefined),
      getProfile: vi.fn(),
      ...over.linkedin,
    },
  };
  const conn = new LinkedIn("twist-instance-1" as never, {
    getTools: () => tools,
  } as never);
  // this.get/this.set/this.clear delegate to tools.store; mock this.callback.
  (conn as unknown as { callback: unknown }).callback = vi.fn(
    async (_fn: unknown, ...args: unknown[]) => `cb:${args.join(",")}`
  );
  return { conn, tools, store };
}
```

Then add the test block:

```typescript
describe("buildInvitationActions", () => {
  it("mints Accept + Ignore callbacks and records the pending marker", async () => {
    const { conn, store } = makeLinkedIn();
    const inv = fakeInvitation();
    const actions = await (
      conn as unknown as {
        buildInvitationActions: (c: string, i: LinkedInInvitation) => Promise<Action[]>;
      }
    ).buildInvitationActions("chan-1", inv);

    expect(actions).toHaveLength(2);
    expect(actions[0]).toMatchObject({ type: ActionType.callback, title: "Accept" });
    expect(actions[1]).toMatchObject({ type: ActionType.callback, title: "Ignore" });
    expect(store.map.get("pending_invitation:prof-1")).toEqual({ invitationId: "inv-1" });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — `buildInvitationActions` does not exist.

- [ ] **Step 3: Add the method + handler stubs**

In `connectors/linkedin/src/linkedin.ts`, inside the `LinkedIn` class (place these near `onLinkUpdated`), add:

```typescript
  /**
   * Mint the Accept/Ignore callback actions for an inbound invitation and
   * record a `pending_invitation:${profileId}` marker so a later
   * `relation.new` (the user accepting directly on LinkedIn) can reconcile
   * the thread. Each callback stores `(channelId, invitationId, profileId)`
   * so the handler can write back and update the correct link/note.
   */
  async buildInvitationActions(
    channelId: string,
    inv: LinkedInInvitation
  ): Promise<Action[]> {
    const accept = await this.callback(
      this.onAcceptInvitation,
      channelId,
      inv.id,
      inv.inviter.id
    );
    const ignore = await this.callback(
      this.onIgnoreInvitation,
      channelId,
      inv.id,
      inv.inviter.id
    );
    await this.set(`pending_invitation:${inv.inviter.id}`, {
      invitationId: inv.id,
    });
    return [
      { type: ActionType.callback, title: "Accept", callback: accept },
      { type: ActionType.callback, title: "Ignore", callback: ignore },
    ];
  }

  // Handler bodies are implemented in Tasks 4 and 5. The `action` first
  // parameter is prepended by the runtime for ActionType.callback dispatch.
  async onAcceptInvitation(
    _action: Action,
    _channelId: string,
    _invitationId: string,
    _profileId: string
  ): Promise<void> {}

  async onIgnoreInvitation(
    _action: Action,
    _channelId: string,
    _invitationId: string,
    _profileId: string
  ): Promise<void> {}
```

- [ ] **Step 4: Wire the backfill call site**

In `backfill` (~line 427), replace:

```typescript
    const invLinks = inv.invitations.map((i) =>
      buildInvitationLink(channelId, i, true)
    );
```

with:

```typescript
    const invLinks = await Promise.all(
      inv.invitations.map(async (i) =>
        buildInvitationLink(channelId, i, true, await this.buildInvitationActions(channelId, i))
      )
    );
```

- [ ] **Step 5: Wire the webhook call site**

In `onWebhookEvent`, the `invitation.received` branch (~line 585), replace:

```typescript
      const link = buildInvitationLink(channelId, target, false);
```

with:

```typescript
      const link = buildInvitationLink(
        channelId,
        target,
        false,
        await this.buildInvitationActions(channelId, target)
      );
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS. Also confirm the package type-checks now that call sites pass `actions`:

Run: `pnpm --filter @plotday/connector-linkedin lint`
Expected: PASS (no `tsc` errors).

- [ ] **Step 7: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts connectors/linkedin/src/linkedin.test.ts
git commit -m "feat(linkedin): mint Accept/Ignore actions and wire into sync"
```

---

## Task 4: `onAcceptInvitation` handler

Accept the invitation on LinkedIn, flip the Plot link to Connected, clear the note's buttons, and guard with the shared idempotency flag.

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (`onAcceptInvitation` body)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Consumes: `this.tools.linkedin.acceptInvitation`, `this.tools.integrations.saveLinks`, `this.tools.integrations.saveNote`, the `invitation_writeback:` flag, `pending_invitation:` marker.

- [ ] **Step 1: Write the failing test**

Append to `connectors/linkedin/src/linkedin.test.ts`:

```typescript
const fakeAction: Action = {
  type: ActionType.callback,
  title: "Accept",
  callback: "cb" as never,
};

describe("onAcceptInvitation", () => {
  it("accepts, flips status to inbox, clears buttons, sets flag", async () => {
    const store = makeStore({ "pending_invitation:prof-1": { invitationId: "inv-1" } });
    const { conn, tools } = makeLinkedIn({ store });

    await (conn as unknown as {
      onAcceptInvitation: (a: Action, c: string, i: string, p: string) => Promise<void>;
    }).onAcceptInvitation(fakeAction, "chan-1", "inv-1", "prof-1");

    expect(tools.linkedin.acceptInvitation).toHaveBeenCalledWith({
      channelId: "chan-1",
      invitationId: "inv-1",
    });
    // Status flipped to inbox via a merge-save on the person-keyed link.
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({
        source: "linkedin:person:prof-1",
        type: "conversation",
        status: "inbox",
      }),
    ]);
    // Note rewritten: Connected, no buttons.
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Connected.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accept");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
  });

  it("is a no-op when the flag is already set", async () => {
    const store = makeStore({ "invitation_writeback:inv-1": "accept" });
    const { conn, tools } = makeLinkedIn({ store });
    await (conn as unknown as {
      onAcceptInvitation: (a: Action, c: string, i: string, p: string) => Promise<void>;
    }).onAcceptInvitation(fakeAction, "chan-1", "inv-1", "prof-1");
    expect(tools.linkedin.acceptInvitation).not.toHaveBeenCalled();
    expect(tools.integrations.saveNote).not.toHaveBeenCalled();
  });

  it("still clears buttons (unavailable) when accept fails", async () => {
    const store = makeStore();
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { acceptInvitation: vi.fn().mockRejectedValue(new Error("gone")) },
    });
    await (conn as unknown as {
      onAcceptInvitation: (a: Action, c: string, i: string, p: string) => Promise<void>;
    }).onAcceptInvitation(fakeAction, "chan-1", "inv-1", "prof-1");
    // Did NOT flip status to Connected on failure.
    expect(tools.integrations.saveLinks).not.toHaveBeenCalled();
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "This request is no longer available.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accept");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — handler is an empty stub.

- [ ] **Step 3: Implement the handler**

Replace the `onAcceptInvitation` stub body with:

```typescript
  async onAcceptInvitation(
    _action: Action,
    channelId: string,
    invitationId: string,
    profileId: string
  ): Promise<void> {
    const flagKey = `invitation_writeback:${invitationId}`;
    if (await this.get<string>(flagKey)) return;

    let ok = true;
    try {
      await this.tools.linkedin.acceptInvitation({ channelId, invitationId });
    } catch (error) {
      ok = false;
      console.warn(
        `LinkedIn accept-invitation failed (${invitationId})`,
        error
      );
    }
    await this.set(flagKey, "accept");

    if (ok) {
      // Merge-save: flip the person-keyed link to Connected without touching
      // title/preview/etc. (saveLinks upserts by source).
      await this.tools.integrations.saveLinks([
        {
          source: `linkedin:person:${profileId}`,
          sources: [`linkedin:person:${profileId}`],
          type: TYPE_CONVERSATION,
          channelId,
          status: STATUS_INBOX,
          meta: {
            syncProvider: PROVIDER_KEY,
            channelId,
            profileId,
            invitationId,
          },
        },
      ]);
    }

    await this.tools.integrations.saveNote({
      thread: { source: `linkedin:person:${profileId}` },
      key: `invite-request-${invitationId}`,
      content: ok ? "Connected." : "This request is no longer available.",
      contentType: "markdown",
      actions: [],
    });
    await this.clear(`pending_invitation:${profileId}`);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts connectors/linkedin/src/linkedin.test.ts
git commit -m "feat(linkedin): Accept button accepts invitation and marks Connected"
```

---

## Task 5: `onIgnoreInvitation` handler

Ignore the invitation on LinkedIn, archive the Plot thread, clear the note's buttons.

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (`onIgnoreInvitation` body)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Consumes: `this.tools.linkedin.ignoreInvitation`, `saveLinks` (with `archived: true`), `saveNote`, the shared flag + pending marker.

- [ ] **Step 1: Write the failing test**

Append to `connectors/linkedin/src/linkedin.test.ts`:

```typescript
describe("onIgnoreInvitation", () => {
  it("ignores, archives the thread, clears buttons, sets flag", async () => {
    const store = makeStore({ "pending_invitation:prof-1": { invitationId: "inv-1" } });
    const { conn, tools } = makeLinkedIn({ store });

    await (conn as unknown as {
      onIgnoreInvitation: (a: Action, c: string, i: string, p: string) => Promise<void>;
    }).onIgnoreInvitation(fakeAction, "chan-1", "inv-1", "prof-1");

    expect(tools.linkedin.ignoreInvitation).toHaveBeenCalledWith({
      channelId: "chan-1",
      invitationId: "inv-1",
    });
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({
        source: "linkedin:person:prof-1",
        type: "conversation",
        archived: true,
      }),
    ]);
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Ignored.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("ignore");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
  });

  it("is a no-op when the flag is already set", async () => {
    const store = makeStore({ "invitation_writeback:inv-1": "ignore" });
    const { conn, tools } = makeLinkedIn({ store });
    await (conn as unknown as {
      onIgnoreInvitation: (a: Action, c: string, i: string, p: string) => Promise<void>;
    }).onIgnoreInvitation(fakeAction, "chan-1", "inv-1", "prof-1");
    expect(tools.linkedin.ignoreInvitation).not.toHaveBeenCalled();
    expect(tools.integrations.saveLinks).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — handler is an empty stub.

- [ ] **Step 3: Implement the handler**

Replace the `onIgnoreInvitation` stub body with:

```typescript
  async onIgnoreInvitation(
    _action: Action,
    channelId: string,
    invitationId: string,
    profileId: string
  ): Promise<void> {
    const flagKey = `invitation_writeback:${invitationId}`;
    if (await this.get<string>(flagKey)) return;

    try {
      await this.tools.linkedin.ignoreInvitation({ channelId, invitationId });
    } catch (error) {
      // Ignore is dismiss-locally intent — proceed to archive even if the
      // remote call failed (e.g. the invitation was already resolved).
      console.warn(
        `LinkedIn ignore-invitation failed (${invitationId})`,
        error
      );
    }
    await this.set(flagKey, "ignore");

    // Archiving is a Plot concept (there is no LinkedIn "ignored" status).
    await this.tools.integrations.saveLinks([
      {
        source: `linkedin:person:${profileId}`,
        sources: [`linkedin:person:${profileId}`],
        type: TYPE_CONVERSATION,
        channelId,
        archived: true,
        meta: {
          syncProvider: PROVIDER_KEY,
          channelId,
          profileId,
          invitationId,
        },
      },
    ]);
    await this.tools.integrations.saveNote({
      thread: { source: `linkedin:person:${profileId}` },
      key: `invite-request-${invitationId}`,
      content: "Ignored.",
      contentType: "markdown",
      actions: [],
    });
    await this.clear(`pending_invitation:${profileId}`);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts connectors/linkedin/src/linkedin.test.ts
git commit -m "feat(linkedin): Ignore button ignores invitation and archives thread"
```

---

## Task 6: Reconcile requests accepted directly on LinkedIn (`relation.new`)

When the user accepts a request outside Plot, LinkedIn fires `relation.new`. If a pending marker exists for that profile, flip the thread to Connected and clear its buttons — otherwise keep the current save-contact behavior.

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (`onWebhookEvent`, the `relation.new` else-branch ~line 587)
- Test: `connectors/linkedin/src/linkedin.test.ts`

**Interfaces:**
- Consumes: `pending_invitation:${profileId}` marker, the shared flag, `saveLinks`, `saveNote`, existing `getProfile`/`saveContacts`.

- [ ] **Step 1: Write the failing test**

Append to `connectors/linkedin/src/linkedin.test.ts`:

```typescript
describe("onWebhookEvent relation.new reconciliation", () => {
  const profile = {
    id: "prof-1",
    isSelf: false,
    name: "Héctor",
    handle: "hector",
    subtitle: null,
    email: null,
    phone: null,
    pictureUrl: null,
    profileUrl: null,
  };

  it("flips a pending invitation to Connected and clears its buttons", async () => {
    const store = makeStore({ "pending_invitation:prof-1": { invitationId: "inv-1" } });
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { getProfile: vi.fn().mockResolvedValue(profile) },
    });

    await (conn as unknown as {
      onWebhookEvent: (e: unknown, c: string) => Promise<void>;
    }).onWebhookEvent({ kind: "relation.new", profileId: "prof-1" }, "chan-1");

    expect(tools.integrations.saveContacts).toHaveBeenCalled();
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ source: "linkedin:person:prof-1", status: "inbox" }),
    ]);
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({ key: "invite-request-inv-1", content: "Connected.", actions: [] })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accept");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
  });

  it("just saves the contact when there is no pending invitation", async () => {
    const { conn, tools } = makeLinkedIn({
      linkedin: { getProfile: vi.fn().mockResolvedValue(profile) },
    });
    await (conn as unknown as {
      onWebhookEvent: (e: unknown, c: string) => Promise<void>;
    }).onWebhookEvent({ kind: "relation.new", profileId: "prof-1" }, "chan-1");
    expect(tools.integrations.saveContacts).toHaveBeenCalled();
    expect(tools.integrations.saveLinks).not.toHaveBeenCalled();
    expect(tools.integrations.saveNote).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: FAIL — reconciliation not implemented; `saveLinks`/`saveNote` not called for the pending case.

- [ ] **Step 3: Implement reconciliation**

In `onWebhookEvent`, replace the `relation.new` else-branch body (~lines 587-604) with:

```typescript
    } else {
      // relation.new — a new 1st-degree LinkedIn connection. Save the profile
      // as a contact, then reconcile any pending request the user accepted
      // directly on LinkedIn: flip the thread to Connected and clear buttons.
      try {
        const profile = await this.tools.linkedin.getProfile({
          channelId,
          profileId: event.profileId,
        });
        const contact = profileToContact(profile);
        await this.tools.integrations.saveContacts([contact]);
      } catch (error) {
        console.warn(
          `LinkedIn new_relation handler failed for profile ${event.profileId}`,
          error
        );
      }

      const pending = await this.get<{ invitationId: string }>(
        `pending_invitation:${event.profileId}`
      );
      if (pending) {
        const flagKey = `invitation_writeback:${pending.invitationId}`;
        if (!(await this.get<string>(flagKey))) {
          await this.set(flagKey, "accept");
          await this.tools.integrations.saveLinks([
            {
              source: `linkedin:person:${event.profileId}`,
              sources: [`linkedin:person:${event.profileId}`],
              type: TYPE_CONVERSATION,
              channelId,
              status: STATUS_INBOX,
              meta: {
                syncProvider: PROVIDER_KEY,
                channelId,
                profileId: event.profileId,
                invitationId: pending.invitationId,
              },
            },
          ]);
          await this.tools.integrations.saveNote({
            thread: { source: `linkedin:person:${event.profileId}` },
            key: `invite-request-${pending.invitationId}`,
            content: "Connected.",
            contentType: "markdown",
            actions: [],
          });
        }
        await this.clear(`pending_invitation:${event.profileId}`);
      }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/connector-linkedin test`
Expected: PASS (full suite).

- [ ] **Step 5: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts connectors/linkedin/src/linkedin.test.ts
git commit -m "feat(linkedin): reconcile out-of-band-accepted requests via relation.new"
```

---

## Task 7: Finalize

Run the finalization checklist: lint, full test run, user-facing docs, and a final review.

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Possibly modify: `docs/features.md`

- [ ] **Step 1: Full type-check + test**

Run: `pnpm --filter @plotday/connector-linkedin lint && pnpm --filter @plotday/connector-linkedin test`
Expected: both PASS.

- [ ] **Step 2: Add a user-facing update fragment**

Run: `pnpm updates:new "LinkedIn connection requests now show who's asking and let you Accept or Ignore in one tap"`

Then edit the generated `docs/updates.d/*.md` so the bullet lives under a fitting section (create `### Connections` if none fits; do not duplicate an existing near-match), e.g.:

```markdown
### Connections

- LinkedIn connection requests now explain who's reaching out — with their name, headline, and a link to their profile — and you can Accept or Ignore right from the request.
```

- [ ] **Step 3: Review error capture**

Confirm the new `catch` blocks (`onAcceptInvitation`, `onIgnoreInvitation`) log expected/handled failures with `console.warn` only — these are expected outcomes (invitation resolved out-of-band), NOT unexpected bugs, so no `captureException` is required (matches the existing `onLinkUpdated` accept-failure handling). No action needed; just verify.

- [ ] **Step 4: Commit docs**

```bash
git add docs/updates.d docs/features.md 2>/dev/null; git commit -m "docs(linkedin): connection-request note + Accept/Ignore update fragment"
```

- [ ] **Step 5: Final self-check against the spec**

Confirm each spec item is covered: system note (Task 2), name-link + headline (Task 1), Accept (Task 4), Ignore wired to the existing `ignoreInvitation` (Task 5), idempotency via the shared flag (Tasks 4–6), out-of-band reconciliation (Task 6), always-add for bare + with-message (Task 2). Nothing outstanding.

---

## Self-Review Notes

- **Spec coverage:** note content style (sentence + headline) → Task 1/2; buttons via `ActionType.callback` → Task 2/3; Accept routes through accept + status→inbox → Task 4; Ignore uses `ignoreInvitation` + archive → Task 5; lifecycle/idempotency via `invitation_writeback:` → Tasks 4–6; out-of-band resolution → Task 6 (via `relation.new`, the actually-available signal; the connector has no periodic pending-list poll, so a request *ignored* elsewhere with no relation event leaves buttons in place until pressed — safe because the handlers are idempotent). All scope-guard exclusions honored (no reason, no message-on-accept, no re-invite, no new status).
- **Type consistency:** `buildInvitationLink(channelId, inv, initialSync, actions)` used identically in both call sites (Task 3) and tests (Task 2). Handler signatures `(action, channelId, invitationId, profileId)` are consistent across stub (Task 3), impl (Tasks 4–5), and tests. Flag key `invitation_writeback:${invitationId}`, marker `pending_invitation:${profileId}`, and note key `invite-request-${invitationId}` are spelled identically everywhere.
- **No placeholders:** every code step contains full, runnable code.
