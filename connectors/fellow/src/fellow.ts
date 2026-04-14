import { type NewLinkWithNotes } from "@plotday/twister";
import { Connector } from "@plotday/twister/connector";
import { Options } from "@plotday/twister/options";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Store } from "@plotday/twister/tools/store";
import {
  FellowAPI,
  type FellowNote,
  type FellowActionItem,
} from "./fellow-api";

type SyncState = {
  cursor: string | null;
  batchNumber: number;
  notesProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

/**
 * Fellow connector — syncs meeting notes and action items from Fellow.
 *
 * Uses API key auth via Options (no OAuth). Meeting notes are synced as links
 * with relatedSource set to the Google Calendar event ID, enabling
 * cross-connector thread bundling with the Google Calendar connector.
 */
export class Fellow extends Connector<Fellow> {
  // No provider or scopes — uses API key auth via Options

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        apiKey: {
          type: "text" as const,
          secure: true,
          label: "API key",
          default: "",
          placeholder: "your-fellow-api-key",
        },
        subdomain: {
          type: "text" as const,
          label: "Subdomain",
          default: "",
          placeholder: "yourcompany",
        },
      }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      store: build(Store),
      network: build(Network, { urls: ["https://*.fellow.app/*"] }),
    };
  }

  private getAPI(): FellowAPI {
    const opts = this.tools.options;
    return new FellowAPI(opts.apiKey as string, opts.subdomain as string);
  }

  /**
   * Returns a single channel for the Fellow workspace.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null,
  ): Promise<Channel[]> {
    // Verify credentials by fetching one note
    const api = this.getAPI();
    await api.listNotes({ pageSize: 1 });

    return [
      {
        id: "meeting-notes",
        title: "Meeting Notes",
        linkTypes: [
          {
            type: "meeting",
            label: "Meeting",
            logo: "/assets/logo-fellow.svg",
          },
        ],
      },
    ];
  }

  /**
   * Start syncing meeting notes for the enabled channel.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue webhook setup as a separate task to avoid blocking the HTTP response
    const webhookCallback = await this.callback(
      this.setupWebhook,
      channel.id
    );
    await this.runTask(webhookCallback);

    await this.startBatchSync(channel.id, syncHistoryMin);
  }

  /**
   * Clean up state when channel is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
      meta: { syncProvider: "fellow", channelId: channel.id },
    });
  }

  async setupWebhook(channelId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        channelId,
      );

      // Skip webhook registration in development
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      const api = this.getAPI();
      const webhook = await api.createWebhook(webhookUrl, [
        "ai_note.generated",
        "ai_note.shared_to_channel",
        "action_item.assigned",
        "action_item.completed",
      ]);

      if (webhook?.id) {
        await this.set(`webhook_id_${channelId}`, webhook.id);
        await this.set(`webhook_secret_${channelId}`, webhook.secret);
      }
    } catch (error) {
      console.error("Failed to set up Fellow webhook:", error);
    }
  }

  private async startBatchSync(channelId: string, syncHistoryMin?: Date): Promise<void> {
    await this.set(`sync_state_${channelId}`, {
      cursor: null,
      batchNumber: 1,
      notesProcessed: 0,
      initialSync: true,
      ...(syncHistoryMin ? { syncHistoryMin: syncHistoryMin.toISOString() } : {}),
    } satisfies SyncState);

    const batchCallback = await this.callback(
      this.syncBatch,
      channelId,
      true,
    );
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Fetches a batch of notes and saves them as meeting threads.
   */
  async syncBatch(channelId: string, initialSync?: boolean): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${channelId}`);
    if (!state) return;

    const isInitial = initialSync ?? state.initialSync;
    const api = this.getAPI();
    const result = await api.listNotes({
      cursor: state.cursor ?? undefined,
      updatedAtStart: state.syncHistoryMin ?? undefined,
    });

    for (const note of result.data) {
      // Fetch action items for this note
      let actionItems: FellowActionItem[] = [];
      try {
        const aiResult = await api.listActionItems();
        actionItems = aiResult.data.filter((ai) => ai.note_id === note.id);
      } catch {
        // Action items are supplementary; don't fail the sync
      }

      const link = this.transformNote(note, actionItems, channelId, isInitial);
      await this.tools.integrations.saveLink(link);
    }

    // Continue to next batch or finish
    if (result.nextCursor) {
      await this.set(`sync_state_${channelId}`, {
        cursor: result.nextCursor,
        batchNumber: state.batchNumber + 1,
        notesProcessed: state.notesProcessed + result.data.length,
        initialSync: isInitial,
      } satisfies SyncState);

      const nextBatch = await this.callback(
        this.syncBatch,
        channelId,
        isInitial,
      );
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Sync complete
      await this.clear(`sync_state_${channelId}`);
    }
  }

  /**
   * Transform a Fellow note + its action items into a Plot link with notes.
   */
  private transformNote(
    note: FellowNote,
    actionItems: FellowActionItem[],
    channelId: string,
    initialSync: boolean,
  ): NewLinkWithNotes {
    const notes: any[] = [];

    // Meeting notes content
    if (note.content_markdown) {
      notes.push({
        key: "notes",
        content: note.content_markdown,
        contentType: "markdown" as const,
        created: note.updated_at ? new Date(note.updated_at) : undefined,
      });
    }

    // Action items as individual notes
    for (const item of actionItems) {
      const statusPrefix =
        item.status === "Done"
          ? "[x]"
          : item.status === "Archived"
            ? "[-]"
            : "[ ]";
      const assigneeText =
        item.assignees.length > 0
          ? ` (${item.assignees.map((a) => a.full_name).join(", ")})`
          : "";
      const dueText = item.due_date ? ` — due ${item.due_date}` : "";

      notes.push({
        key: `action-item-${item.id}`,
        content: `${statusPrefix} ${item.text}${assigneeText}${dueText}`,
        contentType: "markdown" as const,
      });
    }

    const subdomain = this.tools.options.subdomain as string;

    return {
      source: `fellow:note:${note.id}`,
      // Cross-connector thread bundling: join existing calendar thread
      ...(note.event_guid
        ? { relatedSource: `google-calendar:${note.event_guid}` }
        : {}),
      title: note.title || "Meeting Notes",
      type: "meeting",
      channelId,
      sourceUrl: `https://${subdomain}.fellow.app/notes/${note.id}`,
      created: note.event_start
        ? new Date(note.event_start)
        : note.created_at
          ? new Date(note.created_at)
          : undefined,
      meta: {
        syncProvider: "fellow",
        channelId,
        noteId: note.id,
        ...(note.event_guid ? { eventGuid: note.event_guid } : {}),
      },
      notes,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Handle incoming webhooks from Fellow.
   */
  private async onWebhook(
    _request: WebhookRequest,
    channelId: string,
  ): Promise<void> {
    const enabled = await this.get<boolean>(`sync_enabled_${channelId}`);
    if (!enabled) return;

    // Parse the webhook payload and do an incremental sync
    // Fellow webhooks signal that new data is available; re-sync recent notes
    const api = this.getAPI();
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const result = await api.listNotes({ updatedAtStart: oneHourAgo });

    for (const note of result.data) {
      let actionItems: FellowActionItem[] = [];
      try {
        const aiResult = await api.listActionItems();
        actionItems = aiResult.data.filter((ai) => ai.note_id === note.id);
      } catch {
        // Non-critical
      }

      const link = this.transformNote(note, actionItems, channelId, false);
      await this.tools.integrations.saveLink(link);
    }
  }
}

export default Fellow;
