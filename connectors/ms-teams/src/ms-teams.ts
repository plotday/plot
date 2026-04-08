import {
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import type { NewActor, Note, Thread } from "@plotday/twister/plot";
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
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
    }
    return new GraphApi(token.token);
  }

  // ---- Channel discovery ----

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

  // ---- Channel lifecycle ----

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    if (channel.id === DM_CHANNEL_ID) {
      const syncCallback = await this.callback(this.syncDmSpaces, true);
      await this.runTask(syncCallback);
    } else {
      // Resolve and cache team ID for this channel
      const teamId = await this.findTeamForChannel(channel.id);
      if (!teamId) {
        console.error(`Could not find team for channel ${channel.id}`);
        return;
      }
      await this.set(`team_for_channel_${channel.id}`, teamId);

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

  async onChannelDisabled(channel: Channel): Promise<void> {
    if (channel.id === DM_CHANNEL_ID) {
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

  // ---- Team resolution ----

  private async findTeamForChannel(channelId: string): Promise<string | null> {
    const cached = await this.get<string>(`team_for_channel_${channelId}`);
    if (cached) return cached;

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

  // ---- Channel message batch sync ----

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

  // ---- Webhook setup & handler ----

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
      oldest: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
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
      try {
        await this.setupChannelWebhook(channelId);
      } catch (retryError) {
        console.error("Failed to recreate subscription:", retryError);
      }
    }
  }

  // ---- DM sync ----

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

  // ---- Write-back: reply from Plot ----

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
}

export default MsTeams;
