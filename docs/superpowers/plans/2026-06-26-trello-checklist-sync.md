# Trello Checklist Sync (Layer 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Trello card checklist items into Plot as structured-item notes with two-way completion, assignment, rename, and deletion.

**Architecture:** This is a **`public/` submodule change only** — `public/connectors/trello/`. The platform/SDK foundation (Layer 1: note `section_*`/`item_position` columns, `user.note` view, Twister `Note`/`NewNote` fields, `Actor.source`, and dispatch-time `tagActors` enrichment) already shipped in **Plan 3**. This plan adds: (a) checklist/checkItem fetch + a `checkItem → NewNote` transform that rides the existing `saveLink(transformCard(...))`; (b) write-back of completion/assignment/rename via a new `onNoteUpdated` branch for `checkitem-*` keys; (c) webhook-action-driven deletion. No `workers/api` or schema changes — only a post-merge core-repo gitlink re-point.

**Tech Stack:** TypeScript, `@plotday/twister` SDK, Vitest, Trello REST API (`api.trello.com/1`).

## Global Constraints

- **Submodule only:** all code changes are under `public/connectors/trello/src/`. The connector is **not** an npm package and needs **no changeset** (changesets are only for `public/twister/src/` changes). It deploys via `plot deploy` (reads `plotTwistId`), not npm.
- **Note key scheme (immutable Trello ids):** checklist item notes use `key = "checkitem-{checkItemId}"`. Never derive keys from mutable fields (name/position).
- **Tag semantics:** `Tag.Todo = 1` (assigned-to), `Tag.Done = 3` (completed-by). Imported from `@plotday/twister` (re-exported via `./tag`).
- **Positions are fractional-index `text`:** stringify Trello's float `pos` with `String(pos)` for both `sectionPosition` (checklist) and `itemPosition` (item).
- **Inbound assignment uses `source.accountId`:** express a Trello member as a `NewActor` of shape `{ name, avatar?, source: { accountId: memberId } }`. The runtime resolves it to a contact via `contact_external_account` scoped to this connector's instance (no lookup needed). This is exactly the existing `memberContact()` shape in `trello-sync.ts`.
- **Outbound assignment reads `note.tagActors`:** in `onNoteUpdated`, map a Plot assignee actor id → Trello member id via `note.tagActors[actorId]?.source?.accountId` (populated by the Plan 3 runtime enrichment). Never call an external lookup.
- **Item-level completion collapse:** Trello completion is one bit per item; Plot `Done` is per-actor. Inbound: a `complete` item gets one `Done` actor (the assignee, else the connection owner). Outbound: **any** `Done` actor ⇒ `state=complete`; **no** `Done` actor ⇒ `state=incomplete`.
- **Single-assignee:** Trello checkItems carry one `idMember`. With multiple Plot `Tag.Todo` actors, write the first. An assignee with no resolvable Trello member id is skipped with a `deliveryError` (`{ code, message? }`) — this must NOT block the completion/rename fields.
- **Loop-safety is inherent:** write-backs run as the twist (`updated_by = twist`), so the resulting webhook re-sync does not re-dispatch. No connector-side guard needed.
- **Error capture:** every new `catch` for an *unexpected* failure logs via `console.error` (the connector runtime forwards connector logs; there is no `tracker` in connector scope — follow the existing `trello.ts` pattern of `console.error`/`console.warn`). Do not swallow silently.
- **Run all connector tests from** `public/connectors/trello/`: `pnpm vitest run` (or a single file path). Lint: `pnpm lint` (runs `tsc && eslint .`).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `public/connectors/trello/src/trello-api.ts` | Trello REST client + types | **Modify** — add `TrelloChecklist`/`TrelloCheckItem` types, `checklists`/`checkItem` fetch fields, `updateCheckItem()`, `me()` |
| `public/connectors/trello/src/trello-api.test.ts` | API request-shaping tests | **Modify** — add tests for the new query fields + methods |
| `public/connectors/trello/src/trello-sync.ts` | Pure `transformCard` (card → link+notes) | **Modify** — emit `checkitem-*` notes; new `ownerMemberId` param |
| `public/connectors/trello/src/trello-sync.test.ts` | Transform tests | **Modify** — add checkItem→note tests |
| `public/connectors/trello/src/trello.ts` | Connector class (lifecycle, sync, write-back, webhook) | **Modify** — me-id cache, per-card checklist state, `onNoteUpdated` checkitem branch, `onWebhook` deletion branches |
| `public/connectors/trello/src/trello.test.ts` | Connector tests | **Modify** — add write-back + deletion tests |
| `docs/updates.d/<slug>.md` | User-facing update fragment | **Create** in Task 7 |

---

## Task 1: Fetch checklists & checkItems on sync-in (`trello-api.ts` types + query fields)

**Files:**
- Modify: `public/connectors/trello/src/trello-api.ts`
- Test: `public/connectors/trello/src/trello-api.test.ts`

**Interfaces:**
- Produces:
  - `export type TrelloCheckItem = { id: string; name: string; state: "complete" | "incomplete"; pos: number; idMember: string | null }`
  - `export type TrelloChecklist = { id: string; name: string; pos: number; checkItems: TrelloCheckItem[] }`
  - `TrelloCard` gains `checklists?: TrelloChecklist[]`
  - `getCards`/`getCard` request `checklists=all&checklist_fields=name,pos&checkItems=all&checkItem_fields=name,state,pos,idMember`

- [ ] **Step 1: Write the failing test** — append to `trello-api.test.ts` inside `describe("TrelloApi request shaping", ...)`:

```ts
  it("getCards requests checklists + checkItems with member ids", async () => {
    const f = mockFetchOnce([]);
    await api.getCards("b1", { limit: 50 });
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("checklists=all");
    expect(url).toContain("checklist_fields=name,pos");
    expect(url).toContain("checkItems=all");
    expect(url).toContain("checkItem_fields=name,state,pos,idMember");
  });

  it("getCard requests checklists + checkItems too", async () => {
    const f = mockFetchOnce({ id: "c1", name: "C" });
    await api.getCard("c1");
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("checklists=all");
    expect(url).toContain("checkItem_fields=name,state,pos,idMember");
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-api.test.ts`
Expected: FAIL — the two new tests assert substrings not yet present in the request URLs.

- [ ] **Step 3: Add the types** — in `trello-api.ts`, immediately above `export type TrelloCard`:

```ts
export type TrelloCheckItem = {
  id: string;
  name: string;
  state: "complete" | "incomplete";
  pos: number;
  idMember: string | null;
};

export type TrelloChecklist = {
  id: string;
  name: string;
  pos: number;
  checkItems: TrelloCheckItem[];
};
```

Then add `checklists?: TrelloChecklist[];` to the `TrelloCard` type (next to `attachments?` / `actions?`).

- [ ] **Step 4: Add the fetch fields** — in `getCards`, add these three entries to the query array (after the `actions_limit=50` line, before `limit=`):

```ts
      "checklists=all",
      "checklist_fields=name,pos",
      "checkItems=all",
      "checkItem_fields=name,state,pos,idMember",
```

In `getCard`, add the same four entries to its query array (after `actions_limit=50`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-api.test.ts`
Expected: PASS (all tests in the file).

- [ ] **Step 6: Commit**

```bash
git add public/connectors/trello/src/trello-api.ts public/connectors/trello/src/trello-api.test.ts
git commit -m "feat(trello): fetch checklists + checkItems on card sync"
```

---

## Task 2: `updateCheckItem` + `me` API methods (`trello-api.ts`)

**Files:**
- Modify: `public/connectors/trello/src/trello-api.ts`
- Test: `public/connectors/trello/src/trello-api.test.ts`

**Interfaces:**
- Produces:
  - `updateCheckItem(cardId: string, checkItemId: string, fields: { name?: string; state?: "complete" | "incomplete"; idMember?: string }): Promise<TrelloCheckItem>` — `PUT /cards/{cardId}/checkItem/{checkItemId}`. An `idMember` of `""` clears the assignment.
  - `me(): Promise<{ id: string; fullName: string | null; username: string | null }>` — `GET /members/me?fields=id,fullName,username`.

- [ ] **Step 1: Write the failing test** — append to `trello-api.test.ts` inside `describe("TrelloApi request shaping", ...)`:

```ts
  it("updateCheckItem PUTs state/name/idMember to the card checkItem endpoint", async () => {
    const f = mockFetchOnce({ id: "ci1", name: "Buy milk", state: "complete", pos: 1, idMember: "m1" });
    const item = await api.updateCheckItem("c1", "ci1", { state: "complete", name: "Buy milk", idMember: "m1" });
    expect(item.state).toBe("complete");
    const url = f.mock.calls[0][0] as string;
    const init = f.mock.calls[0][1] as RequestInit;
    expect(init.method).toBe("PUT");
    expect(url).toContain("/cards/c1/checkItem/ci1");
    expect(url).toContain("state=complete");
    expect(url).toContain("name=Buy%20milk");
    expect(url).toContain("idMember=m1");
  });

  it("me fetches /members/me with id,fullName,username", async () => {
    const f = mockFetchOnce({ id: "me1", fullName: "Owner", username: "owner" });
    const me = await api.me();
    expect(me.id).toBe("me1");
    const url = f.mock.calls[0][0] as string;
    expect(url).toContain("/members/me");
    expect(url).toContain("fields=id,fullName,username");
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-api.test.ts`
Expected: FAIL — `api.updateCheckItem is not a function` / `api.me is not a function`.

- [ ] **Step 3: Add the methods** — in `trello-api.ts`, inside `class TrelloApi`, after `updateComment(...)`:

```ts
  updateCheckItem(
    cardId: string,
    checkItemId: string,
    fields: { name?: string; state?: "complete" | "incomplete"; idMember?: string },
  ): Promise<TrelloCheckItem> {
    const parts: string[] = [];
    if (fields.name !== undefined) parts.push(`name=${encodeURIComponent(fields.name)}`);
    if (fields.state !== undefined) parts.push(`state=${fields.state}`);
    // Empty-string idMember clears the assignment (verify during e2e).
    if (fields.idMember !== undefined) parts.push(`idMember=${encodeURIComponent(fields.idMember)}`);
    return this.req("PUT", `/cards/${cardId}/checkItem/${checkItemId}`, parts.join("&"));
  }

  me(): Promise<{ id: string; fullName: string | null; username: string | null }> {
    return this.req("GET", "/members/me", "fields=id,fullName,username");
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-api.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/connectors/trello/src/trello-api.ts public/connectors/trello/src/trello-api.test.ts
git commit -m "feat(trello): add updateCheckItem + me API methods"
```

---

## Task 3: Emit `checkitem-*` notes from `transformCard` (`trello-sync.ts`)

**Files:**
- Modify: `public/connectors/trello/src/trello-sync.ts`
- Test: `public/connectors/trello/src/trello-sync.test.ts`

**Interfaces:**
- Consumes: `TrelloChecklist`/`TrelloCheckItem` (Task 1); `Tag` from `@plotday/twister`.
- Produces: `transformCard(card, boardId, initialSync, ownerMemberId?)` — new optional 4th param. `ownerMemberId` is the connection owner's Trello member id, used to attribute `Done` on **unassigned-complete** items. Each non-empty checklist contributes one note per item with shape:
  - `key: "checkitem-{item.id}"`, `content: item.name`, `created` (= the card's `cardCreatedAt`)
  - `sectionKey: checklist.id`, `sectionLabel: checklist.name`, `sectionPosition: String(checklist.pos)`, `itemPosition: String(item.pos)`
  - `tags`: `{ [Tag.Todo]: [assignee] }` when `item.idMember`; `{ [Tag.Done]: [doneActor] }` when `item.state === "complete"` (doneActor = the assignee, else the owner). Both keys may be present.

- [ ] **Step 1: Write the failing test** — in `trello-sync.test.ts`, add a `describe` block (after the existing `describe("transformCard", ...)`). Note the `Tag` import at the top of the file: add `import { Tag } from "@plotday/twister";`.

```ts
describe("transformCard checklists", () => {
  function withChecklists() {
    return card({
      members: [
        { id: "m1", fullName: "Ada", username: "ada", avatarUrl: null },
        { id: "m2", fullName: "Bob", username: "bob", avatarUrl: null },
      ],
      checklists: [
        {
          id: "cl1",
          name: "QA tasks",
          pos: 16384,
          checkItems: [
            { id: "ci1", name: "Write tests", state: "complete", pos: 100, idMember: "m1" },
            { id: "ci2", name: "Review PR", state: "incomplete", pos: 200, idMember: null },
            { id: "ci3", name: "Deploy", state: "complete", pos: 300, idMember: null },
          ],
        },
        { id: "cl2", name: "Empty", pos: 32768, checkItems: [] },
      ],
    });
  }

  it("emits one note per checkItem with section + item positions", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    type KN = { key?: string; content?: string | null; sectionKey?: string | null; sectionLabel?: string | null; sectionPosition?: string | null; itemPosition?: string | null; tags?: Record<number, unknown[]> };
    const notes = (link.notes ?? []) as KN[];
    const ci1 = notes.find((n) => n.key === "checkitem-ci1")!;
    expect(ci1.content).toBe("Write tests");
    expect(ci1.sectionKey).toBe("cl1");
    expect(ci1.sectionLabel).toBe("QA tasks");
    expect(ci1.sectionPosition).toBe("16384");
    expect(ci1.itemPosition).toBe("100");
  });

  it("skips empty checklists entirely", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const keys = (link.notes ?? []).map((n) => (n as { key?: string }).key);
    expect(keys.filter((k) => k?.startsWith("checkitem-"))).toEqual(["checkitem-ci1", "checkitem-ci2", "checkitem-ci3"]);
  });

  it("assigns Tag.Todo from idMember and Tag.Done for a complete assigned item", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci1 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci1")! as { tags?: Record<number, Array<{ source?: { accountId?: string } }>> };
    expect(ci1.tags?.[Tag.Todo]?.[0].source?.accountId).toBe("m1");
    expect(ci1.tags?.[Tag.Done]?.[0].source?.accountId).toBe("m1");
  });

  it("leaves an incomplete unassigned item untagged", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci2 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci2")! as { tags?: Record<number, unknown[]> };
    expect(ci2.tags).toBeUndefined();
  });

  it("attributes Done to the owner for an unassigned complete item", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci3 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci3")! as { tags?: Record<number, Array<{ source?: { accountId?: string } }>> };
    expect(ci3.tags?.[Tag.Todo]).toBeUndefined();
    expect(ci3.tags?.[Tag.Done]?.[0].source?.accountId).toBe("owner1");
  });

  it("omits owner Done when no ownerMemberId is provided", () => {
    const link = transformCard(withChecklists(), "board-1", false, undefined);
    const ci3 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci3")! as { tags?: Record<number, unknown[]> };
    expect(ci3.tags).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-sync.test.ts`
Expected: FAIL — `checkitem-*` notes are not emitted yet.

- [ ] **Step 3: Implement** — in `trello-sync.ts`:

Add the `Tag` import at the top:

```ts
import { Tag } from "@plotday/twister";
import type { NewActor, NewContact, NewLinkWithNotes } from "@plotday/twister";
```

(Keep the existing `import type { TrelloCard, TrelloMember, cardCreatedAt }` line; add `TrelloCheckItem` is not needed directly — items are reached via `card.checklists`.)

Add a helper that resolves a Trello member id to a `NewActor`, preferring the card's hydrated member objects (for a real name/avatar), falling back to a source-only contact with the id as its display name:

```ts
function memberActorById(idMember: string, card: TrelloCard): NewActor {
  const m = (card.members ?? []).find((x) => x.id === idMember);
  if (m) return memberContact(m);
  // Assignee is a board member not present on the card — name-only fallback.
  // The runtime resolves the contact by source.accountId; this name is only
  // used if the contact has never been seen before.
  return { name: idMember, source: { accountId: idMember } } as NewContact;
}
```

In `transformCard`, change the signature to accept the owner id:

```ts
export function transformCard(
  card: TrelloCard,
  boardId: string,
  initialSync: boolean,
  ownerMemberId?: string,
): NewLinkWithNotes {
```

After the attachments loop (before `const contacts = ...`), add the checklist loop:

```ts
  for (const checklist of card.checklists ?? []) {
    for (const item of checklist.checkItems) {
      const tags: NonNullable<CardNote["tags"]> = {};
      if (item.idMember) tags[Tag.Todo] = [memberActorById(item.idMember, card)];
      if (item.state === "complete") {
        const doneId = item.idMember ?? ownerMemberId ?? null;
        if (doneId) tags[Tag.Done] = [memberActorById(doneId, card)];
      }
      notes.push({
        key: `checkitem-${item.id}`,
        content: item.name,
        created,
        sectionKey: checklist.id,
        sectionLabel: checklist.name,
        sectionPosition: String(checklist.pos),
        itemPosition: String(item.pos),
        ...(Object.keys(tags).length > 0 ? { tags } : {}),
      } as CardNote);
    }
  }
```

> Note: `CardNote` is the local alias already declared in `transformCard` as `NonNullable<NewLinkWithNotes["notes"]>[number]`. It carries `sectionKey`/`sectionLabel`/`sectionPosition`/`itemPosition`/`tags` from the Plan 3 `NewNote` type, so no extra typing is needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/trello && pnpm vitest run src/trello-sync.test.ts`
Expected: PASS (existing transform tests + the new `describe` block).

- [ ] **Step 5: Commit**

```bash
git add public/connectors/trello/src/trello-sync.ts public/connectors/trello/src/trello-sync.test.ts
git commit -m "feat(trello): emit checklist items as structured note-items"
```

---

## Task 4: Wire owner id + per-card checklist state into sync paths (`trello.ts`)

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts`

**Interfaces:**
- Consumes: `api.me()` (Task 2); `transformCard(..., ownerMemberId)` (Task 3); the `Store` tool (`this.set`/`this.get`/`this.clear`) already in `build()`.
- Produces (private connector helpers, used by Task 6 too):
  - `getOwnerMemberId(boardId: string): Promise<string | undefined>` — returns the cached `me_member_id`, fetching+caching via `api.me()` on first use; returns `undefined` on failure (degrades to no owner-Done attribution).
  - `recordChecklistItems(cardId: string, card: TrelloCard): Promise<void>` — persists `checklist_items_{cardId}` = `Record<checklistId, checkItemId[]>` from the card's current checklists (so Task 6 can resolve `removeChecklistFromCard`). Writes `{}` when the card has no checklists.
  - State keys: `me_member_id` (string), `checklist_items_{cardId}` (`Record<string, string[]>`).

- [ ] **Step 1: Write the failing test** — in `trello.test.ts`, add:

```ts
describe("checklist sync wiring", () => {
  const bid = "b1";

  it("fetches+caches the owner member id and passes it to transformCard", async () => {
    const store = makeStore({ [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: true } });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const trello = makeTrello({ store, integrations: { saveLink, channelSyncCompleted: vi.fn().mockResolvedValue(undefined) } });
    const me = vi.fn().mockResolvedValue({ id: "owner1", fullName: "Owner", username: "owner" });
    const getCards = vi.fn().mockResolvedValue([
      { id: "c1", name: "C", desc: "", idList: "l1", idBoard: bid, closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z",
        checklists: [{ id: "cl1", name: "QA", pos: 1, checkItems: [{ id: "ci1", name: "x", state: "complete", pos: 1, idMember: null }] }] },
    ]);
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ me, getCards });

    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);

    expect(me).toHaveBeenCalledTimes(1);
    expect(await store.get("me_member_id")).toBe("owner1");
    // owner-attributed Done lands on the saved note
    const savedNotes = saveLink.mock.calls[0][0].notes as Array<{ key: string; tags?: Record<number, Array<{ source?: { accountId?: string } }>> }>;
    const ci1 = savedNotes.find((n) => n.key === "checkitem-ci1")!;
    expect(ci1.tags?.[3]?.[0].source?.accountId).toBe("owner1"); // Tag.Done = 3
    // per-card checklist map persisted for later deletion handling
    expect(await store.get("checklist_items_c1")).toEqual({ cl1: ["ci1"] });
  });

  it("reuses the cached owner id without a second me() call", async () => {
    const store = makeStore({ me_member_id: "ownerX", [`sync_state_${bid}`]: { before: null, batchNumber: 1, initialSync: false } });
    const trello = makeTrello({ store, integrations: { saveLink: vi.fn().mockResolvedValue("t1") } });
    const me = vi.fn();
    const getCards = vi.fn().mockResolvedValue([]);
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ me, getCards });
    await (trello as unknown as { syncBatch: (b: string) => Promise<void> }).syncBatch(bid);
    expect(me).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello.test.ts`
Expected: FAIL — `me` is never called; `me_member_id`/`checklist_items_c1` not stored; owner Done absent.

- [ ] **Step 3: Implement** — in `trello.ts`:

Import the card type for the helper signature (top of file, alongside the existing trello-api import):

```ts
import { TrelloApi, cardCreatedAt, verifyTrelloWebhook, type TrelloCard } from "./trello-api";
```

Add the two private helpers to the `Trello` class (place them just above `private async syncBatch`):

```ts
  /** The connection owner's Trello member id, cached for Done-attribution on unassigned-complete items. */
  private async getOwnerMemberId(boardId: string): Promise<string | undefined> {
    const cached = await this.get<string>("me_member_id");
    if (cached) return cached;
    try {
      const api = await this.getApi(boardId);
      const me = await api.me();
      if (me?.id) {
        await this.set("me_member_id", me.id);
        return me.id;
      }
    } catch (error) {
      console.warn("Failed to fetch Trello member id for owner attribution:", error);
    }
    return undefined;
  }

  /** Persist the card's checklist→checkItem-id map so checklist removal can archive the right notes. */
  private async recordChecklistItems(cardId: string, card: TrelloCard): Promise<void> {
    const map: Record<string, string[]> = {};
    for (const cl of card.checklists ?? []) {
      map[cl.id] = cl.checkItems.map((i) => i.id);
    }
    await this.set(`checklist_items_${cardId}`, map);
  }
```

In `syncBatch`, replace the save loop:

```ts
    for (const card of cards) {
      await this.tools.integrations.saveLink(transformCard(card, boardId, state.initialSync));
    }
```

with:

```ts
    const ownerMemberId = await this.getOwnerMemberId(boardId);
    for (const card of cards) {
      await this.tools.integrations.saveLink(transformCard(card, boardId, state.initialSync, ownerMemberId));
      await this.recordChecklistItems(card.id, card);
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/trello && pnpm vitest run src/trello.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/connectors/trello/src/trello.ts public/connectors/trello/src/trello.test.ts
git commit -m "feat(trello): cache owner member id + checklist-item map on sync"
```

---

## Task 5: Write back checkItem completion / assignment / rename (`onNoteUpdated`)

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts`

**Interfaces:**
- Consumes: `api.updateCheckItem` (Task 2); `note.tags` (`{ [Tag]: ActorId[] }`), `note.tagActors` (`Record<ActorId, Actor>` with `actor.source?.accountId`).
- Produces: a new branch at the **top** of `onNoteUpdated` (before the existing `description`/`comment` handling) matching `note.key` against `/^checkitem-(.+)$/`. Returns `{ externalContent: item.name, deliveryError? }`.

Reconcile rules (full-note, no per-field diff):
- `state`: any actor in `note.tags[Tag.Done]` ⇒ `"complete"`, else `"incomplete"`.
- `idMember`: first actor in `note.tags[Tag.Todo]` resolved via `note.tagActors[id]?.source?.accountId`. If it resolves, set it. If there is a Todo actor but it has no `source.accountId`, leave `idMember` unset and return a `deliveryError` (`{ code: "invalid_recipient", message: "Assignee is not a Trello board member" }`). If there are zero Todo actors, set `idMember: ""` to clear.
- `name`: `note.content ?? ""`.

- [ ] **Step 1: Write the failing test** — in `trello.test.ts`, add:

```ts
describe("checkItem write-back", () => {
  const thread = { meta: { cardId: "c1", boardId: "b1" } } as any;
  function withUpdate(trello: Trello) {
    const updateCheckItem = vi.fn().mockResolvedValue({ id: "ci1", name: "Renamed", state: "complete", pos: 1, idMember: "m1" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCheckItem });
    return updateCheckItem;
  }

  it("marks complete when a Done actor is present and renames from content", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "Renamed", tags: { 3: ["a1"] }, tagActors: {} } as any; // Tag.Done = 3
    const res = await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ state: "complete", name: "Renamed" }));
    expect(res).toEqual({ externalContent: "Renamed" });
  });

  it("marks incomplete when no Done actor is present", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: {}, tagActors: {} } as any;
    await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ state: "incomplete", idMember: "" }));
  });

  it("resolves the assignee to a Trello member via tagActors.source.accountId", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: { 1: ["a1"] }, tagActors: { a1: { id: "a1", source: { accountId: "m1" } } } } as any; // Tag.Todo = 1
    const res = await trello.onNoteUpdated(note, thread);
    expect(updateCheckItem).toHaveBeenCalledWith("c1", "ci1", expect.objectContaining({ idMember: "m1" }));
    expect((res as { deliveryError?: unknown }).deliveryError).toBeUndefined();
  });

  it("returns a deliveryError (without blocking completion) when the assignee has no member id", async () => {
    const trello = makeTrello();
    const updateCheckItem = withUpdate(trello);
    const note = { key: "checkitem-ci1", content: "x", tags: { 1: ["a1"], 3: ["a1"] }, tagActors: { a1: { id: "a1" } } } as any;
    const res = await trello.onNoteUpdated(note, thread);
    const fields = updateCheckItem.mock.calls[0][2];
    expect(fields.idMember).toBeUndefined(); // assignee not written
    expect(fields.state).toBe("complete"); // completion still applied
    expect((res as { deliveryError?: { code: string } }).deliveryError?.code).toBe("invalid_recipient");
  });

  it("ignores non-checkitem keys (falls through to existing handling)", async () => {
    const trello = makeTrello();
    const updateCheckItem = vi.fn();
    const updateCard = vi.fn().mockResolvedValue({ desc: "d" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ updateCheckItem, updateCard });
    await trello.onNoteUpdated({ key: "description", content: "d" } as any, thread);
    expect(updateCheckItem).not.toHaveBeenCalled();
    expect(updateCard).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello.test.ts`
Expected: FAIL — checkitem keys are not yet handled; the regex `/^comment-(.+)$/` returns and `updateCheckItem` is never called.

- [ ] **Step 3: Implement** — at the top of the file add the `Tag` import (merge into the existing `@plotday/twister` import line):

```ts
import { Connector, Tag, type CreateLinkDraft, type Link, type NewLinkWithNotes, type Note, type NoteWriteBackResult, type Thread, type ToolBuilder } from "@plotday/twister";
```

In `onNoteUpdated`, insert this branch immediately after the `cardId`/`boardId` guard and `const api = await this.getApi(boardId);`, **before** the `if (note.key === "description")` block:

```ts
    const ci = note.key.match(/^checkitem-(.+)$/);
    if (ci) {
      const checkItemId = ci[1];
      const doneActors = note.tags?.[Tag.Done] ?? [];
      const todoActors = note.tags?.[Tag.Todo] ?? [];
      const fields: { name?: string; state?: "complete" | "incomplete"; idMember?: string } = {
        name: note.content ?? "",
        state: doneActors.length > 0 ? "complete" : "incomplete",
      };
      let deliveryError: NoteWriteBackResult["deliveryError"];
      if (todoActors.length > 0) {
        const memberId = note.tagActors?.[todoActors[0]]?.source?.accountId;
        if (memberId) fields.idMember = memberId;
        else deliveryError = { code: "invalid_recipient", message: "Assignee is not a Trello board member" };
      } else {
        fields.idMember = ""; // no assignee → clear
      }
      const item = await api.updateCheckItem(cardId, checkItemId, fields);
      return { externalContent: item.name, ...(deliveryError ? { deliveryError } : {}) };
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/trello && pnpm vitest run src/trello.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/connectors/trello/src/trello.ts public/connectors/trello/src/trello.test.ts
git commit -m "feat(trello): write back checkItem completion, assignment, rename"
```

---

## Task 6: Archive notes on checkItem / checklist deletion (`onWebhook`)

**Files:**
- Modify: `public/connectors/trello/src/trello.ts`
- Test: `public/connectors/trello/src/trello.test.ts`

**Interfaces:**
- Consumes: `integrations.saveNote({ thread: { source }, key, archived: true })`; the `checklist_items_{cardId}` state from Task 4.
- Produces: two new branches in `onWebhook`, evaluated **after** signature verification and **before** the existing card re-fetch:
  - `action.type === "deleteCheckItem"`: archive `checkitem-{action.data.checkItem.id}` on `trello:card:{action.data.card.id}`, and drop that id from `checklist_items_{cardId}`.
  - `action.type === "removeChecklistFromCard"`: archive every `checkitem-{id}` for `action.data.checklist.id` using the persisted map, then delete that checklist key from the map.
  - The existing card-level re-fetch path (`saveLink(transformCard(...))`) is preserved for all other action types, and now also passes `ownerMemberId` + records the checklist map (so the persisted state stays current).

The connector's `build()` already grants the `Integrations` tool, which exposes `saveNote`. The `makeTrello` test helper must gain a `saveNote` mock.

- [ ] **Step 1: Extend the test harness** — in `trello.test.ts`, add `saveNote` to the default integrations mock in `makeTrello`:

```ts
      saveNote: vi.fn().mockResolvedValue("note-1"),
```

(Insert it alongside `saveLink`, `channelSyncCompleted`, `archiveLinks` in the `integrations` object.)

- [ ] **Step 2: Write the failing test** — add to `trello.test.ts`:

```ts
describe("checkItem deletion via webhook", () => {
  const url = "https://api.plot.test/hook/abc";
  async function sign(secret: string, raw: string, cb: string) {
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
    const s = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw + cb));
    return btoa(String.fromCharCode(...new Uint8Array(s)));
  }
  async function fire(trello: Trello, action: unknown, store: ReturnType<typeof makeStore>) {
    const body = JSON.stringify({ action });
    const sig = await sign("SEC", body, url);
    await (trello as unknown as { onWebhook: (r: unknown, b: string) => Promise<void> }).onWebhook(
      { method: "POST", headers: { "x-trello-webhook": sig }, params: {}, body: JSON.parse(body), rawBody: body }, "b1",
    );
  }

  it("archives a single note on deleteCheckItem", async () => {
    const store = makeStore({ webhook_url_b1: url, checklist_items_card9: { cl1: ["ci1", "ci2"] } });
    const saveNote = vi.fn().mockResolvedValue("n1");
    const trello = makeTrello({ store, integrations: { saveNote } });
    await fire(trello, { type: "deleteCheckItem", data: { card: { id: "card9" }, checkItem: { id: "ci1" } } }, store);
    expect(saveNote).toHaveBeenCalledWith({ thread: { source: "trello:card:card9" }, key: "checkitem-ci1", archived: true });
    expect(await store.get("checklist_items_card9")).toEqual({ cl1: ["ci2"] });
  });

  it("archives every item of a removed checklist", async () => {
    const store = makeStore({ webhook_url_b1: url, checklist_items_card9: { cl1: ["ci1", "ci2"], cl2: ["ci3"] } });
    const saveNote = vi.fn().mockResolvedValue("n1");
    const trello = makeTrello({ store, integrations: { saveNote } });
    await fire(trello, { type: "removeChecklistFromCard", data: { card: { id: "card9" }, checklist: { id: "cl1" } } }, store);
    expect(saveNote).toHaveBeenCalledTimes(2);
    expect(saveNote).toHaveBeenCalledWith({ thread: { source: "trello:card:card9" }, key: "checkitem-ci1", archived: true });
    expect(saveNote).toHaveBeenCalledWith({ thread: { source: "trello:card:card9" }, key: "checkitem-ci2", archived: true });
    expect(await store.get("checklist_items_card9")).toEqual({ cl2: ["ci3"] });
  });

  it("still re-fetches the card for non-deletion actions", async () => {
    const store = makeStore({ webhook_url_b1: url });
    const saveLink = vi.fn().mockResolvedValue("t1");
    const saveNote = vi.fn();
    const trello = makeTrello({ store, integrations: { saveLink, saveNote } });
    const getCard = vi.fn().mockResolvedValue({ id: "card9", name: "C", desc: "", idList: "l1", idBoard: "b1", closed: false, url: "u", idMembers: [], dateLastActivity: "2026-01-01T00:00:00Z" });
    const me = vi.fn().mockResolvedValue({ id: "owner1", fullName: "O", username: "o" });
    (trello as unknown as { getApi: unknown }).getApi = vi.fn().mockResolvedValue({ getCard, me });
    await fire(trello, { type: "updateCheckItemStateOnCard", data: { card: { id: "card9" }, checkItem: { id: "ci1" } } }, store);
    expect(getCard).toHaveBeenCalledWith("card9");
    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(saveNote).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd public/connectors/trello && pnpm vitest run src/trello.test.ts`
Expected: FAIL — deletion actions are not handled; `saveNote` is never called.

- [ ] **Step 4: Implement** — rewrite the body of `onWebhook` from the action extraction onward. Replace:

```ts
    const action = (request.body as { action?: { data?: { card?: { id?: string } } } })?.action;
    const cardId = action?.data?.card?.id;
    if (!cardId) return;

    // Re-fetch the card for fresh, complete data (webhook payloads are partial).
    const api = await this.getApi(boardId);
    const card = await api.getCard(cardId);
    await this.tools.integrations.saveLink(transformCard(card, boardId, false));
```

with:

```ts
    const action = (
      request.body as {
        action?: {
          type?: string;
          data?: { card?: { id?: string }; checkItem?: { id?: string }; checklist?: { id?: string } };
        };
      }
    )?.action;
    const cardId = action?.data?.card?.id;
    if (!cardId) return;

    // Deletion actions: archive the affected checkitem note(s); no card re-fetch needed.
    if (action?.type === "deleteCheckItem") {
      const checkItemId = action.data?.checkItem?.id;
      if (checkItemId) {
        await this.tools.integrations.saveNote({
          thread: { source: `trello:card:${cardId}` },
          key: `checkitem-${checkItemId}`,
          archived: true,
        });
        const map = (await this.get<Record<string, string[]>>(`checklist_items_${cardId}`)) ?? {};
        for (const clId of Object.keys(map)) map[clId] = map[clId].filter((id) => id !== checkItemId);
        await this.set(`checklist_items_${cardId}`, map);
      }
      return;
    }
    if (action?.type === "removeChecklistFromCard") {
      const checklistId = action.data?.checklist?.id;
      const map = (await this.get<Record<string, string[]>>(`checklist_items_${cardId}`)) ?? {};
      const itemIds = checklistId ? (map[checklistId] ?? []) : [];
      for (const itemId of itemIds) {
        await this.tools.integrations.saveNote({
          thread: { source: `trello:card:${cardId}` },
          key: `checkitem-${itemId}`,
          archived: true,
        });
      }
      if (checklistId) delete map[checklistId];
      await this.set(`checklist_items_${cardId}`, map);
      return;
    }

    // Re-fetch the card for fresh, complete data (webhook payloads are partial).
    const api = await this.getApi(boardId);
    const card = await api.getCard(cardId);
    const ownerMemberId = await this.getOwnerMemberId(boardId);
    await this.tools.integrations.saveLink(transformCard(card, boardId, false, ownerMemberId));
    await this.recordChecklistItems(cardId, card);
```

> `saveNote` is provided by the already-built `Integrations` tool — no `build()` change. The existing `onWebhook` test ("re-fetches the card…") needs the card webhook to still work: it now also calls `getOwnerMemberId`, which calls `api.me()`. Update that existing test's `getApi` mock to include `me: vi.fn().mockResolvedValue({ id: "owner1", fullName: "O", username: "o" })` so the re-fetch path doesn't throw. (The signature-invalid test does not reach the card path, so it needs no change.)

- [ ] **Step 5: Run the full connector suite to verify everything passes**

Run: `cd public/connectors/trello && pnpm vitest run`
Expected: PASS — all files (`trello-api`, `trello-sync`, `trello-channels`, `trello`).

- [ ] **Step 6: Commit**

```bash
git add public/connectors/trello/src/trello.ts public/connectors/trello/src/trello.test.ts
git commit -m "feat(trello): archive checkitem notes on webhook deletion"
```

---

## Task 7: Finalize — lint, full suite, user-facing fragment, rollout notes

**Files:**
- Create: `docs/updates.d/<slug>.md` (via `pnpm updates:new`)
- Verify: whole connector package

- [ ] **Step 1: Lint the connector (tsc + eslint)**

Run: `cd public/connectors/trello && pnpm lint`
Expected: PASS — no TypeScript errors, no eslint errors. (Fix any `any`/unused-import issues the new code introduces.)

- [ ] **Step 2: Run the full connector test suite once more**

Run: `cd public/connectors/trello && pnpm vitest run`
Expected: PASS — all suites green.

- [ ] **Step 3: Add the user-facing update fragment**

Run (from repo root): `pnpm updates:new "Trello checklist items now sync to Plot"`
Then edit the generated `docs/updates.d/<slug>.md` so it reads (group under a Trello/Connections section, not Fixes):

```markdown
### Trello

- Trello checklist items now appear in Plot. Check them off, assign them, or rename them in either place and the change syncs both ways.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.d
git commit -m "docs(updates): Trello checklist item sync"
```

- [ ] **Step 5: Update the connector build progress file**

Edit `docs/superpowers/trello-PROGRESS.md`: mark Plan 4 ✅ complete in the status table, and note that Plan 5 (client UI) remains and **must `seq`-bump `note`** when it adds the Drift columns (carried Plan-3 prerequisite). Commit:

```bash
git add docs/superpowers/trello-PROGRESS.md
git commit -m "docs: Plan 4 (Trello checklist sync) complete"
```

- [ ] **Step 6: Rollout (NOT part of this plan's code — do after review/merge)**

This plan changes only the `public/` submodule. To ship:
1. Push the `public/` branch and open a submodule PR (analogous to plot#236). The connector deploys via `plot deploy` (reads `plotTwistId`), **no changeset, no npm publish**.
2. After the submodule PR merges to `plot/main`, **re-point the core `trello-connector` gitlink** to the new submodule HEAD (one commit on the already-rebased core branch core#481), regenerate `pnpm-lock.yaml` if needed, and verify `pnpm install --frozen-lockfile` + `cd workers/api && pnpm exec tsc --noEmit`.
3. Provisioning (Trello app key/secret) is already tracked in `trello-PROGRESS.md` and gates the prod connect button — unchanged by this plan.

---

## Self-Review

**Spec coverage (Part 3 §3.3 + §3.7):**
- checkItem → `NewNote` with `section_*`/`item_position` → Task 3 ✓
- inbound `Tag.Todo` via `source.accountId` → Task 3 (`memberActorById`) ✓
- inbound item-level `Done` collapse incl. unassigned→owner attribution → Task 3 + Task 4 (`getOwnerMemberId`) ✓
- skip empty checklists → Task 3 ✓
- positions = fractional-index `text` (`String(pos)`) → Task 3 ✓
- `tagActors` companion-map read for write-back → Task 5 ✓
- `onNoteUpdated`: Done⇔state, assignee via enriched `source.accountId`, rename, single-assignee first, non-member skip-with-`deliveryError` (non-blocking) → Task 5 ✓
- deletion = webhook-action driven (`deleteCheckItem`, `removeChecklistFromCard`) via `saveNote(archived:true)` → Task 6 ✓
- write-back round-trip baseline (`externalContent` = sync-in content, i.e. `item.name`) → Task 5 returns `{ externalContent: item.name }`; sync-in emits `content: item.name` ✓
- no `workers/api`/schema change (Layer 1 done in Plan 3); only gitlink re-point → Task 7 rollout ✓
- deferred (v-next): create/delete checkItem *from Plot* (`onNoteCreated` for `checkitem-*`), Layer-3 app UI (Plan 5) → out of scope, stated ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type consistency:**
- `transformCard(card, boardId, initialSync, ownerMemberId?)` — defined Task 3, called Task 4 + Task 6 with the 4th arg. ✓
- `updateCheckItem(cardId, checkItemId, { name?, state?, idMember? })` — defined Task 2, called Task 5. ✓
- `me()` → `{ id, fullName, username }` — defined Task 2, consumed by `getOwnerMemberId` Task 4. ✓
- State keys `me_member_id` / `checklist_items_{cardId}` — written Task 4, read Task 6. ✓
- `Tag.Todo`/`Tag.Done` (1/3) — imported in `trello-sync.ts` (Task 3) and `trello.ts` (Task 5); tests reference the numeric values 1/3 to match. ✓
- `saveNote({ thread:{source}, key, archived })` — `NewNote` accepts `archived` + `key` + `{source}` thread ref (Plan 3 / SDK verified). ✓

**Scope:** Single subsystem (one connector package); coherent for one plan. ✓
