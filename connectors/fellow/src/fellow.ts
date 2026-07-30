import { type Link, type NewContact, type NewLinkWithNotes } from "@plotday/twister";
import { Connector } from "@plotday/twister/connector";
import { Options } from "@plotday/twister/options";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
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
  type FellowAiNoteWebhook,
  type FellowActionItemAssignedWebhook,
  type FellowActionItemCompletedWebhook,
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

  readonly singleChannel = true;
  readonly access = [
    "Reads your meeting notes to attach them to the right events in Plot",
  ];

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
          helpText:
            "In Fellow, open User Settings → Developer tools, create a new API key, then paste it here. If you don't see Developer tools, an admin must first enable the API in Workspace Security Settings.",
          helpUrl: "https://help.fellow.ai/en/articles/11817206-developer-api",
        },
        subdomain: {
          type: "text" as const,
          label: "Subdomain",
          default: "",
          placeholder: "yourcompany",
          required: true,
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
    const apiKey = opts.apiKey as string | undefined;
    const subdomain = opts.subdomain as string | undefined;
    // `subdomain: { required: true }` blocks blank submission in the Flutter
    // form, but existing instances saved before that flag shipped — or any
    // caller that bypasses the form — can still reach here empty. Left
    // unchecked, FellowAPI builds `https://.fellow.app/...` — an invalid
    // hostname whose DNS failure workerd wraps as an opaque
    // "internal error; reference = <id>", indistinguishable from a genuine
    // platform blip. Fail fast with an actionable message instead.
    if (!apiKey || !subdomain) {
      throw new Error(
        `Fellow connection is missing ${!apiKey ? "an API key" : "a subdomain"}. Please re-enter your Fellow API key and subdomain.`,
      );
    }
    return new FellowAPI(apiKey, subdomain);
  }

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    const subdomain = this.tools.options.subdomain as string | undefined;
    return subdomain && subdomain.length > 0 ? subdomain : null;
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
            sharingModel: "thread" as const,
            logo: "https://plot.day/assets/logo-fellow.svg",
          },
          {
            type: "task",
            label: "Action Item",
            sharingModel: "none" as const,
            logo: "https://plot.day/assets/logo-fellow.svg",
            supportsAssignee: true,
            statuses: [
              { status: "open", label: "Open", icon: "todo" as StatusIcon, todo: true },
              { status: "done", label: "Done", icon: "done" as StatusIcon, done: true },
              {
                status: "archived",
                label: "Archived",
                icon: "cancelled" as StatusIcon,
                done: true,
              },
            ],
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
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
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
    await this.clear(`last_incremental_sync_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
      meta: { syncProvider: "fellow", channelId: channel.id },
    });
  }

  /**
   * Write back a status change made in Plot to Fellow. Only action-item task
   * links carry an `actionItemId`; meeting links have no external status to
   * push. Best-effort: a failed write is reconciled on the next sync-in
   * (Fellow remains the source of truth for status).
   */
  async onLinkUpdated(link: Link): Promise<void> {
    if (link.type !== "task") return;
    const actionItemId = link.meta?.actionItemId as string | undefined;
    if (!actionItemId) return;

    const api = this.getAPI();
    try {
      if (link.status === "archived") {
        await api.archiveActionItem(actionItemId);
      } else {
        await api.completeActionItem(actionItemId, link.status === "done");
      }
    } catch (error) {
      console.error(
        "[fellow] onLinkUpdated write-back failed:",
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  async setupWebhook(channelId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {async: false},
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
      console.log("Registering Fellow webhook for channel", channelId, "at", webhookUrl);
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

      const link = this.transformNote(note, channelId, isInitial);
      await this.tools.integrations.saveLink(link);

      for (const item of actionItems) {
        const taskLink = this.transformActionItem(
          item,
          { noteId: note.id, created: this.noteCreatedDate(note) },
          channelId,
          isInitial,
        );
        await this.tools.integrations.saveLink(taskLink);
      }
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
      // Sync complete — signal so the platform clears the "Syncing…"
      // indicator and the stuck-sync watchdog stops tracking this channel.
      // Gated on isInitial so incremental (webhook-driven) re-syncs, which
      // also flow through this same branch, don't fire it redundantly.
      if (isInitial) {
        await this.tools.integrations.channelSyncCompleted(channelId);
      }
      await this.clear(`sync_state_${channelId}`);
    }
  }

  /**
   * True when `content_markdown` is still Fellow's blank agenda template —
   * the "Talking Points / Action Items / Notepad" section headers with their
   * placeholder prompts and nothing else actually written in. Compared after
   * stripping markdown formatting and collapsing whitespace, since heading
   * level, emphasis markup, and blank-line count can all vary without the
   * content meaning anything different.
   */
  private isEmptyAgendaTemplate(markdown: string): boolean {
    const normalize = (text: string) =>
      text
        .replace(/[#*_`>-]/g, "")
        .replace(/\s+/g, " ")
        .trim()
        .toLowerCase();

    const template =
      "Talking Points (The things to talk about) " +
      "Action Items (What came out of this meeting? What are your next steps?) " +
      "Notepad (Anything else to write down?)";

    return normalize(markdown) === normalize(template);
  }

  /** The date a note-attached action item's task link is "created" as — the meeting time. */
  private noteCreatedDate(note: FellowNote): Date | undefined {
    return note.event_start
      ? new Date(note.event_start)
      : note.created_at
        ? new Date(note.created_at)
        : undefined;
  }

  /**
   * Map a Fellow action item status to a Plot task status.
   */
  private mapActionItemStatus(status: FellowActionItem["status"]): string {
    switch (status) {
      case "Done":
        return "done";
      case "Archived":
        return "archived";
      default:
        return "open";
    }
  }

  /**
   * Transform a Fellow action item into its own Plot task link, assigned to
   * the action item's assignee rather than embedding the assignee's name in
   * the note content.
   *
   * `context.noteId` is `null` for a standalone action item (created
   * directly in Fellow, not attached to a meeting note) — `sourceUrl` is
   * omitted in that case since there's no note page to link to.
   */
  private transformActionItem(
    item: FellowActionItem,
    context: { noteId: string | null; created?: Date },
    channelId: string,
    initialSync: boolean,
  ): NewLinkWithNotes {
    const subdomain = this.tools.options.subdomain as string;
    const primaryAssignee = item.assignees[0];
    const assignee: NewContact | undefined = primaryAssignee
      ? {
          ...(primaryAssignee.email ? { email: primaryAssignee.email } : {}),
          name: primaryAssignee.full_name,
          source: { accountId: primaryAssignee.id },
        }
      : undefined;
    const dueText = item.due_date ? ` — due ${item.due_date}` : "";
    const notes: any[] = [
      {
        key: "description",
        content: `${item.text}${dueText}`,
        contentType: "markdown" as const,
        author: null,
      },
    ];

    return {
      source: `fellow:${subdomain}:action-item:${item.id}`,
      title: item.text,
      type: "task",
      channelId,
      status: this.mapActionItemStatus(item.status),
      assignee: assignee ?? null,
      author: null,
      ...(context.noteId
        ? { sourceUrl: `https://${subdomain}.fellow.app/notes/${context.noteId}` }
        : {}),
      created: context.created,
      meta: {
        syncProvider: "fellow",
        channelId,
        noteId: context.noteId,
        actionItemId: item.id,
        ...(item.assignees.length > 0
          ? { assigneeNames: item.assignees.map((a) => a.full_name) }
          : {}),
      },
      notes,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /** Maps the `action_item.assigned` webhook payload to a `FellowActionItem`. */
  private actionItemFromAssignedWebhook(
    payload: FellowActionItemAssignedWebhook,
  ): FellowActionItem {
    return {
      id: payload.id,
      text: payload.text,
      status: payload.status,
      due_date: payload.due_date,
      note_id: payload.note_id,
      assignees: payload.assignees,
      completion_type: payload.completion_type,
      ai_detected: payload.ai_generated,
    };
  }

  /** Maps the `action_item.completed` webhook payload to a `FellowActionItem`. */
  private actionItemFromCompletedWebhook(
    payload: FellowActionItemCompletedWebhook,
  ): FellowActionItem {
    return {
      id: payload.id,
      text: payload.text,
      status: payload.wont_do ? "Archived" : payload.done ? "Done" : "Incomplete",
      due_date: payload.due_date,
      note_id: payload.note_id,
      assignees: payload.assignee_id
        ? [
            {
              id: payload.assignee_id,
              full_name: payload.assignee_name ?? "",
              email: payload.assignee_email ?? "",
            },
          ]
        : [],
      completion_type: null,
      ai_detected: payload.ai_generated,
    };
  }

  /**
   * Transform a Fellow note into a Plot meeting link with notes. Action
   * items are synced separately as their own task links (see
   * transformActionItem) rather than embedded here.
   */
  private transformNote(
    note: FellowNote,
    channelId: string,
    initialSync: boolean,
  ): NewLinkWithNotes {
    const notes: any[] = [];

    // Meeting notes content — skip Fellow's blank agenda template so a
    // meeting nobody has written anything in doesn't post an empty-looking
    // note to Plot.
    if (note.content_markdown && !this.isEmptyAgendaTemplate(note.content_markdown)) {
      notes.push({
        key: "notes",
        content: note.content_markdown,
        contentType: "markdown" as const,
        created: note.updated_at ? new Date(note.updated_at) : undefined,
      });
    }

    const subdomain = this.tools.options.subdomain as string;

    return {
      // Fellow note ids are tenant-scoped, so qualify with the workspace
      // subdomain to keep source globally unique across users.
      source: `fellow:${subdomain}:note:${note.id}`,
      // Cross-connector thread bundling: include canonical aliases so this
      // note attaches to the existing calendar event thread regardless of
      // which calendar connector created it. `icaluid:` works for Google,
      // Outlook, and Apple; `google-event:` and `google-calendar:` cover the
      // legacy Google-only path (Fellow's `event_guid` is the calendar UID).
      sources: [
        `fellow:${subdomain}:note:${note.id}`,
        ...(note.event_guid
          ? [
              `google-calendar:${note.event_guid}`,
              `icaluid:${note.event_guid}`,
              `google-event:${note.event_guid}`,
            ]
          : []),
      ],
      title: note.title || "Meeting Notes",
      type: "meeting",
      channelId,
      sourceUrl: `https://${subdomain}.fellow.app/notes/${note.id}`,
      created: this.noteCreatedDate(note),
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
   * Build a targeted update from an `ai_note.generated`/`ai_note.shared_to_channel`
   * webhook payload. Applies just the "ai-notes" note from the payload's
   * `ai_notes` field — the agenda/content_markdown note is left untouched
   * here and continues to be upserted by the content_markdown-driven sync
   * (`transformNote`), since this payload never carries that content.
   */
  private transformAiNoteWebhook(
    payload: FellowAiNoteWebhook,
    channelId: string,
  ): NewLinkWithNotes {
    const subdomain = this.tools.options.subdomain as string;
    const notes: any[] = payload.ai_notes
      ? [
          {
            key: "ai-notes",
            content: payload.ai_notes,
            contentType: "markdown" as const,
            author: null,
          },
        ]
      : [];

    return {
      source: `fellow:${subdomain}:note:${payload.id}`,
      sources: [
        `fellow:${subdomain}:note:${payload.id}`,
        ...(payload.event_id
          ? [
              `google-calendar:${payload.event_id}`,
              `icaluid:${payload.event_id}`,
              `google-event:${payload.event_id}`,
            ]
          : []),
      ],
      ...(payload.event_title ? { title: payload.event_title } : {}),
      type: "meeting",
      channelId,
      sourceUrl:
        payload.recap_url ??
        `https://${subdomain}.fellow.app/notes/${payload.id}`,
      created: payload.event_start ? new Date(payload.event_start) : undefined,
      meta: {
        syncProvider: "fellow",
        channelId,
        noteId: payload.id,
        ...(payload.event_id ? { eventGuid: payload.event_id } : {}),
      },
      notes,
    };
  }

  // Overlap applied to the stored incremental-sync cursor so a note updated
  // right at the edge of the previous window isn't lost to clock skew.
  private static readonly WEBHOOK_SYNC_OVERLAP_MS = 5 * 60 * 1000;

  /**
   * Handle incoming webhooks from Fellow.
   *
   * `action_item.assigned` and `action_item.completed` events carry the full
   * action item in the payload — including `note_id`, which is `null` for a
   * standalone action item created directly in Fellow (assigned to its
   * creator by default, not attached to any meeting note). Those are handled
   * directly from the payload below: a standalone item would never surface
   * through the note-driven re-sync path, since that path only ever visits
   * action items attached to a note it fetched.
   *
   * `ai_note.generated` and `ai_note.shared_to_channel` carry the AI-generated
   * notes content directly (`ai_notes`) — the `/notes` list endpoint's
   * `content_markdown` never includes it, only the agenda/manual content —
   * so that note is applied straight from the payload via
   * `transformAiNoteWebhook`. Execution still falls through afterward to the
   * generic re-sync below so any agenda/content_markdown change picked up in
   * the same webhook delivery isn't missed.
   *
   * Any payload we don't recognize also falls back to re-syncing every note
   * updated since our last successful incremental sync. Using a stored
   * cursor (rather than a fixed lookback window) means a note doesn't get
   * missed just because it happened to fall outside an arbitrary window
   * relative to whenever the webhook fired; the cursor always picks up
   * exactly where the last sync left off, with a small overlap for clock skew.
   */
  private async onWebhook(
    request: WebhookRequest,
    channelId: string,
  ): Promise<string | undefined> {
    const body = request.body;
    const challenge =
      body && typeof body === "object" && !Array.isArray(body)
        ? (body as Record<string, unknown>).challenge
        : undefined;
    if (challenge && typeof challenge === "string") {
      // Fellow webhook verification challenge
      console.log("Challenge received from Fellow webhook:", challenge);
      return(challenge);
    }

    const enabled = await this.get<boolean>(`sync_enabled_${channelId}`);
    if (!enabled) return;

    const eventType =
      body && typeof body === "object" && !Array.isArray(body)
        ? (body as Record<string, unknown>).event_type
        : undefined;

    if (eventType === "action_item.assigned") {
      const payload = body as unknown as FellowActionItemAssignedWebhook;
      const item = this.actionItemFromAssignedWebhook(payload);
      const taskLink = this.transformActionItem(
        item,
        {
          noteId: payload.note_id,
          created: payload.created_at ? new Date(payload.created_at) : undefined,
        },
        channelId,
        false,
      );
      await this.tools.integrations.saveLink(taskLink);
      return;
    }

    if (eventType === "action_item.completed") {
      const payload = body as unknown as FellowActionItemCompletedWebhook;
      const item = this.actionItemFromCompletedWebhook(payload);
      const taskLink = this.transformActionItem(
        item,
        { noteId: payload.note_id },
        channelId,
        false,
      );
      await this.tools.integrations.saveLink(taskLink);
      return;
    }

    if (
      eventType === "ai_note.generated" ||
      eventType === "ai_note.shared_to_channel"
    ) {
      const payload = body as unknown as FellowAiNoteWebhook;
      if (payload.ai_notes) {
        const link = this.transformAiNoteWebhook(payload, channelId);
        await this.tools.integrations.saveLink(link);
      }
      // Deliberately no `return` — fall through to the generic re-sync
      // below so the agenda/content_markdown note (not carried in this
      // payload) still gets picked up.
    }

    const api = this.getAPI();
    const cursorKey = `last_incremental_sync_${channelId}`;
    const storedCursor = await this.get<string>(cursorKey);
    const updatedAtStart = storedCursor
      ? new Date(
          new Date(storedCursor).getTime() - Fellow.WEBHOOK_SYNC_OVERLAP_MS,
        ).toISOString()
      : new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const syncStartedAt = new Date().toISOString();

    let cursor: string | undefined;
    do {
      const result = await api.listNotes({ updatedAtStart, cursor });

      for (const note of result.data) {
        let actionItems: FellowActionItem[] = [];
        try {
          const aiResult = await api.listActionItems();
          actionItems = aiResult.data.filter((ai) => ai.note_id === note.id);
        } catch {
          // Action items are supplementary; don't fail the sync
        }

        const link = this.transformNote(note, channelId, false);
        await this.tools.integrations.saveLink(link);

        for (const item of actionItems) {
          const taskLink = this.transformActionItem(
            item,
            { noteId: note.id, created: this.noteCreatedDate(note) },
            channelId,
            false,
          );
          await this.tools.integrations.saveLink(taskLink);
        }
      }

      cursor = result.nextCursor ?? undefined;
    } while (cursor);

    // Advance the cursor to when this sync started (not finished) so any
    // note updated while this sync was running gets picked up next time.
    await this.set(cursorKey, syncStartedAt);
  }
}

export default Fellow;
