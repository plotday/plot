# Microsoft Teams Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-way Microsoft Teams connector that syncs channel messages and DMs into Plot, with reply write-back support.

**Architecture:** A `Connector<MsTeams>` class in `public/connectors/ms-teams/` following the Slack connector pattern. Graph API client handles all Microsoft Teams REST calls. Channel messages get real-time updates via Graph subscriptions; DMs use batch sync only with a synthetic `__direct_messages__` channel (matching Google Chat's pattern). Private threads for DMs use member mentions for visibility.

**Tech Stack:** TypeScript, `@plotday/twister` SDK, Microsoft Graph REST API v1.0

**Spec:** `docs/superpowers/specs/2026-04-08-ms-teams-connector-design.md`

---

## File Structure

| File | Purpose |
|------|---------|
| Create: `public/connectors/ms-teams/package.json` | Package config |
| Create: `public/connectors/ms-teams/tsconfig.json` | TypeScript config |
| Create: `public/connectors/ms-teams/src/index.ts` | Re-exports |
| Create: `public/connectors/ms-teams/src/graph-api.ts` | Microsoft Graph API client + types + transform functions |
| Create: `public/connectors/ms-teams/src/ms-teams.ts` | Main connector class |
| Modify: `apps/site/app/data/connections.ts:125` | Set `available: true` |

---

### Task 1: Package Scaffold

**Files:**
- Create: `public/connectors/ms-teams/package.json`
- Create: `public/connectors/ms-teams/tsconfig.json`
- Create: `public/connectors/ms-teams/src/index.ts`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "@plotday/connector-ms-teams",
  "displayName": "Microsoft Teams",
  "description": "Messages from your Microsoft Teams channels and chats",
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
    "lint": "plot lint"
  },
  "dependencies": {
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": {
    "typescript": "^5.9.3"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/plotday/plot.git",
    "directory": "connectors/ms-teams"
  },
  "homepage": "https://plot.day",
  "bugs": {
    "url": "https://github.com/plotday/plot/issues"
  },
  "keywords": [
    "plot",
    "connector",
    "microsoft-teams",
    "teams",
    "messaging"
  ],
  "publishConfig": {
    "access": "public"
  }
}
```

- [ ] **Step 2: Create tsconfig.json**

```json
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "extends": "@plotday/twister/tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist"
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 3: Create src/index.ts**

```typescript
export { default, MsTeams } from "./ms-teams";
```

- [ ] **Step 4: Install dependencies**

Run: `cd /Users/kris.braun/code/plot && pnpm install`

- [ ] **Step 5: Commit**

```bash
git add public/connectors/ms-teams/
git commit -m "feat(ms-teams): scaffold connector package"
```

---

### Task 2: Graph API Client

**Files:**
- Create: `public/connectors/ms-teams/src/graph-api.ts`

This file contains the Microsoft Graph API client, TypeScript types for Teams API responses, and transform functions for converting Teams messages to Plot's `NewLinkWithNotes` format.

- [ ] **Step 1: Create graph-api.ts with types and API client**

```typescript
import type {
  NewLinkWithNotes,
  NewActor,
} from "@plotday/twister/plot";
import { AuthProvider } from "@plotday/twister/tools/integrations";

// ---- Microsoft Graph API types ----

export type Team = {
  id: string;
  displayName: string;
  description?: string;
};

export type TeamsChannel = {
  id: string;
  displayName: string;
  description?: string;
  membershipType?: "standard" | "private" | "shared";
};

export type TeamsUser = {
  id: string;
  displayName?: string;
  mail?: string;
  userPrincipalName?: string;
};

export type TeamsMessageBody = {
  contentType: "text" | "html";
  content: string;
};

export type TeamsMessage = {
  id: string;
  createdDateTime: string;
  lastModifiedDateTime?: string;
  messageType: "message" | "systemEventMessage" | "unknownFutureValue";
  from?: {
    user?: TeamsUser;
    application?: { id: string; displayName?: string };
  };
  body: TeamsMessageBody;
  subject?: string | null;
  mentions?: Array<{
    id: number;
    mentionText: string;
    mentioned: {
      user?: TeamsUser;
    };
  }>;
  replies?: TeamsMessage[];
};

export type Chat = {
  id: string;
  topic?: string | null;
  chatType: "oneOnOne" | "group" | "meeting" | "unknownFutureValue";
  members?: ChatMember[];
};

export type ChatMember = {
  id: string;
  displayName?: string;
  email?: string;
  userId?: string;
};

export type Subscription = {
  id: string;
  resource: string;
  changeType: string;
  expirationDateTime: string;
  clientState?: string;
};

export type PaginatedResponse<T> = {
  value: T[];
  "@odata.nextLink"?: string;
};

export type SyncState = {
  channelId: string;
  cursor?: string;
  more?: boolean;
  oldest?: string;
  initialSync?: boolean;
};

// ---- Graph API Client ----

export class GraphApi {
  private baseUrl = "https://graph.microsoft.com/v1.0";

  constructor(public accessToken: string) {}

  private async call<T>(
    method: string,
    url: string,
    body?: unknown
  ): Promise<T | null> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };

    const response = await fetch(url, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    switch (response.status) {
      case 200:
      case 201:
        return (await response.json()) as T;
      case 204:
        return {} as T;
      case 400: {
        const err = await response.json();
        throw new Error("Invalid request", { cause: err });
      }
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 403:
        throw new Error("Access denied - insufficient permissions");
      case 404:
        return null;
      case 429:
        throw new Error("Rate limit exceeded - too many requests");
      default:
        if (response.status >= 500) {
          throw new Error(`Server error: ${response.status}`);
        }
        throw new Error(await response.text());
    }
  }

  // ---- User ----

  async getMe(): Promise<TeamsUser> {
    const data = await this.call<TeamsUser>("GET", `${this.baseUrl}/me`);
    if (!data) throw new Error("Failed to get user profile");
    return data;
  }

  // ---- Teams & Channels ----

  async getJoinedTeams(): Promise<Team[]> {
    const data = await this.call<PaginatedResponse<Team>>(
      "GET",
      `${this.baseUrl}/me/joinedTeams`
    );
    return data?.value ?? [];
  }

  async getChannels(teamId: string): Promise<TeamsChannel[]> {
    const data = await this.call<PaginatedResponse<TeamsChannel>>(
      "GET",
      `${this.baseUrl}/teams/${teamId}/channels`
    );
    return data?.value ?? [];
  }

  // ---- Channel Messages ----

  async getChannelMessages(
    teamId: string,
    channelId: string,
    params?: { top?: number; skipToken?: string }
  ): Promise<PaginatedResponse<TeamsMessage>> {
    let url = `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages?$top=${params?.top ?? 50}`;
    if (params?.skipToken) {
      url = params.skipToken; // skipToken is a full URL from @odata.nextLink
    }
    const data = await this.call<PaginatedResponse<TeamsMessage>>("GET", url);
    return data ?? { value: [] };
  }

  async getMessageReplies(
    teamId: string,
    channelId: string,
    messageId: string
  ): Promise<TeamsMessage[]> {
    const data = await this.call<PaginatedResponse<TeamsMessage>>(
      "GET",
      `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages/${messageId}/replies`
    );
    return data?.value ?? [];
  }

  async sendChannelReply(
    teamId: string,
    channelId: string,
    messageId: string,
    content: string
  ): Promise<TeamsMessage | null> {
    return this.call<TeamsMessage>(
      "POST",
      `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages/${messageId}/replies`,
      { body: { contentType: "html", content } }
    );
  }

  // ---- Chats (DMs) ----

  async getChats(): Promise<Chat[]> {
    const data = await this.call<PaginatedResponse<Chat>>(
      "GET",
      `${this.baseUrl}/me/chats?$filter=chatType eq 'oneOnOne' or chatType eq 'group'&$expand=members`
    );
    return data?.value ?? [];
  }

  async getChatMessages(
    chatId: string,
    params?: { top?: number; skipToken?: string }
  ): Promise<PaginatedResponse<TeamsMessage>> {
    let url = `${this.baseUrl}/chats/${chatId}/messages?$top=${params?.top ?? 50}`;
    if (params?.skipToken) {
      url = params.skipToken;
    }
    const data = await this.call<PaginatedResponse<TeamsMessage>>("GET", url);
    return data ?? { value: [] };
  }

  async sendChatMessage(
    chatId: string,
    content: string
  ): Promise<TeamsMessage | null> {
    return this.call<TeamsMessage>(
      "POST",
      `${this.baseUrl}/chats/${chatId}/messages`,
      { body: { contentType: "html", content } }
    );
  }

  async getChatMembers(chatId: string): Promise<ChatMember[]> {
    const data = await this.call<PaginatedResponse<ChatMember>>(
      "GET",
      `${this.baseUrl}/chats/${chatId}/members`
    );
    return data?.value ?? [];
  }

  // ---- Subscriptions ----

  async createSubscription(
    resource: string,
    notificationUrl: string,
    changeType: string,
    expirationMinutes: number
  ): Promise<Subscription> {
    const expirationDateTime = new Date(
      Date.now() + expirationMinutes * 60 * 1000
    );
    const data = await this.call<Subscription>(
      "POST",
      `${this.baseUrl}/subscriptions`,
      {
        changeType,
        notificationUrl,
        resource,
        expirationDateTime: expirationDateTime.toISOString(),
        clientState: crypto.randomUUID(),
      }
    );
    if (!data) throw new Error("Failed to create subscription");
    return data;
  }

  async renewSubscription(
    subscriptionId: string,
    expirationMinutes: number
  ): Promise<Subscription> {
    const expirationDateTime = new Date(
      Date.now() + expirationMinutes * 60 * 1000
    );
    const data = await this.call<Subscription>(
      "PATCH",
      `${this.baseUrl}/subscriptions/${subscriptionId}`,
      { expirationDateTime: expirationDateTime.toISOString() }
    );
    if (!data) throw new Error("Failed to renew subscription");
    return data;
  }

  async deleteSubscription(subscriptionId: string): Promise<void> {
    await this.call<void>(
      "DELETE",
      `${this.baseUrl}/subscriptions/${subscriptionId}`
    );
  }
}

// ---- Transform functions ----

/**
 * Converts a Teams user reference to a NewActor for Plot.
 * Uses Microsoft provider source for identity resolution.
 */
function userToNewActor(user?: TeamsUser): NewActor | undefined {
  if (!user) return undefined;
  return {
    name: user.displayName ?? user.id,
    email: user.mail ?? undefined,
    source: { provider: AuthProvider.Microsoft, accountId: user.id },
  };
}

/**
 * Extracts @mentions from a Teams message as NewActor[].
 */
function extractMentions(message: TeamsMessage): NewActor[] {
  if (!message.mentions) return [];
  return message.mentions
    .filter((m) => m.mentioned.user)
    .map((m) => ({
      name: m.mentionText,
      source: m.mentioned.user?.id
        ? { provider: AuthProvider.Microsoft, accountId: m.mentioned.user.id }
        : undefined,
    }));
}

/**
 * Strips HTML tags to produce a plain-text snippet for titles/previews.
 */
function stripHtml(html: string): string {
  return html
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Transforms a Teams channel message thread (parent + replies) into a
 * NewLinkWithNotes structure for saving via integrations.saveLink().
 */
export function transformChannelThread(
  parentMessage: TeamsMessage,
  replies: TeamsMessage[],
  teamId: string,
  channelId: string,
  initialSync: boolean
): NewLinkWithNotes {
  const title =
    stripHtml(parentMessage.body.content).substring(0, 50) ||
    "Teams message";

  const allMessages = [parentMessage, ...replies];

  return {
    source: `ms-teams:channel:${channelId}:message:${parentMessage.id}`,
    type: "message",
    title,
    created: new Date(parentMessage.createdDateTime),
    author: userToNewActor(parentMessage.from?.user),
    preview: stripHtml(parentMessage.body.content) || null,
    meta: {
      teamId,
      channelId,
      messageId: parentMessage.id,
    },
    notes: allMessages
      .filter((msg) => msg.messageType === "message")
      .map((msg) => ({
        key: msg.id,
        author: userToNewActor(msg.from?.user),
        content: msg.body.content,
        contentType: msg.body.contentType === "html" ? ("html" as const) : ("text" as const),
        created: new Date(msg.createdDateTime),
        mentions: extractMentions(msg),
      })),
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}

/**
 * Transforms a Teams DM chat into a NewLinkWithNotes structure.
 * DMs are private threads with all participants as mentions for visibility.
 */
export function transformDmThread(
  messages: TeamsMessage[],
  chatId: string,
  members: NewActor[],
  initialSync: boolean
): NewLinkWithNotes {
  const firstMessage = messages[0];
  if (!firstMessage) {
    return {
      source: `ms-teams:dm:${chatId}`,
      type: "message",
      title: "Empty chat",
      private: true,
      notes: [],
    };
  }

  const title =
    stripHtml(firstMessage.body.content).substring(0, 50) || "Teams chat";

  return {
    source: `ms-teams:dm:${chatId}`,
    type: "message",
    title,
    private: true,
    created: new Date(firstMessage.createdDateTime),
    author: userToNewActor(firstMessage.from?.user),
    preview: stripHtml(firstMessage.body.content) || null,
    meta: {
      chatId,
    },
    notes: messages
      .filter((msg) => msg.messageType === "message")
      .map((msg) => ({
        key: msg.id,
        author: userToNewActor(msg.from?.user),
        content: msg.body.content,
        contentType: msg.body.contentType === "html" ? ("html" as const) : ("text" as const),
        created: new Date(msg.createdDateTime),
        mentions: members, // All participants for private thread visibility
      })),
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}

/**
 * Fetches channel messages with pagination and groups them into threads
 * (parent message + replies).
 */
export async function syncChannelMessages(
  api: GraphApi,
  teamId: string,
  state: SyncState
): Promise<{
  threads: Array<{ parent: TeamsMessage; replies: TeamsMessage[] }>;
  state: SyncState;
}> {
  const result = await api.getChannelMessages(teamId, state.channelId, {
    top: 50,
    skipToken: state.cursor,
  });

  const threads: Array<{ parent: TeamsMessage; replies: TeamsMessage[] }> = [];

  for (const message of result.value) {
    // Skip system messages
    if (message.messageType !== "message") continue;

    // Filter by oldest timestamp if set
    if (
      state.oldest &&
      new Date(message.createdDateTime) < new Date(state.oldest)
    ) {
      continue;
    }

    // Fetch replies for this message
    const replies = await api.getMessageReplies(
      teamId,
      state.channelId,
      message.id
    );

    threads.push({ parent: message, replies });
  }

  const nextLink = result["@odata.nextLink"];

  return {
    threads,
    state: {
      channelId: state.channelId,
      cursor: nextLink,
      more: !!nextLink,
      oldest: state.oldest,
      initialSync: state.initialSync,
    },
  };
}
```

- [ ] **Step 2: Verify types compile**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm exec tsc --noEmit`
Expected: Error about missing `ms-teams.ts` (index.ts imports it) — that's OK for now.

- [ ] **Step 3: Commit**

```bash
git add public/connectors/ms-teams/src/graph-api.ts
git commit -m "feat(ms-teams): add Graph API client and transform functions"
```

---

### Task 3: Connector Class — Channel Discovery & Auth

**Files:**
- Create: `public/connectors/ms-teams/src/ms-teams.ts`

- [ ] **Step 1: Create ms-teams.ts with class definition, build, getChannels, getAccountName**

```typescript
import {
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import type { Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  GraphApi,
  type SyncState,
  type TeamsMessage,
  syncChannelMessages,
  transformChannelThread,
  transformDmThread,
} from "./graph-api";

const DM_CHANNEL_ID = "__direct_messages__";
const MAX_SYNC_BATCHES = 50;
/** Graph subscriptions for Teams channel messages max out at ~60 minutes. */
const SUBSCRIPTION_EXPIRY_MINUTES = 55;

export class MsTeams extends Connector<MsTeams> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://graph.microsoft.com/Team.ReadBasic.All",
    "https://graph.microsoft.com/Channel.ReadBasic.All",
    "https://graph.microsoft.com/ChannelMessage.Read.All",
    "https://graph.microsoft.com/ChannelMessage.Send",
    "https://graph.microsoft.com/Chat.Read",
    "https://graph.microsoft.com/ChatMessage.Send",
    "https://graph.microsoft.com/User.Read",
  ];

  readonly provider = AuthProvider.Microsoft;
  readonly scopes = MsTeams.SCOPES;
  readonly linkTypes = [
    {
      type: "message",
      label: "Message",
      logo: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoDark: "https://api.iconify.design/logos/microsoft-teams.svg",
      logoMono: "https://api.iconify.design/simple-icons/microsoftteams.svg",
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

  async getAccountName(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<string | null> {
    if (!token) return null;
    try {
      const api = new GraphApi(token.token);
      const me = await api.getMe();
      return me.displayName ?? null;
    } catch {
      return null;
    }
  }

  private async getApi(channelId: string): Promise<GraphApi> {
    const lookupId = channelId === DM_CHANNEL_ID ? DM_CHANNEL_ID : channelId;
    const token = await this.tools.integrations.get(lookupId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
    }
    return new GraphApi(token.token);
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    const api = new GraphApi(token.token);

    const channels: Channel[] = [];

    // Get teams and their channels as a tree
    const teams = await api.getJoinedTeams();
    for (const team of teams) {
      const teamChannels = await api.getChannels(team.id);
      channels.push({
        id: team.id,
        title: team.displayName,
        children: teamChannels.map((ch) => ({
          id: ch.id,
          title: ch.displayName,
        })),
      });
    }

    // Synthetic DM channel
    channels.push({
      id: DM_CHANNEL_ID,
      title: "Direct Messages",
    });

    return channels;
  }

  // ---- Channel lifecycle (stubs for now, implemented in next tasks) ----

  async onChannelEnabled(channel: Channel): Promise<void> {
    // Implemented in Task 4
    throw new Error("Not implemented");
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    // Implemented in Task 6
    throw new Error("Not implemented");
  }
}

export default MsTeams;
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm build`
Expected: Compiles successfully (with warnings about unused imports that will be used in later tasks)

- [ ] **Step 3: Commit**

```bash
git add public/connectors/ms-teams/src/ms-teams.ts
git commit -m "feat(ms-teams): add connector class with channel discovery"
```

---

### Task 4: Channel Message Sync

**Files:**
- Modify: `public/connectors/ms-teams/src/ms-teams.ts`

Implement `onChannelEnabled` for channel messages (not DMs yet), batch sync, and webhook setup.

- [ ] **Step 1: Replace `onChannelEnabled` stub and add channel sync methods**

In `ms-teams.ts`, replace the `onChannelEnabled` stub and add the following methods after `getChannels`:

```typescript
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    if (channel.id === DM_CHANNEL_ID) {
      // DM sync — implemented in Task 5
      const syncCallback = await this.callback(this.syncDmSpaces, true);
      await this.runTask(syncCallback);
    } else {
      // Channel message sync
      const timeMin = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      const initialState: SyncState = {
        channelId: channel.id,
        oldest: timeMin.toISOString(),
        initialSync: true,
      };
      await this.set(`sync_state_${channel.id}`, initialState);

      const syncCallback = await this.callback(
        this.syncBatch,
        1,
        "full",
        channel.id,
        true
      );
      await this.runTask(syncCallback);

      // Queue webhook setup as a separate task
      const webhookCallback = await this.callback(
        this.setupChannelWebhook,
        channel.id
      );
      await this.runTask(webhookCallback);
    }
  }
```

- [ ] **Step 2: Add `findTeamForChannel` helper**

The Graph API requires `teamId` to fetch channel messages, but `onChannelEnabled` only receives a channel. The team ID is the parent in the `getChannels()` tree. Store the mapping during `onChannelEnabled`:

```typescript
  /**
   * Finds which team a channel belongs to by checking the stored mapping,
   * or by iterating joined teams if not cached.
   */
  private async findTeamForChannel(channelId: string): Promise<string | null> {
    // Check cached mapping
    const cached = await this.get<string>(`team_for_channel_${channelId}`);
    if (cached) return cached;

    // Resolve by listing teams and their channels
    const token = await this.tools.integrations.get(channelId);
    if (!token) return null;
    const api = new GraphApi(token.token);
    const teams = await api.getJoinedTeams();
    for (const team of teams) {
      const channels = await api.getChannels(team.id);
      for (const ch of channels) {
        if (ch.id === channelId) {
          await this.set(`team_for_channel_${channelId}`, team.id);
          return team.id;
        }
      }
    }
    return null;
  }
```

Also add a line in `onChannelEnabled` before the sync to cache the team mapping. The channel tree from `getChannels` has team as parent, but we need to map channel→team. Add this approach: in `getChannels`, store the mapping for each channel child. Actually, simpler: store the mapping in `onChannelEnabled`.

Update `onChannelEnabled` to resolve and cache the team ID before syncing:

```typescript
      // After setting sync state, resolve team ID
      const teamId = await this.findTeamForChannel(channel.id);
      if (!teamId) {
        console.error(`Could not find team for channel ${channel.id}`);
        return;
      }
      await this.set(`team_for_channel_${channel.id}`, teamId);
```

- [ ] **Step 3: Add batch sync method**

```typescript
  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    initialSync?: boolean
  ): Promise<void> {
    if (batchNumber > MAX_SYNC_BATCHES) {
      console.warn(`Sync batch limit reached for channel ${channelId}`);
      return;
    }
    const isInitial = initialSync ?? mode === "full";

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) throw new Error("No sync state found");

      const teamId = await this.get<string>(`team_for_channel_${channelId}`);
      if (!teamId) throw new Error("No team ID found for channel");

      const api = await this.getApi(channelId);
      const result = await syncChannelMessages(api, teamId, state);

      for (const { parent, replies } of result.threads) {
        try {
          // Filter out messages we sent (dedup)
          const sentKey = `sent:${parent.id}`;
          const wasSent = await this.get<boolean>(sentKey);
          if (wasSent) {
            await this.clear(sentKey);
            continue;
          }

          const link = transformChannelThread(
            parent,
            replies,
            teamId,
            channelId,
            isInitial
          );

          link.channelId = channelId;
          link.meta = {
            ...link.meta,
            syncProvider: "teams",
            syncableId: channelId,
          };

          await this.tools.integrations.saveLink(link);
        } catch (error) {
          console.error("Failed to process Teams thread:", error);
        }
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.state.more) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          channelId,
          isInitial
        );
        await this.runTask(syncCallback);
      } else if (mode === "full") {
        await this.clear(`sync_state_${channelId}`);
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );
      throw error;
    }
  }
```

- [ ] **Step 4: Add webhook setup and handler**

```typescript
  async setupChannelWebhook(channelId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onTeamsWebhook,
        channelId
      );

      // Localhost guard
      if (URL.parse(webhookUrl)?.hostname === "localhost") {
        return;
      }

      const teamId = await this.get<string>(`team_for_channel_${channelId}`);
      if (!teamId) {
        console.error("No team ID found for webhook setup");
        return;
      }

      const api = await this.getApi(channelId);
      const resource = `/teams/${teamId}/channels/${channelId}/messages`;
      const subscription = await api.createSubscription(
        resource,
        webhookUrl,
        "created,updated",
        SUBSCRIPTION_EXPIRY_MINUTES
      );

      await this.set(`subscription_${channelId}`, {
        id: subscription.id,
        expiry: subscription.expirationDateTime,
        webhookUrl,
      });

      // Schedule renewal before expiry
      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error("Failed to setup Teams webhook:", error);
    }
  }

  async onTeamsWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    // Handle Graph subscription validation handshake
    const validationToken = request.params?.validationToken;
    if (validationToken) {
      // The webhook infrastructure returns the validation token
      return;
    }

    const body = request.body as {
      value?: Array<{
        changeType: string;
        resource: string;
        clientState?: string;
      }>;
    };

    if (!body?.value?.length) return;

    // Trigger incremental sync for this channel
    await this.startIncrementalSync(channelId);
  }

  private async startIncrementalSync(channelId: string): Promise<void> {
    const incrementalState: SyncState = {
      channelId,
      oldest: new Date(Date.now() - 60 * 60 * 1000).toISOString(), // Last hour
      initialSync: false,
    };
    await this.set(`sync_state_${channelId}`, incrementalState);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      channelId,
      false
    );
    await this.runTask(syncCallback);
  }

  // ---- Subscription renewal ----

  private async scheduleSubscriptionRenewal(
    channelId: string
  ): Promise<void> {
    const subData = await this.get<{ expiry: string }>(
      `subscription_${channelId}`
    );
    if (!subData?.expiry) return;

    const expiry = new Date(subData.expiry);
    // Renew 5 minutes before expiry
    const renewalTime = new Date(expiry.getTime() - 5 * 60 * 1000);

    if (renewalTime <= new Date()) {
      await this.renewSubscription(channelId);
      return;
    }

    const renewalCallback = await this.callback(
      this.renewSubscription,
      channelId
    );
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set(`renewal_task_${channelId}`, taskToken);
    }
  }

  async renewSubscription(channelId: string): Promise<void> {
    try {
      const subData = await this.get<{
        id: string;
        expiry: string;
        webhookUrl: string;
      }>(`subscription_${channelId}`);

      if (!subData?.id) {
        // No subscription, recreate
        await this.setupChannelWebhook(channelId);
        return;
      }

      const api = await this.getApi(channelId);
      const renewed = await api.renewSubscription(
        subData.id,
        SUBSCRIPTION_EXPIRY_MINUTES
      );

      await this.set(`subscription_${channelId}`, {
        ...subData,
        expiry: renewed.expirationDateTime,
      });

      await this.scheduleSubscriptionRenewal(channelId);
    } catch (error) {
      console.error(`Failed to renew subscription for ${channelId}:`, error);
      // Try recreating from scratch
      try {
        await this.setupChannelWebhook(channelId);
      } catch (retryError) {
        console.error("Failed to recreate subscription:", retryError);
      }
    }
  }
```

- [ ] **Step 5: Add placeholder methods referenced by onChannelEnabled (DM sync, implemented in Task 5)**

```typescript
  // ---- DM sync (placeholder — implemented in Task 5) ----

  async syncDmSpaces(initialSync?: boolean): Promise<void> {
    throw new Error("Not implemented — Task 5");
  }
```

- [ ] **Step 6: Build to verify**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm build`
Expected: Compiles successfully

- [ ] **Step 7: Commit**

```bash
git add public/connectors/ms-teams/src/ms-teams.ts
git commit -m "feat(ms-teams): implement channel message sync with webhooks"
```

---

### Task 5: DM Sync

**Files:**
- Modify: `public/connectors/ms-teams/src/ms-teams.ts`

Replace the DM sync placeholder with the full implementation, following the Google Chat pattern.

- [ ] **Step 1: Replace `syncDmSpaces` placeholder with full implementation**

```typescript
  async syncDmSpaces(initialSync?: boolean): Promise<void> {
    const isInitial = initialSync ?? true;

    try {
      const api = await this.getApi(DM_CHANNEL_ID);
      const chats = await api.getChats();

      for (const chat of chats) {
        const dmState: SyncState = {
          channelId: chat.id,
          initialSync: isInitial,
        };
        await this.set(`sync_state_dm_${chat.id}`, dmState);

        const syncCallback = await this.callback(
          this.syncDmBatch,
          1,
          chat.id,
          isInitial
        );
        await this.runTask(syncCallback);
      }
    } catch (error) {
      console.error("Failed to sync DM spaces:", error);
      throw error;
    }
  }

  async syncDmBatch(
    batchNumber: number,
    chatId: string,
    initialSync?: boolean
  ): Promise<void> {
    if (batchNumber > MAX_SYNC_BATCHES) {
      console.warn(`DM sync batch limit reached for ${chatId}`);
      return;
    }
    const isInitial = initialSync ?? true;

    try {
      const api = await this.getApi(DM_CHANNEL_ID);

      // Fetch messages
      const state = await this.get<SyncState>(`sync_state_dm_${chatId}`);
      if (!state) throw new Error("No sync state found for DM");

      const result = await api.getChatMessages(chatId, {
        top: 50,
        skipToken: state.cursor,
      });

      const messages = result.value.filter(
        (msg) => msg.messageType === "message"
      );

      if (messages.length > 0) {
        // Get chat members for private thread visibility
        const memberData = await this.getChatMembersAsActors(api, chatId);

        // Filter out messages we sent (dedup)
        const filtered: TeamsMessage[] = [];
        for (const msg of messages) {
          const wasSent = await this.get<boolean>(`sent:${msg.id}`);
          if (wasSent) {
            await this.clear(`sent:${msg.id}`);
            continue;
          }
          filtered.push(msg);
        }

        if (filtered.length > 0) {
          const link = transformDmThread(
            filtered,
            chatId,
            memberData,
            isInitial
          );

          link.channelId = DM_CHANNEL_ID;
          link.meta = {
            ...link.meta,
            syncProvider: "teams",
            syncableId: DM_CHANNEL_ID,
          };

          await this.tools.integrations.saveLink(link);
        }
      }

      const nextLink = result["@odata.nextLink"];
      const newState: SyncState = {
        channelId: chatId,
        cursor: nextLink,
        more: !!nextLink,
        initialSync: isInitial,
      };
      await this.set(`sync_state_dm_${chatId}`, newState);

      if (nextLink) {
        const syncCallback = await this.callback(
          this.syncDmBatch,
          batchNumber + 1,
          chatId,
          isInitial
        );
        await this.runTask(syncCallback);
      } else {
        await this.clear(`sync_state_dm_${chatId}`);
      }
    } catch (error) {
      console.error(
        `Error in DM sync batch ${batchNumber} for ${chatId}:`,
        error
      );
      throw error;
    }
  }

  /**
   * Fetches and caches chat members as NewActor[] for private thread mentions.
   */
  private async getChatMembersAsActors(
    api: GraphApi,
    chatId: string
  ): Promise<NewActor[]> {
    const cached = await this.get<NewActor[]>(`chat_members_${chatId}`);
    if (cached) return cached;

    try {
      const members = await api.getChatMembers(chatId);
      const actors: NewActor[] = members
        .filter((m) => m.userId)
        .map((m) => ({
          name: m.displayName ?? m.userId!,
          email: m.email ?? undefined,
          source: {
            provider: AuthProvider.Microsoft,
            accountId: m.userId!,
          },
        }));

      await this.set(`chat_members_${chatId}`, actors);
      return actors;
    } catch (error) {
      console.error("Failed to fetch chat members:", error);
      return [];
    }
  }
```

- [ ] **Step 2: Add the `NewActor` import**

At the top of `ms-teams.ts`, update the import from `@plotday/twister/plot`:

```typescript
import type { NewActor, Note, Thread } from "@plotday/twister/plot";
```

- [ ] **Step 3: Build to verify**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm build`
Expected: Compiles successfully

- [ ] **Step 4: Commit**

```bash
git add public/connectors/ms-teams/src/ms-teams.ts
git commit -m "feat(ms-teams): implement DM sync with private threads"
```

---

### Task 6: Write-Back & Cleanup

**Files:**
- Modify: `public/connectors/ms-teams/src/ms-teams.ts`

Implement `onNoteCreated` (replies from Plot → Teams) and `onChannelDisabled` (cleanup).

- [ ] **Step 1: Replace `onChannelDisabled` stub**

```typescript
  async onChannelDisabled(channel: Channel): Promise<void> {
    if (channel.id === DM_CHANNEL_ID) {
      // DM channel — no subscriptions to clean up
      await this.clear(`sync_enabled_${channel.id}`);
      return;
    }

    // Cancel subscription renewal task
    const taskToken = await this.get<string>(
      `renewal_task_${channel.id}`
    );
    if (taskToken) {
      try {
        await this.cancelTask(taskToken);
      } catch {
        // Task may already have executed
      }
      await this.clear(`renewal_task_${channel.id}`);
    }

    // Delete Graph subscription
    const subData = await this.get<{
      id: string;
      webhookUrl: string;
    }>(`subscription_${channel.id}`);
    if (subData) {
      try {
        const api = await this.getApi(channel.id);
        await api.deleteSubscription(subData.id);
      } catch (error) {
        console.error("Failed to delete Teams subscription:", error);
      }

      if (subData.webhookUrl) {
        try {
          await this.tools.network.deleteWebhook(subData.webhookUrl);
        } catch (error) {
          console.error("Failed to delete webhook:", error);
        }
      }

      await this.clear(`subscription_${channel.id}`);
    }

    // Clear state
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`team_for_channel_${channel.id}`);
  }
```

- [ ] **Step 2: Add `onNoteCreated` for write-back**

```typescript
  async onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
    const meta = thread.meta ?? {};
    const syncableId = meta.syncableId as string;

    if (syncableId === DM_CHANNEL_ID) {
      // DM reply
      const chatId = meta.chatId as string;
      if (!chatId) {
        console.error("No chatId in meta for Teams DM reply");
        return;
      }

      const api = await this.getApi(DM_CHANNEL_ID);
      try {
        const result = await api.sendChatMessage(chatId, note.content ?? "");
        if (result?.id) {
          await this.set(`sent:${result.id}`, true);
          return result.id;
        }
      } catch (error) {
        console.error("Failed to send Teams DM reply:", error);
      }
    } else {
      // Channel reply
      const channelId = meta.channelId as string;
      const teamId = meta.teamId as string;
      const messageId = meta.messageId as string;

      if (!channelId || !teamId || !messageId) {
        console.error("Missing meta for Teams channel reply");
        return;
      }

      const api = await this.getApi(channelId);
      try {
        const result = await api.sendChannelReply(
          teamId,
          channelId,
          messageId,
          note.content ?? ""
        );
        if (result?.id) {
          await this.set(`sent:${result.id}`, true);
          return result.id;
        }
      } catch (error) {
        console.error("Failed to send Teams channel reply:", error);
      }
    }
  }
```

- [ ] **Step 3: Build to verify**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm build`
Expected: Compiles successfully with no errors

- [ ] **Step 4: Commit**

```bash
git add public/connectors/ms-teams/src/ms-teams.ts
git commit -m "feat(ms-teams): implement write-back and cleanup"
```

---

### Task 7: Website Update & Final Verification

**Files:**
- Modify: `apps/site/app/data/connections.ts:125`

- [ ] **Step 1: Set Teams connector as available**

In `apps/site/app/data/connections.ts`, change line 125:

```typescript
    available: true,
```

- [ ] **Step 2: Full build verification**

Run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm build`
Expected: Clean build with no errors

- [ ] **Step 3: Lint**

Run: `cd /Users/kris.braun/code/plot && pnpm lint --filter @plotday/connector-ms-teams`
Expected: No lint errors

If that filter doesn't work, run: `cd /Users/kris.braun/code/plot/public/connectors/ms-teams && pnpm lint`

- [ ] **Step 4: Commit**

```bash
git add apps/site/app/data/connections.ts
git commit -m "feat(ms-teams): enable Teams connector on website"
```

---

## Verification Checklist

After all tasks are complete:

1. `cd public/connectors/ms-teams && pnpm build` — clean compile
2. `pnpm lint` — no errors in the connector or site packages
3. Review `ms-teams.ts` end-to-end for:
   - `initialSync` flag flows correctly (true from `onChannelEnabled`, false from webhooks)
   - `syncProvider: "teams"` and `syncableId` injected in all `saveLink` calls
   - Localhost guard in `setupChannelWebhook`
   - All state keys cleaned up in `onChannelDisabled`
   - DM threads are `private: true` with member mentions
   - `sent:` dedup keys set in `onNoteCreated` and checked in sync
