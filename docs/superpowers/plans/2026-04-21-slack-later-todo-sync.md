# Slack Later ⇄ Plot To-Do Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two-way sync between Slack's "Later / Saved for later" list and Plot's to-do state on Slack-synced threads, mirroring the Gmail connector's star ↔ to-do pattern.

**Architecture:** Plot's to-do state is the canonical signal. The Slack connector holds a `starred:${channelId}:${threadTs}` state per thread, echoes changes in both directions via the Integrations tool's `setThreadToDo`, and uses a one-shot `skip_todo_writeback:` flag to break loops. Slack's user-token endpoints (`stars.*`) are reached through a new `getUserToken(channelId)` accessor on the Integrations tool.

**Tech Stack:** TypeScript, Cloudflare Workers (twist runtime), Slack Web API, Plot Twister SDK (`@plotday/twister`), Slack Events API. Repo uses pnpm workspaces; connectors have no unit-test suite — the feedback loop is `pnpm build` + `pnpm lint` per package, plus manual verification against a dev Slack workspace.

**Reference spec:** `docs/superpowers/specs/2026-04-21-slack-later-todo-sync-design.md`

**Reference implementation:** `public/connectors/gmail/src/gmail.ts` (star ↔ to-do plumbing is lines ~440-690).

---

## File Structure

**Twister SDK (public submodule):**
- Modify: `public/twister/src/tools/integrations.ts` — add `abstract getUserToken(channelId: string): Promise<string | null>`
- Create: `public/.changeset/slack-user-token-accessor.md` — changeset for the SDK change

**API worker:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — implement `getUserToken()`, resolving `authed_user.access_token` from the stored `providerData` (currently used by Slack only)

**Slack connector (public submodule):**
- Modify: `public/connectors/slack/src/slack-api.ts` — add `addStar`, `removeStar`, `listStars` methods; export `StarsListItem` type
- Modify: `public/connectors/slack/src/slack.ts` — add user scopes, `activate()`, `linkTypes.statuses`, `getUserApi()`, `onThreadToDo`, `onLinkUpdated`, `star_added`/`star_removed` handling in `onSlackWebhook`, initial backfill, cleanup on disable

**Docs:**
- Modify: `docs/updates.md` — user-facing note about Slack re-auth + new Later ⇄ to-do behavior

**Out of repo (noted, not edited):**
- Slack app manifest — subscribe to `star_added` and `star_removed` events. This is a configuration change in the Slack app dashboard / manifest file kept outside this repository; call it out in the final task.

---

## Task 1: Add `getUserToken` abstract method to Twister Integrations tool

**Files:**
- Modify: `public/twister/src/tools/integrations.ts:243` (class body, after `setThreadToDo`)
- Create: `public/.changeset/slack-user-token-accessor.md`

- [ ] **Step 1: Add the abstract method to the Integrations class**

Open `public/twister/src/tools/integrations.ts`. Immediately before the closing `}` of the `Integrations` abstract class (which currently sits on line 243, right after `setThreadToDo`'s declaration), add:

```ts
  /**
   * Retrieves a provider-specific secondary user token for a channel.
   *
   * Some providers (notably Slack via OAuth v2) issue both a bot-level
   * access token and a per-user access token in the same OAuth response.
   * `get(channelId)` returns the bot token; this method returns the
   * user token (`authed_user.access_token` for Slack) when one exists.
   *
   * Returns null for providers that don't have a separate user token,
   * or when the channel is not enabled.
   *
   * @param channelId - The channel resource ID
   * @returns Promise resolving to the user access token string or null
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getUserToken(channelId: string): Promise<string | null>;
```

- [ ] **Step 2: Type-check the SDK**

Run from repo root:

```
cd public/twister && pnpm build
```

Expected: completes without TypeScript errors, emits updated `.d.ts` in `dist/`.

- [ ] **Step 3: Create the changeset**

Create `public/.changeset/slack-user-token-accessor.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `Integrations.getUserToken(channelId)` for retrieving provider-issued secondary user tokens (currently the Slack `authed_user.access_token`). Used by connectors that need user-scoped endpoints alongside bot-scoped sync.
```

- [ ] **Step 4: Validate changesets**

Run from `public/`:

```
cd public && pnpm validate-changesets
```

Expected: exits 0, lists the new changeset.

- [ ] **Step 5: Reinstall workspace to refresh the symlinked build output**

Run from repo root:

```
pnpm install
```

Expected: completes without errors. The workspace resolves `@plotday/twister` from the `public/twister` directory with the rebuilt types.

- [ ] **Step 6: Commit**

```
git add public/twister/src/tools/integrations.ts public/.changeset/slack-user-token-accessor.md
git commit -m "twister: add Integrations.getUserToken() for provider-scoped user tokens"
```

Note: the `public/` directory is a submodule — the commit above runs inside `public/`. Verify with `git -C public status` that the changes are on a branch in the submodule, then return to the main repo and commit the submodule pointer update in a later task.

---

## Task 2: Implement `getUserToken` in the API worker Integrations tool

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — add `getUserToken` method below the existing `get()` implementation (around line 293)

- [ ] **Step 1: Confirm where `StoredTokenData.providerData` is declared**

Open `workers/api/src/provider.ts`. Verify `SlackProviderData.authed_user.access_token` is a string (line 19). Verify `StoredTokenData` at line 77 carries `providerData: ProviderData | null`.

- [ ] **Step 2: Implement `getUserToken`**

In `workers/api/src/twist/tools/integrations.ts`, find the end of the existing `get()` method (closing `}` around line 293) and add immediately after it:

```ts
  /**
   * Retrieves a provider-specific secondary user token for a channel.
   * Currently implemented for Slack, where OAuth v2 returns a separate
   * `authed_user.access_token` alongside the bot token. Returns null for
   * providers that don't distinguish bot vs. user tokens.
   */
  async getUserToken(channelId: string): Promise<string | null> {
    const provider = this.providerConfigs[0]?.provider;
    if (!provider) return null;

    const config = await this.getChannelConfig(provider, channelId);
    const actorId = config?.enabled ? config.enabledBy : null;
    if (!actorId) return null;

    const tokenKey = `auth_token:${provider}:${actorId}`;
    const tokenData = await this.store.get<StoredTokenData>(tokenKey);
    const providerData = tokenData?.providerData;
    if (!providerData) return null;

    if (provider === AuthProvider.Slack) {
      const slackData = providerData as SlackProviderData;
      return slackData.authed_user?.access_token ?? null;
    }

    return null;
  }
```

- [ ] **Step 3: Add missing imports if needed**

At the top of `workers/api/src/twist/tools/integrations.ts`, confirm (or add):

```ts
import type { SlackProviderData, StoredTokenData } from "../../provider";
```

Check the existing imports — `StoredTokenData` is already used in `getActorToken()` (line 1545), so the import likely exists. Add `SlackProviderData` if it's not already present.

- [ ] **Step 4: Type-check the API worker**

Run from repo root:

```
pnpm --filter @plotday/api exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 5: Commit**

```
git add workers/api/src/twist/tools/integrations.ts
git commit -m "api: implement Integrations.getUserToken for Slack authed_user token"
```

---

## Task 3: Add `addStar`, `removeStar`, `listStars` to `SlackApi`

**Files:**
- Modify: `public/connectors/slack/src/slack-api.ts` — add three methods at the end of the `SlackApi` class (before the closing `}` on line 192); export a small type for `stars.list` items

- [ ] **Step 1: Add the new methods and type**

Open `public/connectors/slack/src/slack-api.ts`. Immediately before the closing `}` of the `SlackApi` class (currently line 192), insert:

```ts
  public async addStar(channelId: string, timestamp: string): Promise<void> {
    await this.call("stars.add", { channel: channelId, timestamp });
  }

  public async removeStar(channelId: string, timestamp: string): Promise<void> {
    try {
      await this.call("stars.remove", { channel: channelId, timestamp });
    } catch (error) {
      // stars.remove returns `not_starred` when the item isn't saved; treat as idempotent success.
      const message = error instanceof Error ? error.message : String(error);
      if (!message.includes("not_starred")) throw error;
    }
  }

  public async listStars(cursor?: string): Promise<{
    items: StarsListItem[];
    nextCursor?: string;
  }> {
    const params: Record<string, string | number> = { limit: 100 };
    if (cursor) params.cursor = cursor;
    const data = await this.call("stars.list", params);
    return {
      items: (data.items ?? []) as StarsListItem[],
      nextCursor: data.response_metadata?.next_cursor,
    };
  }
```

Then, directly above the `SlackApi` class declaration (around line 68), add the exported item type:

```ts
export type StarsListItem = {
  type: string;
  channel?: string;
  message?: {
    ts: string;
    thread_ts?: string;
  };
};
```

- [ ] **Step 2: Type-check the connector**

Run from repo root:

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 3: Commit (inside the submodule)**

```
git -C public add connectors/slack/src/slack-api.ts
git -C public commit -m "connector-slack: add stars.add/remove/list API wrappers"
```

---

## Task 4: Declare Slack user scopes, `activate()`, and Later status

**Files:**
- Modify: `public/connectors/slack/src/slack.ts`

- [ ] **Step 1: Add user scopes**

Find `static readonly SCOPES = [...]` (currently lines 67-77). Extend the array:

```ts
  static readonly SCOPES = [
    "channels:history",
    "channels:read",
    "groups:history",
    "groups:read",
    "users:read",
    "users:read.email",
    "chat:write",
    "im:history",
    "mpim:history",
    "stars:read",
    "stars:write",
  ];
```

- [ ] **Step 2: Extend `linkTypes` with statuses**

Find `readonly linkTypes = [{ type: "message", ... }]` (currently line 81). Rewrite it as:

```ts
  readonly linkTypes = [
    {
      type: "message",
      label: "Message",
      logo: "https://api.iconify.design/logos/slack-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/slack.svg",
      statuses: [
        { status: "inbox", label: "Inbox" },
        { status: "later", label: "Later", tag: Tag.Star, todo: true },
      ],
    },
  ];
```

- [ ] **Step 3: Import `Tag` and `Actor` types**

At the top of `slack.ts`, extend the `@plotday/twister` import block:

```ts
import {
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import { Tag } from "@plotday/twister/tag";
import type { Actor, ActorId, Link, Note, Thread } from "@plotday/twister/plot";
```

(Preserve other existing imports. `Actor` and `ActorId` are needed for the to-do handlers below; `Link` is needed for `onLinkUpdated`; `Note`, `Thread` are already imported.)

- [ ] **Step 4: Add the `activate()` override**

Directly above the existing `async getChannels(...)` method (line 90), add:

```ts
  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }
```

Ensure `Authorization` is already in the `integrations` import block at the top (it is, line 10).

- [ ] **Step 5: Type-check**

Run from repo root:

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0. If errors mention missing imports, double-check that `Tag`, `Actor`, `ActorId`, and `Link` are all in scope.

- [ ] **Step 6: Commit (inside submodule)**

```
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "connector-slack: declare stars scopes, Later status, activate() actor capture"
```

---

## Task 5: Add `getUserApi()` and Plot → Slack writeback handlers

**Files:**
- Modify: `public/connectors/slack/src/slack.ts`

- [ ] **Step 1: Add `getUserApi()` helper**

Directly below the existing `getApi()` method (currently lines 147-153), add:

```ts
  private async getUserApi(channelId: string): Promise<SlackApi> {
    const token = await this.tools.integrations.getUserToken(channelId);
    if (!token) {
      throw new Error(
        "No Slack user token available (missing stars:read/stars:write scopes?)"
      );
    }
    return new SlackApi(token);
  }
```

- [ ] **Step 2: Add the key-building helper (co-locate with the writeback handlers)**

At the bottom of the `Slack` class, directly above the last closing `}` of the class body (currently line 406, just above the final `}` that ends the class), add a small helper. First add the helper, then the two handlers:

```ts
  private starredKey(channelId: string, threadTs: string): string {
    return `starred:${channelId}:${threadTs}`;
  }

  private skipKey(channelId: string, threadTs: string): string {
    return `skip_todo_writeback:${channelId}:${threadTs}`;
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = meta.channelId as string | undefined;
    const threadTs = meta.threadTs as string | undefined;
    if (!channelId || !threadTs) return;

    if (await this.get(this.skipKey(channelId, threadTs))) {
      await this.clear(this.skipKey(channelId, threadTs));
      return;
    }

    // Update local state BEFORE calling Slack so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(this.starredKey(channelId, threadTs), todo);

    const api = await this.getUserApi(channelId);
    if (todo) {
      await api.addStar(channelId, threadTs);
    } else {
      await api.removeStar(channelId, threadTs);
    }
  }

  async onLinkUpdated(link: Link): Promise<void> {
    const channelId = link.meta?.channelId as string | undefined;
    const threadTs = link.meta?.threadTs as string | undefined;
    if (!channelId || !threadTs) return;

    if (await this.get(this.skipKey(channelId, threadTs))) {
      await this.clear(this.skipKey(channelId, threadTs));
      return;
    }

    const isLater = link.status === "later";
    await this.set(this.starredKey(channelId, threadTs), isLater);

    const api = await this.getUserApi(channelId);
    if (isLater) {
      await api.addStar(channelId, threadTs);
    } else {
      await api.removeStar(channelId, threadTs);
    }
  }
```

- [ ] **Step 3: Type-check**

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 4: Commit (submodule)**

```
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "connector-slack: Plot→Slack Later writeback via onThreadToDo/onLinkUpdated"
```

---

## Task 6: Handle `star_added` / `star_removed` in `onSlackWebhook`

**Files:**
- Modify: `public/connectors/slack/src/slack.ts` — `onSlackWebhook` (currently lines 314-350)

- [ ] **Step 1: Rewrite `onSlackWebhook` to dispatch by event type**

Replace the existing `onSlackWebhook` method body with:

```ts
  async onSlackWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    const body = request.body;
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      console.warn("Invalid webhook body format");
      return;
    }

    const bodyObj = body as { challenge?: string; event?: any };
    if (bodyObj.challenge) {
      return; // URL verification challenge handled by infra
    }

    const event = bodyObj.event;
    if (!event) return;

    if (event.type === "star_added" || event.type === "star_removed") {
      await this.handleStarEvent(event, event.type === "star_added");
      return;
    }

    if (
      event.type === "message" &&
      event.channel === channelId &&
      !event.subtype
    ) {
      await this.startIncrementalSync(channelId);
    }
  }

  private async handleStarEvent(event: any, isStarred: boolean): Promise<void> {
    const item = event.item;
    if (!item || item.type !== "message") return;

    const channelId = item.channel as string | undefined;
    const messageTs = item.message?.ts as string | undefined;
    const parentTs = (item.message?.thread_ts as string | undefined) ?? messageTs;
    if (!channelId || !parentTs) return;

    // Gate on enabled channels: ignore stars in channels the user
    // hasn't opted into for Plot sync (v1 scope).
    if (!(await this.get<boolean>(`sync_enabled_${channelId}`))) return;

    const wasStarred = !!(await this.get<boolean>(this.starredKey(channelId, parentTs)));
    if (wasStarred === isStarred) return; // our own echo

    const actorId = await this.get<ActorId>("auth_actor_id");
    if (!actorId) {
      console.error("No auth_actor_id; cannot apply star event");
      return;
    }

    const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${parentTs}`;

    await this.tools.integrations.setThreadToDo(canonicalUrl, actorId, isStarred);

    // Block the onThreadToDo callback that Plot will queue in response.
    await this.set(this.skipKey(channelId, parentTs), true);

    // Record the new state so subsequent duplicate events short-circuit.
    await this.set(this.starredKey(channelId, parentTs), isStarred);
  }
```

- [ ] **Step 2: Type-check**

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 3: Commit (submodule)**

```
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "connector-slack: Slack→Plot Later sync via star_added/star_removed events"
```

---

## Task 7: Initial backfill of existing Later items on channel enable

**Files:**
- Modify: `public/connectors/slack/src/slack.ts` — extend `onChannelEnabled` (currently line 101-140) to queue a backfill task; add the `backfillStars` method

- [ ] **Step 1: Queue the backfill callback in `onChannelEnabled`**

Find the block inside `onChannelEnabled` that queues `syncCallback` and `webhookCallback` (lines 125-139). Immediately after the `webhookCallback` `runTask` call, add:

```ts
    const backfillCallback = await this.callback(this.backfillStars, channel.id);
    await this.runTask(backfillCallback);
```

- [ ] **Step 2: Add the `backfillStars` method**

Directly below `startIncrementalSync` (around line 375), add:

```ts
  async backfillStars(channelId: string): Promise<void> {
    const actorId = await this.get<ActorId>("auth_actor_id");
    if (!actorId) return;

    let api: SlackApi;
    try {
      api = await this.getUserApi(channelId);
    } catch (error) {
      console.warn("backfillStars: user token unavailable", error);
      return;
    }

    let cursor: string | undefined = undefined;
    do {
      const { items, nextCursor } = await api.listStars(cursor);

      for (const item of items) {
        if (item.type !== "message") continue;
        if (item.channel !== channelId) continue;

        const messageTs = item.message?.ts;
        const parentTs = item.message?.thread_ts ?? messageTs;
        if (!parentTs) continue;

        const alreadyStarred = await this.get<boolean>(
          this.starredKey(channelId, parentTs)
        );
        if (alreadyStarred) continue;

        const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${parentTs}`;

        try {
          await this.tools.integrations.setThreadToDo(canonicalUrl, actorId, true);
        } catch (error) {
          console.warn("backfillStars: setThreadToDo failed", parentTs, error);
          // Continue with other items.
        }

        // Block the onThreadToDo callback that Plot will queue, since the
        // item is already saved-for-later in Slack — no need to write again.
        await this.set(this.skipKey(channelId, parentTs), true);
        await this.set(this.starredKey(channelId, parentTs), true);
      }

      cursor = nextCursor;
    } while (cursor);
  }
```

Note: the imported `StarsListItem` type isn't referenced directly here (we rely on `listStars`'s declared return type), so no extra import is needed. If the type-checker complains, add:

```ts
import { SlackApi, type StarsListItem, /* existing... */ } from "./slack-api";
```

- [ ] **Step 3: Type-check**

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 4: Commit (submodule)**

```
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "connector-slack: backfill existing Later items on channel enable"
```

---

## Task 8: Clear per-channel Later state on disable

**Files:**
- Modify: `public/connectors/slack/src/slack.ts` — extend `stopSync` (currently line 209)

- [ ] **Step 1: Add key sweeping**

Replace the body of `stopSync` with:

```ts
  async stopSync(channelId: string): Promise<void> {
    await this.clear(`channel_webhook_${channelId}`);
    await this.clear(`sync_state_${channelId}`);

    // Sweep per-thread state for this channel so a re-enable starts clean.
    const starredKeys = await this.list(`starred:${channelId}:`);
    for (const key of starredKeys) await this.clear(key);

    const skipKeys = await this.list(`skip_todo_writeback:${channelId}:`);
    for (const key of skipKeys) await this.clear(key);
  }
```

`this.list(prefix)` is the standard Store API for prefix-scanning keys — declared as `abstract list(prefix: string): Promise<string[]>` in `public/twister/src/tools/store.ts:126` and referenced by the `preUpgrade()` pattern in `public/connectors/AGENTS.md`.

- [ ] **Step 2: Type-check**

```
pnpm --filter @plotday/connector-slack exec tsc --noEmit
```

Expected: exits 0.

- [ ] **Step 3: Commit (submodule)**

```
git -C public add connectors/slack/src/slack.ts
git -C public commit -m "connector-slack: clear per-thread Later state on channel disable"
```

---

## Task 9: Run `finalize` checks across affected packages

**Files:**
- All files modified above.

- [ ] **Step 1: Build the Twister SDK**

```
cd public/twister && pnpm build
```

Expected: exits 0, `dist/` has up-to-date `.d.ts` for `Integrations.getUserToken`.

- [ ] **Step 2: Build the Slack connector**

```
cd public/connectors/slack && pnpm build
```

Expected: exits 0.

- [ ] **Step 3: Lint the API worker**

```
pnpm --filter @plotday/api lint
```

Expected: exits 0.

- [ ] **Step 4: Validate changesets**

```
cd public && pnpm validate-changesets
```

Expected: exits 0.

- [ ] **Step 5: Commit build/lint fixes if any**

If lint surfaced fixes:

```
git add <files>
git commit -m "fix: address lint findings from finalize pass"
```

---

## Task 10: Update `docs/updates.md`

**Files:**
- Modify: `docs/updates.md` — add a bullet to the current top section

- [ ] **Step 1: Read the current top section**

Open `docs/updates.md`. The top section is the in-progress update — add one bullet at the bottom of its bullet list. Do not add a new `---` separator; only the user does that on publish.

- [ ] **Step 2: Add the bullet**

Add (in plain user language — no jargon):

```
- Slack: save a message for Later and it becomes a to-do in Plot. Toggle the to-do in Plot and the message saves/unsaves in Slack. You'll need to reconnect Slack once to grant the new permission.
```

- [ ] **Step 3: Commit**

```
git add docs/updates.md
git commit -m "docs: Slack Later ⇄ Plot to-do in updates.md"
```

---

## Task 11: Update submodule pointer and note Slack app config change

**Files:**
- Modify: root `.gitmodules` is unchanged; just commit the updated `public/` submodule pointer in the main repo.
- Out of repo: Slack app manifest subscription for `star_added`, `star_removed`.

- [ ] **Step 1: Push the submodule branch**

From inside `public/`:

```
git -C public push --set-upstream origin <branch-name>
```

Use whatever feature branch you've been committing on inside the submodule. Open a PR against the `public` repo's default branch. Note the PR URL — you'll reference it in the main repo's PR description.

- [ ] **Step 2: Update the submodule pointer in the main repo**

From repo root:

```
git add public
git commit -m "bump public submodule: slack Later/to-do sync + twister getUserToken"
```

- [ ] **Step 3: Add `star_added` and `star_removed` to the Slack app event subscriptions**

This step is **outside the repo**: edit the Plot Slack app configuration (via the Slack app dashboard at api.slack.com, or the team's `slack-app-manifest.yaml` if one is tracked in a separate repo) so that the following events are subscribed under "Event Subscriptions" → "Subscribe to bot/user events":

- `star_added` (user-scope event)
- `star_removed` (user-scope event)

These need to be under user events, not bot events, because stars are per-user. Document who made this change in the PR description; ideally a team-mate with Slack app admin access applies it before release.

- [ ] **Step 4: Push and open a PR for the main repo**

```
git push --set-upstream origin <feature-branch>
```

Open a PR referencing the submodule PR and the Slack app manifest change.

---

## Manual Verification

Run against a development Slack workspace. These mirror the test plan in the spec.

- [ ] **V1: Re-auth and scope acceptance**

With an existing Slack connection on dev, trigger re-auth. Verify the scope consent screen now includes "Save items for later" (the Slack product name for `stars:read`/`stars:write`) and complete the auth flow.

- [ ] **V2: Initial backfill**

Before enabling a test channel, save 2–3 messages in that channel for Later in Slack. Enable the channel in Plot. After the history sync completes, verify those threads appear with the Star tag and as to-dos in Plot.

- [ ] **V3: Slack → Plot real-time**

In Slack, save a fresh message for Later. Within a few seconds, the corresponding Plot thread should flip to to-do. Unsave it in Slack; the to-do should clear.

- [ ] **V4: Plot → Slack real-time**

In Plot, toggle the Star/to-do on a synced Slack thread. In Slack, verify the corresponding message is now saved for later. Untoggle in Plot; verify Slack unsaves.

- [ ] **V5: Star on a reply**

In a Slack thread, save a reply (not the parent message) for Later. Verify the parent thread flips to to-do in Plot. Unsave the reply; verify Plot's to-do clears.

- [ ] **V6: Rapid flip-flop**

In Slack, save then unsave the same message three times within a couple of seconds. Verify Plot converges to the correct terminal state with no stuck to-do and no error logs about duplicate `setThreadToDo` calls.

- [ ] **V7: Channel disable**

Disable a synced channel in Plot. Re-enable it. Save a message for Later. Verify the star → to-do flow still works after the re-enable (confirms that `stopSync`'s state sweep didn't leave anything stale).

---

## Self-Review Notes

- Spec section 1 (OAuth scopes) → Task 4 step 1.
- Spec section 2 (link-type status) → Task 4 step 2.
- Spec section 3 (token selection) → Tasks 1, 2, 5 step 1.
- Spec section 4 (state keys) → Task 5 step 2 (helpers + usage).
- Spec section 5a (Slack → Plot) → Task 6.
- Spec section 5b (Plot → Slack) → Task 5 step 2.
- Spec section 5c (initial backfill) → Task 7.
- Spec section 6 (SlackApi additions) → Task 3.
- Spec section 7 (cleanup on disable) → Task 8.
- Spec section 8 (edge cases) → covered by logic in Tasks 6 and 7 (non-enabled channel gate, thread-parent resolution, idempotent removeStar).
- Docs / changeset / Slack app config → Tasks 9, 10, 11.
- Manual verification → "Manual Verification" section above.
