# LinkedIn relations backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync a user's full LinkedIn 1st-degree relations into Plot's `contact` table so the compose UI can offer them as new-DM recipients. Backfill paces conservatively (2–4h jittered per page) to stay under Unipile's account-restriction limits.

**Architecture:** Three isolated layers. (1) `UnipileClient` gains `listRelations()`. (2) `LinkedInMessaging` tool gains `listRelations()` and `getProfile()`. (3) `LinkedIn` connector gains `syncRelationsPage` + `refreshRelationsList` scheduled tasks, plus a `users.new_relation` webhook branch. Relations are persisted as Plot contacts via `integrations.saveContacts()`; no `link`/`thread` rows are created. Dedup with later chats/invitations happens through `contact_external_account (provider, account_id)`.

**Tech Stack:** TypeScript, Cloudflare Workers (twist runtime + API worker), vitest, Kysely (DB types only — no DB writes from connector layer), `@plotday/twister` SDK.

---

## File map

**Modified:**
- `workers/api/src/twist/tools/unipile/types.ts` — add `UnipileRelation` + `UnipileRelationList`.
- `workers/api/src/twist/tools/unipile/client.ts` — add `listRelations()` method.
- `workers/api/src/twist/tools/unipile/client.test.ts` — test `listRelations()`.
- `workers/api/src/twist/tools/unipile/normalize.ts` — add `normalizeRelation()`.
- `workers/api/src/twist/tools/unipile/normalize.test.ts` — test `normalizeRelation()`.
- `workers/api/src/twist/tools/unipile/linkedin.ts` — implement tool methods `listRelations`, `getProfile`.
- `libs/unipile/src/types.ts` — add `LinkedInRelationPage` Plot-shape.
- `libs/unipile/src/linkedin.ts` — abstract `listRelations`, `getProfile` on tool.
- `connectors/linkedin/src/linkedin.ts` — add `RelationsSyncState`, `syncRelationsPage`, `refreshRelationsList`; wire `onChannelEnabled` / `onChannelDisabled`; add `relation.new` branch in `onWebhookEvent`.
- `workers/api/src/app/hook-messaging.ts` — add `users.new_relation` dispatch.

**No new files.** No schema changes, no migrations, no Flutter changes.

---

## Task 1: Unipile types for relations

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/types.ts`

- [ ] **Step 1: Add UnipileRelation and UnipileRelationList types**

Append to the end of `workers/api/src/twist/tools/unipile/types.ts`:

```ts
/**
 * Unipile relation (1st-degree LinkedIn connection). Shape comes from
 * `GET /users/relations`. Unlike `UnipileAttendee` this is flat (no
 * `specifics` nesting) and uses `member_id` rather than `provider_id`.
 * See https://github.com/unipile/unipile-node-sdk
 * (src/users/ressource.types.ts → LinkedinUserRelationSchema).
 */
export type UnipileRelation = {
  object: "UserRelation";
  member_id: string;
  member_urn: string;
  connection_urn: string;
  first_name: string;
  last_name: string;
  headline: string;
  public_identifier: string;
  public_profile_url: string;
  profile_picture_url?: string;
  created_at: number;
};

export type UnipileRelationList = {
  object: "UserRelationsList";
  items: UnipileRelation[];
  cursor: string | null;
};
```

- [ ] **Step 2: Commit**

```bash
git add workers/api/src/twist/tools/unipile/types.ts
git commit -m "Add UnipileRelation types for /users/relations endpoint"
```

---

## Task 2: UnipileClient.listRelations + test

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Test: `workers/api/src/twist/tools/unipile/client.test.ts`

- [ ] **Step 1: Add failing test**

Insert after the existing `"throws UnipileApiError"` test in `workers/api/src/twist/tools/unipile/client.test.ts` (before the closing `});` of the `describe` block):

```ts
  it("listRelations sends account_id and parses the relations list", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          object: "UserRelationsList",
          items: [
            {
              object: "UserRelation",
              member_id: "ACoAA123",
              member_urn: "urn:li:member:123",
              connection_urn: "urn:li:fs_miniProfile:123",
              first_name: "Ada",
              last_name: "Lovelace",
              headline: "Computing pioneer",
              public_identifier: "adalovelace",
              public_profile_url: "https://www.linkedin.com/in/adalovelace",
              profile_picture_url: "https://media.licdn.com/ada.jpg",
              created_at: 1700000000,
            },
          ],
          cursor: "next-page-token",
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      )
    );

    const client = new UnipileClient(env);
    const result = await client.listRelations({
      accountId: "acct-1",
      cursor: "prev-cursor",
      limit: 50,
    });

    const [url] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api7.unipile.com:13441/api/v1/users/relations?account_id=acct-1&cursor=prev-cursor&limit=50"
    );
    expect(result.object).toBe("UserRelationsList");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]!.member_id).toBe("ACoAA123");
    expect(result.cursor).toBe("next-page-token");
  });
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm exec vitest run src/twist/tools/unipile/client.test.ts -t "listRelations"
```

Expected: FAIL with `client.listRelations is not a function`.

- [ ] **Step 3: Implement listRelations**

In `workers/api/src/twist/tools/unipile/client.ts`, add the import in the type block at the top:

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
  UnipileRelationList,
  UnipileWebhook,
  UnipileWebhookSource,
} from "./types";
```

Then insert the new method directly after `listReceivedInvitations` (right before the `acceptInvitation` block):

```ts
  listRelations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileRelationList> {
    return this.get<UnipileRelationList>("/users/relations", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd workers/api && pnpm exec vitest run src/twist/tools/unipile/client.test.ts -t "listRelations"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/unipile/client.test.ts
git commit -m "Wrap Unipile GET /users/relations in UnipileClient"
```

---

## Task 3: normalizeRelation + tests

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/normalize.ts`
- Test: `workers/api/src/twist/tools/unipile/normalize.test.ts`

- [ ] **Step 1: Add failing tests**

Insert into `workers/api/src/twist/tools/unipile/normalize.test.ts` immediately before the final closing `});` of the `describe` block:

```ts
  it("normalizeRelation maps the flat relation shape to LinkedInProfile", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      member_id: "ACoAA111",
      member_urn: "urn:li:member:111",
      connection_urn: "urn:li:fs_miniProfile:111",
      first_name: "Grace",
      last_name: "Hopper",
      headline: "Rear Admiral, COBOL pioneer",
      public_identifier: "ghopper",
      public_profile_url: "https://www.linkedin.com/in/ghopper",
      profile_picture_url: "https://media.licdn.com/g.jpg",
      created_at: 1700000000,
    });
    expect(profile.id).toBe("ACoAA111");
    expect(profile.fullName).toBe("Grace Hopper");
    expect(profile.publicIdentifier).toBe("ghopper");
    expect(profile.headline).toBe("Rear Admiral, COBOL pioneer");
    expect(profile.pictureUrl).toBe("https://media.licdn.com/g.jpg");
    expect(profile.url).toBe("https://www.linkedin.com/in/ghopper");
    expect(profile.email).toBeNull();
    expect(profile.isSelf).toBe(false);
  });

  it("normalizeRelation falls back to publicIdentifier when names are empty", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      member_id: "ACoAA222",
      member_urn: "urn:li:member:222",
      connection_urn: "urn:li:fs_miniProfile:222",
      first_name: "",
      last_name: "",
      headline: "",
      public_identifier: "anon",
      public_profile_url: "https://www.linkedin.com/in/anon",
      created_at: 1700000000,
    });
    expect(profile.fullName).toBe("anon");
    expect(profile.headline).toBeNull();
    expect(profile.pictureUrl).toBeNull();
  });
```

Also add `normalizeRelation` to the import at the top of the file:

```ts
import {
  normalizeChat,
  normalizeMessage,
  normalizeInvitation,
  normalizeProfile,
  normalizeRelation,
} from "./normalize";
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd workers/api && pnpm exec vitest run src/twist/tools/unipile/normalize.test.ts -t "normalizeRelation"
```

Expected: FAIL with `normalizeRelation is not exported`.

- [ ] **Step 3: Implement normalizeRelation**

In `workers/api/src/twist/tools/unipile/normalize.ts`, update the imports at the top to include `UnipileRelation`:

```ts
import type {
  UnipileAttachment,
  UnipileAttendee,
  UnipileChat,
  UnipileInvitation,
  UnipileMessage,
  UnipileRelation,
} from "./types";
```

Then append at the end of the file:

```ts
/**
 * Normalize a Unipile `UserRelation` (from GET /users/relations) into Plot's
 * `LinkedInProfile` shape. Relations are 1st-degree connections; they never
 * represent the connected account itself, so `isSelf` is always false.
 * Email is never present in this endpoint's payload — separate profile
 * fetches would be needed, but those count toward LinkedIn's ~100/day
 * profile-retrieval ceiling and are intentionally avoided.
 */
export function normalizeRelation(rel: UnipileRelation): LinkedInProfile {
  const first = rel.first_name?.trim() ?? "";
  const last = rel.last_name?.trim() ?? "";
  const joined = [first, last].filter(Boolean).join(" ");
  const fullName = joined || rel.public_identifier || "Unknown";
  const headlineTrimmed = rel.headline?.trim() ?? "";
  return {
    id: rel.member_id,
    isSelf: false,
    publicIdentifier: rel.public_identifier || null,
    fullName,
    headline: headlineTrimmed || null,
    email: null,
    pictureUrl: rel.profile_picture_url ?? null,
    url:
      rel.public_profile_url ||
      (rel.public_identifier
        ? `https://www.linkedin.com/in/${rel.public_identifier}`
        : null),
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd workers/api && pnpm exec vitest run src/twist/tools/unipile/normalize.test.ts
```

Expected: PASS — both new tests plus the existing five.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile/normalize.ts workers/api/src/twist/tools/unipile/normalize.test.ts
git commit -m "Normalize Unipile UserRelation to LinkedInProfile"
```

---

## Task 4: LinkedInMessaging.listRelations (interface + impl)

**Files:**
- Modify: `libs/unipile/src/types.ts`
- Modify: `libs/unipile/src/linkedin.ts`
- Modify: `workers/api/src/twist/tools/unipile/linkedin.ts`

- [ ] **Step 1: Add Plot-shaped page type**

Append to the end of `libs/unipile/src/types.ts`:

```ts
export type LinkedInRelationPage = {
  relations: LinkedInProfile[];
  nextCursor: string | null;
};
```

- [ ] **Step 2: Add abstract method on the tool interface**

In `libs/unipile/src/linkedin.ts`, extend the import at the top to include `LinkedInRelationPage`:

```ts
import type {
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInRelationPage,
} from "./types";
```

Then insert a new abstract method directly after `listReceivedInvitations` (around line 65):

```ts
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage>;
```

- [ ] **Step 3: Rebuild the twister/unipile workspace package**

The connector consumes these types from the built dist. Run:

```bash
cd libs/unipile && pnpm build
```

Expected: tsc emits `dist/` with the new types. No errors.

- [ ] **Step 4: Implement on the API-worker side**

In `workers/api/src/twist/tools/unipile/linkedin.ts`, update the imports at the top:

```ts
import type {
  LinkedInMessaging as ILinkedInMessaging,
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInRelationPage,
} from "@plotday/unipile";
```

And the normalize imports:

```ts
import {
  normalizeChat,
  normalizeInvitation,
  normalizeMessage,
  normalizeProfile,
  normalizeRelation,
} from "./normalize";
```

Then insert this method directly after `listReceivedInvitations`:

```ts
  async listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listRelations({
      accountId: params.channelId,
      cursor: params.cursor ?? null,
      limit: params.limit,
    });
    return {
      relations: result.items.map(normalizeRelation),
      nextCursor: result.cursor,
    };
  }
```

- [ ] **Step 5: Verify the API worker still typechecks**

```bash
cd workers/api && pnpm exec tsc --noEmit
```

Expected: no type errors. If a "did you mean" error mentions `listRelations`, the `dist/` rebuild from Step 3 didn't propagate — re-run Step 3 then `pnpm install` at the repo root.

- [ ] **Step 6: Commit**

```bash
git add libs/unipile/src/types.ts libs/unipile/src/linkedin.ts workers/api/src/twist/tools/unipile/linkedin.ts
git commit -m "Add LinkedInMessaging.listRelations tool method"
```

---

## Task 5: LinkedInMessaging.getProfile (for webhook lookup)

**Files:**
- Modify: `libs/unipile/src/linkedin.ts`
- Modify: `workers/api/src/twist/tools/unipile/linkedin.ts`

The `users.new_relation` webhook delivers a `member_id` only — no profile fields. The connector needs a way to fetch the relation's profile and turn it into a `NewContact`. `UnipileClient` already has `getAttendee()`; we expose a thin wrapper on the tool.

- [ ] **Step 1: Add abstract method on the tool interface**

In `libs/unipile/src/linkedin.ts`, insert directly after the new `listRelations` abstract:

```ts
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getProfile(params: {
    channelId: string;
    profileId: string;
  }): Promise<LinkedInProfile>;
```

Add `LinkedInProfile` to the imports at the top:

```ts
import type {
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInProfile,
  LinkedInRelationPage,
} from "./types";
```

- [ ] **Step 2: Rebuild the unipile workspace package**

```bash
cd libs/unipile && pnpm build
```

- [ ] **Step 3: Implement on the API-worker side**

In `workers/api/src/twist/tools/unipile/linkedin.ts`, add `LinkedInProfile` to the imports:

```ts
import type {
  LinkedInMessaging as ILinkedInMessaging,
  LinkedInChat,
  LinkedInChatPage,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInProfile,
  LinkedInRelationPage,
} from "@plotday/unipile";
```

Then insert after the new `listRelations` impl:

```ts
  async getProfile(params: {
    channelId: string;
    profileId: string;
  }): Promise<LinkedInProfile> {
    await this.assertAccount(params.channelId);
    const raw = await this.client.getAttendee({ providerId: params.profileId });
    return normalizeProfile(raw);
  }
```

- [ ] **Step 4: Verify typecheck**

```bash
cd workers/api && pnpm exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/linkedin.ts workers/api/src/twist/tools/unipile/linkedin.ts
git commit -m "Add LinkedInMessaging.getProfile tool method"
```

---

## Task 6: Connector state shape + syncRelationsPage method

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

- [ ] **Step 1: Add the RelationsSyncState type**

In `connectors/linkedin/src/linkedin.ts`, immediately after the existing `SyncState` type (around line 43), add:

```ts
type RelationsSyncState = {
  cursor: string | null;
  completed: boolean;
  lastCompletedAt: number | null;
  lastPageAt: number;
};

const RELATIONS_PAGE_LIMIT = 100;
const RELATIONS_PAGE_MIN_DELAY_MS = 2 * 60 * 60 * 1000;
const RELATIONS_PAGE_MAX_DELAY_MS = 4 * 60 * 60 * 1000;
const RELATIONS_PAGE_ERROR_MIN_DELAY_MS = 4 * 60 * 60 * 1000;
const RELATIONS_PAGE_ERROR_MAX_DELAY_MS = 8 * 60 * 60 * 1000;
const RELATIONS_REFRESH_MIN_DELAY_MS = 18 * 60 * 60 * 1000;
const RELATIONS_REFRESH_MAX_DELAY_MS = 30 * 60 * 60 * 1000;
```

- [ ] **Step 2: Add the syncRelationsPage method**

Insert this method on the `LinkedIn` class, immediately after the existing `syncBatch` method (right before `onWebhookEvent`):

```ts
  /**
   * Conservative paginated backfill of the connected LinkedIn account's
   * 1st-degree relations into Plot's contact table. Each call fetches one
   * page (~100 relations), saves them as contacts, and reschedules itself
   * with a 2–4h jittered delay. Stops rescheduling once Unipile returns
   * `nextCursor === null`. The refresh task (refreshRelationsList) rearms
   * this loop ~once per day to pick up new connections.
   *
   * Pacing is deliberate. Unipile's docs explicitly warn against
   * fixed-interval polling of the relations list; the 2–4h randomized
   * window matches their "first page only a few times a day at random
   * intervals" guidance and keeps the connector well under the documented
   * ~100/day profile-retrieval ceiling (this endpoint is the list, not
   * a per-relation profile fetch).
   */
  async syncRelationsPage(channelId: string): Promise<void> {
    const state = (await this.get<RelationsSyncState>(
      `relations_state_${channelId}`
    )) ?? {
      cursor: null,
      completed: false,
      lastCompletedAt: null,
      lastPageAt: 0,
    };

    if (state.completed) {
      // Refresh task is what un-completes us. Don't reschedule.
      return;
    }

    let nextCursor: string | null;
    try {
      const page = await this.tools.linkedin.listRelations({
        channelId,
        cursor: state.cursor,
        limit: RELATIONS_PAGE_LIMIT,
      });

      const contacts: NewContact[] = page.relations
        .map(profileToContact)
        .filter((c): c is NewContact => c != null);

      if (contacts.length > 0) {
        await this.tools.integrations.saveContacts(contacts);
      }

      nextCursor = page.nextCursor;

      const completed = nextCursor === null;
      await this.set(`relations_state_${channelId}`, {
        cursor: nextCursor,
        completed,
        lastCompletedAt: completed ? Date.now() : state.lastCompletedAt,
        lastPageAt: Date.now(),
      } satisfies RelationsSyncState);

      if (completed) {
        const refreshDelay =
          RELATIONS_REFRESH_MIN_DELAY_MS +
          Math.random() *
            (RELATIONS_REFRESH_MAX_DELAY_MS - RELATIONS_REFRESH_MIN_DELAY_MS);
        const refresh = await this.callback(
          this.refreshRelationsList,
          channelId
        );
        await this.runTask(refresh, {
          runAt: new Date(Date.now() + refreshDelay),
        });
        return;
      }
    } catch (error) {
      console.warn(
        `LinkedIn relations backfill page failed for channel ${channelId}`,
        error
      );
      // Cursor stays put. Retry on a longer backoff so we don't immediately
      // re-enter a rate-limited window.
      const errorDelay =
        RELATIONS_PAGE_ERROR_MIN_DELAY_MS +
        Math.random() *
          (RELATIONS_PAGE_ERROR_MAX_DELAY_MS -
            RELATIONS_PAGE_ERROR_MIN_DELAY_MS);
      const retry = await this.callback(this.syncRelationsPage, channelId);
      await this.runTask(retry, {
        runAt: new Date(Date.now() + errorDelay),
      });
      return;
    }

    const delayMs =
      RELATIONS_PAGE_MIN_DELAY_MS +
      Math.random() *
        (RELATIONS_PAGE_MAX_DELAY_MS - RELATIONS_PAGE_MIN_DELAY_MS);
    const next = await this.callback(this.syncRelationsPage, channelId);
    await this.runTask(next, { runAt: new Date(Date.now() + delayMs) });
  }
```

Note: `profileToContact` is already declared at the bottom of the same file (line 458). `NewContact` is already imported at the top.

- [ ] **Step 3: Verify typecheck**

```bash
cd connectors/linkedin && pnpm exec tsc --noEmit
```

Expected: errors about `refreshRelationsList` not being defined on `this`. That's fine — Task 7 adds it.

- [ ] **Step 4: Commit (with Task 7 — they're paired)**

Hold the commit until Task 7's method is in place. Move on.

---

## Task 7: refreshRelationsList method + onChannelEnabled/Disabled wiring

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

- [ ] **Step 1: Add refreshRelationsList**

Insert immediately after the `syncRelationsPage` method in `connectors/linkedin/src/linkedin.ts`:

```ts
  /**
   * Rearm the relations backfill loop after a completed pass. Resets the
   * cursor to null and immediately schedules `syncRelationsPage`. Catches
   * relations added/removed since the last full pass without needing a
   * fixed-cadence polling loop.
   */
  async refreshRelationsList(channelId: string): Promise<void> {
    const state = await this.get<RelationsSyncState>(
      `relations_state_${channelId}`
    );
    await this.set(`relations_state_${channelId}`, {
      cursor: null,
      completed: false,
      lastCompletedAt: state?.lastCompletedAt ?? null,
      lastPageAt: state?.lastPageAt ?? 0,
    } satisfies RelationsSyncState);

    const next = await this.callback(this.syncRelationsPage, channelId);
    await this.runTask(next, { runAt: new Date() });
  }
```

- [ ] **Step 2: Initialize state and kick off backfill in onChannelEnabled**

Modify the existing `onChannelEnabled` method. The current implementation is:

```ts
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_state_${channel.id}`, {
      initialSync: true,
      lastMessageHighWaterMs: null,
      lastInvitationHighWaterMs: null,
    } satisfies SyncState);

    const webhookCallback = await this.tools.callbacks.createFromParent(
      this.onWebhookEvent,
      channel.id
    );
    await this.set(`webhook_callback_${channel.id}`, webhookCallback);

    const batch = await this.callback(this.syncBatch, channel.id, true);
    await this.runTask(batch);
  }
```

Add the relations bootstrap immediately before the closing brace, after the existing `runTask(batch)` line:

```ts
    // Relations backfill — populates Plot contacts so compose can offer
    // every LinkedIn 1st-degree connection as a recipient. First page runs
    // immediately; subsequent pages jittered 2–4h apart. See
    // syncRelationsPage for the rationale.
    await this.set(`relations_state_${channel.id}`, {
      cursor: null,
      completed: false,
      lastCompletedAt: null,
      lastPageAt: 0,
    } satisfies RelationsSyncState);
    const firstRelationsPage = await this.callback(
      this.syncRelationsPage,
      channel.id
    );
    await this.runTask(firstRelationsPage);
```

- [ ] **Step 3: Clear state in onChannelDisabled**

Update `onChannelDisabled` from:

```ts
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);
  }
```

To:

```ts
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`webhook_callback_${channel.id}`);
    await this.clear(`relations_state_${channel.id}`);
  }
```

- [ ] **Step 4: Verify connector typecheck**

```bash
cd connectors/linkedin && pnpm exec tsc --noEmit
```

Expected: no errors. If errors remain about missing `listRelations` on `this.tools.linkedin`, the workspace link is stale — run `cd libs/unipile && pnpm build` then `pnpm install` at repo root.

- [ ] **Step 5: Commit Tasks 6 + 7 together**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "Backfill LinkedIn relations into Plot contacts on conservative schedule"
```

---

## Task 8: Webhook dispatch — users.new_relation

**Files:**
- Modify: `workers/api/src/app/hook-messaging.ts`

The Unipile `users` webhook source emits `users.new_relation` events when LinkedIn adds a new 1st-degree connection (typically up to ~8h after acceptance, because Unipile polls internally). We already register the `users` webhook source for invitations; this just adds another event branch.

- [ ] **Step 1: Add the new dispatch kind to classifyEvent**

In `workers/api/src/app/hook-messaging.ts`, update `classifyEvent`'s return type and add the branch. Change the signature from:

```ts
function classifyEvent(
  event: HostedWebhookEvent
):
  | "account.connected"
  | "account.needs_reauth"
  | "messaging.new_message"
  | "users.invitation.received"
  | null {
```

to:

```ts
function classifyEvent(
  event: HostedWebhookEvent
):
  | "account.connected"
  | "account.needs_reauth"
  | "messaging.new_message"
  | "users.invitation.received"
  | "users.new_relation"
  | null {
```

Then add a new branch directly after the existing `users.invitation.received` line in the function body:

```ts
  if (event.event_type === "users.new_relation") {
    return "users.new_relation";
  }
```

- [ ] **Step 2: Add the dispatch case**

In the switch statement inside the route handler, add a case after `users.invitation.received`:

```ts
      case "users.new_relation":
        await handleNewRelation(c.env, ctx, event, logger);
        break;
```

- [ ] **Step 3: Implement handleNewRelation**

Append this function at the bottom of the file (after `handleInvitationReceived`, before `export default`):

```ts
async function handleNewRelation(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  event: HostedWebhookEvent,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const accountId = event.account_id;
  // Unipile delivers the connected member's id under a few possible keys
  // depending on payload revision; check the documented one first.
  const profileId =
    (event.payload?.member_id as string | undefined) ??
    (event.payload?.user_id as string | undefined) ??
    (event.payload?.provider_id as string | undefined);
  logger.info("new_relation received", {
    account_id: accountId,
    profile_id: profileId,
  });

  if (!accountId) {
    logger.warn("new_relation event missing account_id, dropping");
    return;
  }
  if (!profileId) {
    logger.warn("new_relation event missing member id, dropping", {
      payload_keys: event.payload ? Object.keys(event.payload) : [],
    });
    return;
  }

  const db = createDb(env);
  let twistInstanceId: string | undefined;
  try {
    const row = await db
      .selectFrom("channel")
      .select("twist_instance_id")
      .where("channel_id", "=", accountId)
      .executeTakeFirst();
    twistInstanceId = row?.twist_instance_id;
  } finally {
    await db.destroy();
  }

  if (!twistInstanceId) {
    logger.warn("No channel found for account_id, dropping new_relation", {
      account_id: accountId,
    });
    return;
  }

  const callbackKey = `webhook_callback_${accountId}`;
  const token = await loadConnectorCallback(env, twistInstanceId, callbackKey);
  if (!token) {
    logger.warn(
      "Webhook callback not yet stored for account, dropping new_relation",
      { account_id: accountId, twist_instance_id: twistInstanceId }
    );
    return;
  }

  try {
    const result = await invokeWebhookCallback(env, ctx, token, {
      kind: "relation.new",
      profileId,
    });
    disposeRpc(result);
    logger.info("new_relation callback invoked", {
      account_id: accountId,
      twist_instance_id: twistInstanceId,
    });
  } catch (error) {
    if (isCallbackError(error)) {
      const errorType = getCallbackErrorType(error as Error);
      if (
        errorType === "NOT_FOUND" ||
        errorType === "EXPIRED" ||
        errorType === "INVALID_TOKEN" ||
        errorType === "INVALID_TOKEN_FORMAT"
      ) {
        logger.warn(
          "Webhook callback permanently unavailable for new_relation",
          { account_id: accountId, error_type: errorType }
        );
        return;
      }
    }
    throw error;
  }
}
```

- [ ] **Step 4: Verify the API worker typechecks**

```bash
cd workers/api && pnpm exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/hook-messaging.ts
git commit -m "Dispatch Unipile users.new_relation webhook to connector"
```

---

## Task 9: Connector — handle relation.new in onWebhookEvent

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

- [ ] **Step 1: Extend the event union and handler**

In `connectors/linkedin/src/linkedin.ts`, replace the current `onWebhookEvent` signature and body. The existing method is:

```ts
  async onWebhookEvent(
    event:
      | { kind: "message.received"; chatId: string; messageId: string }
      | { kind: "invitation.received"; invitationId: string },
    channelId: string
  ): Promise<void> {
    if (event.kind === "message.received") {
      const chat = await this.tools.linkedin.getChat({
        channelId,
        chatId: event.chatId,
      });
      const link = chat.isGroup
        ? await this.buildGroupLink(channelId, chat, false, undefined)
        : await this.build1to1ConversationLink(channelId, chat, false, undefined);
      if (link) await this.tools.integrations.saveLinks([link]);
    } else {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 1,
      });
      const target = result.invitations.find(
        (i) => i.id === event.invitationId
      );
      if (!target) return;
      const link = buildInvitationLink(channelId, target, false);
      await this.tools.integrations.saveLinks([link]);
    }
  }
```

Replace it with:

```ts
  async onWebhookEvent(
    event:
      | { kind: "message.received"; chatId: string; messageId: string }
      | { kind: "invitation.received"; invitationId: string }
      | { kind: "relation.new"; profileId: string },
    channelId: string
  ): Promise<void> {
    if (event.kind === "message.received") {
      const chat = await this.tools.linkedin.getChat({
        channelId,
        chatId: event.chatId,
      });
      const link = chat.isGroup
        ? await this.buildGroupLink(channelId, chat, false, undefined)
        : await this.build1to1ConversationLink(channelId, chat, false, undefined);
      if (link) await this.tools.integrations.saveLinks([link]);
    } else if (event.kind === "invitation.received") {
      const result = await this.tools.linkedin.listReceivedInvitations({
        channelId,
        limit: 1,
      });
      const target = result.invitations.find(
        (i) => i.id === event.invitationId
      );
      if (!target) return;
      const link = buildInvitationLink(channelId, target, false);
      await this.tools.integrations.saveLinks([link]);
    } else {
      // relation.new — a new 1st-degree LinkedIn connection. Fetch the
      // profile and save as a Plot contact. Existing person-keyed links
      // (chats/invitations) will dedupe onto the same contact_external_account
      // row via (LinkedIn, profileId).
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
    }
  }
```

- [ ] **Step 2: Verify typecheck**

```bash
cd connectors/linkedin && pnpm exec tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "Handle LinkedIn new_relation webhook in connector"
```

---

## Task 10: Lint pass

**Files:**
- All modified files.

- [ ] **Step 1: Run lint on each changed package**

```bash
cd libs/unipile && pnpm lint
cd connectors/linkedin && pnpm lint
cd workers/api && pnpm lint
```

Expected: all pass. Fix any errors inline; if a rule violation is unavoidable (e.g. `@typescript-eslint/no-unused-vars` on an abstract method's parameters), match the existing file convention — see the `// eslint-disable-next-line` directives already present in `libs/unipile/src/linkedin.ts`.

- [ ] **Step 2: Commit any lint fixes**

```bash
git add -u
git commit -m "Lint fixes for relations backfill"
```

(Skip if no fixes were needed.)

---

## Task 11: Manual verification

Connector code is not covered by automated tests in this repo; do an end-to-end walkthrough against the local stack. This task is documentation, not a code change — no commit.

- [ ] **Step 1: Ensure the API worker and local DB are running**

```bash
pnpm --filter @plotday/api dev
```

In another terminal, confirm `$DATABASE_URL` is set for this worktree (`echo $DATABASE_URL`). If not, run `bash scripts/worktree-db` first.

- [ ] **Step 2: Enable a LinkedIn channel against a Unipile sandbox account**

Use the existing connector flow (web UI or whatever is wired). On enable, you should see in the API worker logs:

- `syncBatch` running once immediately (existing behavior — chats + invitations).
- `syncRelationsPage` running once immediately (NEW — relations page 1).

- [ ] **Step 3: Verify contacts landed in the local DB**

Replace `<LINKEDIN_TWIST_INSTANCE_ID>` with the actual `twist_instance_id` for the channel (look it up in the `channel` table by your `channel_id`).

```bash
psql "$DATABASE_URL" -c "
  SELECT cea.provider, cea.account_id, c.name
  FROM contact_external_account cea
  JOIN contact c ON c.id = cea.contact_id
  WHERE cea.provider = 'linkedin'
  ORDER BY cea.account_id
  LIMIT 20;
"
```

Expected: rows with `provider='linkedin'` and `account_id` matching member IDs from your sandbox account's connections.

- [ ] **Step 4: Verify pagination state persisted**

In the local twist storage, the key `relations_state_<channelId>` should now have `cursor != null` (unless the sandbox account has <100 connections, in which case `completed: true`).

You can inspect via the connector's `this.get(...)` indirectly — easiest path is to log it from a temporary debug branch in `syncRelationsPage`, or read from the underlying Storage DO.

- [ ] **Step 5: Manually trigger the next page**

The next scheduled call is 2–4h out; you don't want to wait. Either:

(a) Temporarily tighten the jitter in `connectors/linkedin/src/linkedin.ts` (e.g. set both `RELATIONS_PAGE_MIN_DELAY_MS` and `RELATIONS_PAGE_MAX_DELAY_MS` to `60 * 1000` — one minute), restart the connector, and watch a few pages run.

(b) Or, if your local dev setup exposes a way to manually invoke twist callbacks, call `syncRelationsPage` directly.

Confirm: `cursor` advances each page; `completed: true` is set when `nextCursor === null`; a `refreshRelationsList` task is then scheduled and `syncRelationsPage` stops rescheduling itself.

**Revert any timing changes before committing.**

- [ ] **Step 6: Verify dedup with chats**

Send a LinkedIn DM from one of the relations to your sandbox account. The existing `syncBatch` (or messaging webhook) should pick it up and create a person-keyed link. Re-run the query from Step 3:

```bash
psql "$DATABASE_URL" -c "
  SELECT cea.provider, cea.account_id, count(*) as rows
  FROM contact_external_account cea
  WHERE cea.provider = 'linkedin' AND cea.account_id = '<MEMBER_ID>'
  GROUP BY cea.provider, cea.account_id;
"
```

Expected: exactly one row. The chat link reused the contact from the backfill — no duplicate.

- [ ] **Step 7: Spot-check compose UI**

Open the Flutter app, navigate to wherever a new thread / compose / recipient picker exists. Try typing a LinkedIn contact's name.

Two possible outcomes:

- **The contact appears as a suggestion** → end-to-end works. Done.
- **The contact does not appear** → Plot's compose picker today filters to contacts with existing threads. File a follow-up to surface threadless contacts (the design doc lists this in "Out of scope follow-ups"). Note this in the PR description; do **not** expand this PR's scope to include the Flutter change.

---

## Self-review (already done by plan author)

- **Spec coverage:** every architecture/orchestration item from the design doc has a task. Backfill loop → Task 6. Refresh task → Task 7. Webhook event branch → Tasks 8+9. `saveContacts` → Tasks 6, 9. Conservative 2–4h jitter → Task 6 constants. Error backoff 4–8h → Task 6.
- **Placeholders:** none. Every step shows the exact code.
- **Type consistency:** `LinkedInProfile` used everywhere a relation lands; `RelationsSyncState` shape identical in tasks 6 and 7; `relation.new` event kind matches between hook-messaging.ts (Task 8) and the connector (Task 9); `profileId` field name consistent across the boundary.
- **One spec requirement deliberately not implemented as its own task:** the design mentions "log unhandled `users.*` event types." Existing `hook-messaging.ts` already does that via the `default` branch of the dispatch switch — no new code needed.

Plan complete and saved to `docs/superpowers/plans/2026-05-24-linkedin-relations-backfill.md`.
