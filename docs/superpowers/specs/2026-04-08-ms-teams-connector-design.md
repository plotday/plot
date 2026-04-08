# Microsoft Teams Connector Design

## Context

Plot lists Microsoft Teams as a forthcoming connector (`available: false` in `apps/site/app/data/connections.ts`). Users need Teams messages synced into Plot priorities with two-way reply support, including both channel messages and DMs. This follows the established connector patterns used by Slack and Google Chat.

## Scope

- Two-way message sync for Teams channels and DMs
- Independent Microsoft OAuth (not shared with Outlook Calendar)
- Channel messages: batch sync + real-time via Graph subscriptions
- DMs: batch sync only (single synthetic channel, private threads)
- Write-back: replies from Plot posted back to Teams

## Package Structure

```
public/connectors/ms-teams/
  src/
    index.ts              # export { default, MsTeams } from "./ms-teams"
    ms-teams.ts           # Main connector class
    graph-api.ts          # Microsoft Graph API client for Teams endpoints
  package.json            # @plotday/connector-ms-teams
  tsconfig.json
```

**package.json** follows the pattern in `public/connectors/outlook-calendar/package.json`:
- `name`: `@plotday/connector-ms-teams`
- `displayName`: `Microsoft Teams`
- Depends on `@plotday/twister: "workspace:^"`
- Extends `@plotday/twister/tsconfig.base.json`

## Authentication

- **Provider**: `AuthProvider.Microsoft`
- **Scopes**:
  - `https://graph.microsoft.com/Team.ReadBasic.All` — list joined teams
  - `https://graph.microsoft.com/Channel.ReadBasic.All` — list channels in teams
  - `https://graph.microsoft.com/ChannelMessage.Read.All` — read channel messages
  - `https://graph.microsoft.com/ChannelMessage.Send` — post replies to channels
  - `https://graph.microsoft.com/Chat.Read` — read 1:1 and group chats
  - `https://graph.microsoft.com/ChatMessage.Send` — post replies to chats
  - `https://graph.microsoft.com/User.Read` — get account display name
- Token refresh is handled by the Integrations tool (connectors don't manage refresh directly)

## Class Definition

```typescript
export class MsTeams extends Connector<MsTeams> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly SCOPES = [/* scopes above */];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Microsoft;
  readonly scopes = MsTeams.SCOPES;
  readonly linkTypes = [{
    type: "message",
    label: "Message",
    logo: "https://api.iconify.design/logos/microsoft-teams.svg",
    logoDark: "https://api.iconify.design/logos/microsoft-teams.svg",
    logoMono: "https://api.iconify.design/simple-icons/microsoftteams.svg",
  }];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
    };
  }

  async getAccountName(_auth: Authorization | null, token: AuthToken | null): Promise<string | null> {
    if (!token) return null;
    const api = new GraphApi(token.token);
    const me = await api.getMe();
    return me.displayName ?? null;
  }
}
```

Per-user OAuth (default `shared: false`) — each user authenticates individually.

## Channel Model

`getChannels()` returns a tree structure:

```
Team A (parent, id: team-uuid)
  ├── General (child, id: channel-id)
  ├── Engineering (child, id: channel-id)
  └── Design (child, id: channel-id)
Team B (parent, id: team-uuid)
  ├── General
  └── Sales
Direct Messages (synthetic, id: "__direct_messages__")
```

**Graph API calls:**
1. `GET /me/joinedTeams` — list teams the user belongs to
2. `GET /teams/{team-id}/channels` — list channels per team
3. Each team becomes a parent `Channel` with its channels as `children`
4. Append a synthetic `{ id: "__direct_messages__", title: "Direct Messages" }` channel

## Sync: Channel Messages

### Initial Sync (onChannelEnabled)

1. Store `sync_enabled_{channelId}` state
2. Set initial sync state with `oldest` = 30 days ago
3. Queue batch sync via `this.runTask()` with `initialSync: true`
4. Queue webhook setup via separate `this.runTask()`

### Batch Sync

- `GET /teams/{teamId}/channels/{channelId}/messages` with `$top` pagination
- For each top-level message, fetch replies: `GET /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies`
- Transform to `NewLinkWithNotes` and save via `integrations.saveLink()`
- If more pages, queue next batch via `this.runTask()`

### Real-Time (Graph Subscriptions)

- Create subscription: `POST /subscriptions` with resource `/teams/{teamId}/channels/{channelId}/messages`
- `changeType: "created,updated"`
- `notificationUrl`: from `network.createWebhook({}, this.onTeamsWebhook, channelId)`
- Localhost guard: skip subscription creation if webhook URL is localhost
- **Subscription renewal**: Graph subscriptions for Teams channel messages have max ~60 min lifetime. Store subscription ID + expiry in state. Queue a renewal task that runs before expiry to create a new subscription.

### Webhook Handler

```typescript
async onTeamsWebhook(request: WebhookRequest, channelId: string): Promise<void> {
  // Handle validation handshake
  if (request.params.validationToken) {
    // Return validationToken as plain text (Graph subscription validation)
    return;
  }

  // Process change notifications
  const notifications = request.body?.value;
  if (notifications) {
    await this.startIncrementalSync(channelId);
  }
}
```

**Note on validation**: Microsoft Graph sends a validation request when creating a subscription. The webhook must respond with the `validationToken` query parameter as plain text. This needs to be handled in the webhook callback.

## Sync: Direct Messages

### Channel Enable (onChannelEnabled for `__direct_messages__`)

1. List all chats: `GET /me/chats` (filter for `oneOnOne` and `group` chat types)
2. For each chat, queue a batch sync task with `initialSync: true`

### DM Batch Sync

- `GET /chats/{chatId}/messages` with pagination
- Transform each conversation to `NewLinkWithNotes`:
  - `private: true`
  - `channelId: "__direct_messages__"`
  - All chat participants added as `mentions` for thread visibility
- Save via `integrations.saveLink()`
- No real-time webhooks (batch sync only, matching Google Chat pattern)

### DM Thread Key

```
source: "ms-teams:dm:{chatId}"
```

Using the chat ID as the stable identifier ensures idempotent upserts.

## Thread Transformation

### Channel Messages

```typescript
{
  source: `ms-teams:channel:{channelId}:message:{messageId}`,
  type: "message",
  title: stripHtml(message.body.content).substring(0, 50),
  private: false,
  created: new Date(message.createdDateTime),
  author: userToNewContact(message.from),
  channelId: channelId,
  meta: {
    syncProvider: "teams",
    syncableId: channelId,
    messageId: messageId,
    teamId: teamId,
  },
  notes: [
    // Parent message
    {
      key: messageId,
      content: message.body.content,
      contentType: message.body.contentType === "html" ? "html" : "text",
      created: new Date(message.createdDateTime),
      author: userToNewContact(message.from),
      mentions: extractMentions(message),
    },
    // ...replies mapped similarly with their own messageId as key
  ],
  ...(initialSync ? { unread: false, archived: false } : {}),
}
```

### DM Messages

Same structure but:
- `source: "ms-teams:dm:{chatId}"`
- `private: true`
- `channelId: "__direct_messages__"`
- `meta.chatId: chatId` (needed for write-back routing in `onNoteCreated`)
- `meta.syncableId: "__direct_messages__"` (for bulk archiving on disable)
- All chat members included as `mentions` on each note (for private thread visibility)

## Write-Back

### onNoteCreated (replies from Plot → Teams)

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
  const meta = thread.meta ?? {};
  const messageId = meta.messageId as string;
  const channelId = meta.syncableId as string;
  const teamId = meta.teamId as string;

  const api = await this.getApi(channelId);

  if (channelId === "__direct_messages__") {
    // DM reply: POST /chats/{chatId}/messages
    const chatId = meta.chatId as string;
    const result = await api.sendChatMessage(chatId, note.content ?? "");
    if (result?.id) await this.set(`sent:${result.id}`, true);
    return result?.id;
  } else {
    // Channel reply: POST /teams/{teamId}/channels/{channelId}/messages/{messageId}/replies
    const result = await api.sendChannelReply(teamId, channelId, messageId, note.content ?? "");
    if (result?.id) await this.set(`sent:${result.id}`, true);
    return result?.id;
  }
}
```

Sent message IDs are stored for dedup when the message syncs back.

## Graph API Client

`graph-api.ts` wraps Microsoft Graph REST API calls:

```typescript
class GraphApi {
  constructor(private accessToken: string) {}

  // Teams & Channels
  async getJoinedTeams(): Promise<Team[]>
  async getChannels(teamId: string): Promise<TeamsChannel[]>

  // Channel Messages
  async getChannelMessages(teamId: string, channelId: string, params?: { top?: number, skipToken?: string }): Promise<PaginatedResponse<TeamsMessage>>
  async getMessageReplies(teamId: string, channelId: string, messageId: string): Promise<TeamsMessage[]>
  async sendChannelReply(teamId: string, channelId: string, messageId: string, content: string): Promise<TeamsMessage>

  // Chats (DMs)
  async getChats(): Promise<Chat[]>
  async getChatMessages(chatId: string, params?: { top?: number, skipToken?: string }): Promise<PaginatedResponse<TeamsMessage>>
  async sendChatMessage(chatId: string, content: string): Promise<TeamsMessage>
  async getChatMembers(chatId: string): Promise<ChatMember[]>

  // Subscriptions
  async createSubscription(resource: string, notificationUrl: string, changeType: string, expirationMinutes: number): Promise<Subscription>
  async renewSubscription(subscriptionId: string, expirationMinutes: number): Promise<Subscription>
  async deleteSubscription(subscriptionId: string): Promise<void>

  // User
  async getMe(): Promise<User>

  // Generic caller with error handling
  private async call<T>(method: string, url: string, body?: unknown): Promise<T>
}
```

Error handling follows the Outlook Calendar pattern: handle 400, 401, 403, 404, 410, 429, 500+ status codes.

## State Management

Keys stored via `this.set()` / `this.get()`:

| Key | Value | Purpose |
|-----|-------|---------|
| `sync_enabled_{channelId}` | `boolean` | Track enabled channels |
| `sync_state_{channelId}` | `SyncState` | Pagination cursor, timestamps |
| `subscription_{channelId}` | `{ id, expiry }` | Graph subscription for renewal |
| `channel_webhook_{channelId}` | `{ url }` | Webhook URL for cleanup |
| `sent:{messageId}` | `true` | Dedup sent messages on sync-back |

## Cleanup (onChannelDisabled)

1. Delete Graph subscription if exists (`subscription_{channelId}`)
2. Delete webhook via `network.deleteWebhook(url)`
3. Clear all state keys for the channel
4. Clear callbacks via `this.callback.deleteAll()` (if last channel)

## Website Update

In `apps/site/app/data/connections.ts`, set `available: true` on the existing Microsoft Teams entry (line ~121).

## Verification

1. **Build**: `cd public/connectors/ms-teams && pnpm build` — compiles without errors
2. **Lint**: `pnpm lint` from repo root — no new lint errors
3. **Auth flow**: Start local API worker, trigger OAuth, verify token is stored
4. **Channel discovery**: After auth, verify `getChannels()` returns teams with nested channels + DM synthetic channel
5. **Initial sync**: Enable a channel, verify messages from last 30 days appear as threads in Plot
6. **DM sync**: Enable Direct Messages channel, verify DM conversations appear as private threads
7. **Write-back**: Reply to a synced thread in Plot, verify reply appears in Teams
8. **Webhook**: Send a message in Teams channel, verify it syncs to Plot (requires Cloudflare tunnel for non-localhost testing)
9. **Dedup**: Reply from Plot, verify the synced-back copy doesn't create a duplicate note
