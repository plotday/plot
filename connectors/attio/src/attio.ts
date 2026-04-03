import {
  type Link,
  type NewLinkWithNotes,
  type Note,
  type Thread,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Options } from "@plotday/twister/options";

import {
  AttioAPI,
  type AttioRecord,
  type AttioTask,
  type AttioWebhookEvent,
  type AttioWebhookSubscription,
  extractName,
  extractPersonName,
  extractEmail,
  extractPhone,
  extractDealStage,
  extractCurrencyValue,
} from "./attio-api";

type SyncState = {
  cursor: string | null;
  batchNumber: number;
  recordsProcessed: number;
  initialSync: boolean;
};

/**
 * Attio CRM connector — syncs deals, people, and tasks from Attio.
 *
 * Uses API key authentication via Options.
 */
export class Attio extends Connector<Attio> {
  static readonly handleReplies = true;
  readonly singleChannel = true;

  /** Entity types synced under the single channel. */
  private static readonly ENTITY_TYPES = ["deals", "people", "tasks"] as const;

  readonly linkTypes = [
    {
      type: "deal",
      label: "Deal",
      logo: "https://plot.day/assets/logo-attio.svg",
      logoDark: "https://plot.day/assets/logo-attio-dark.svg",
      statuses: [] as Array<{
        status: string;
        label: string;
        tag?: Tag;
        done?: true;
      }>,
      supportsAssignee: true,
    },
    {
      type: "person",
      label: "Person",
      logo: "https://plot.day/assets/logo-attio.svg",
      logoDark: "https://plot.day/assets/logo-attio-dark.svg",
      statuses: [],
    },
    {
      type: "task",
      label: "Task",
      logo: "https://plot.day/assets/logo-attio.svg",
      logoDark: "https://plot.day/assets/logo-attio-dark.svg",
      statuses: [
        { status: "open", label: "Open" },
        {
          status: "completed",
          label: "Completed",
          tag: Tag.Done,
          done: true as const,
        },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        apiKey: {
          type: "text" as const,
          secure: true,
          label: "Access Token",
          default: "",
          placeholder: "c_...",
          helpText:
            "In Attio, go to Settings → Developers → Access tokens, then click Generate access token.",
          helpUrl:
            "https://attio.com/help/apps/other-apps/generating-an-api-key",
        },
      }),
      network: build(Network, { urls: ["https://api.attio.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /** Build an AttioAPI client using the stored API key. */
  private getAPI(): AttioAPI {
    const apiKey = this.tools.options.apiKey as string;
    if (!apiKey) throw new Error("No Attio API key configured");
    return new AttioAPI(apiKey);
  }

  // ---- Account Identity ----

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string> {
    const api = this.getAPI();
    const workspace = await api.getWorkspace();
    await this.set("workspace_slug", workspace.slug);
    return workspace.name;
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns a single channel with all link types (deals, people, tasks).
   * Fetches deal pipeline stages dynamically for linkTypes.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    const api = this.getAPI();

    // Fetch deal stages dynamically (status attribute on deals)
    let dealStatuses: Array<{
      status: string;
      label: string;
      tag?: Tag;
      done?: true;
    }> = [];
    try {
      const stages = await api.getStatusOptions("deals", "stage");
      dealStatuses = stages
        .filter((s) => !s.is_archived)
        .map((stage) => ({
          status: stage.title,
          label: stage.title,
          ...(isWonStage(stage.title)
            ? { tag: Tag.Done, done: true as const }
            : {}),
          ...(isLostStage(stage.title) ? { done: true as const } : {}),
        }));
    } catch (error) {
      console.warn("Failed to fetch deal stages:", error);
    }

    return [
      {
        id: "attio",
        title: "Attio",
        linkTypes: [
          {
            type: "deal",
            label: "Deal",
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: dealStatuses,
            supportsAssignee: true,
          },
          {
            type: "person",
            label: "Person",
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: [],
          },
          {
            type: "task",
            label: "Task",
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: [
              { status: "open", label: "Open" },
              {
                status: "completed",
                label: "Completed",
                tag: Tag.Done,
                done: true as const,
              },
            ],
          },
        ],
      },
    ];
  }

  async onChannelEnabled(_channel: Channel): Promise<void> {
    await this.set("sync_enabled", true);
    await this.setupAttioWebhook();
    for (const entityType of Attio.ENTITY_TYPES) {
      await this.startBatchSync(entityType);
    }
  }

  async onChannelDisabled(_channel: Channel): Promise<void> {
    // Remove the shared webhook
    const webhookId = await this.get<string>("webhook_id");
    if (webhookId) {
      try {
        const api = this.getAPI();
        await api.deleteWebhook(webhookId);
      } catch (error) {
        console.warn("Failed to delete Attio webhook:", error);
      }
      await this.clear("webhook_id");
    }

    // Clean up per-entity sync state
    for (const entityType of Attio.ENTITY_TYPES) {
      await this.clear(`sync_state_${entityType}`);
    }
    await this.clear("sync_enabled");
  }

  // ---- Batch Sync ----

  private async startBatchSync(entityType: string): Promise<void> {
    await this.set(`sync_state_${entityType}`, {
      cursor: null,
      batchNumber: 1,
      recordsProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, entityType);
    await this.tools.tasks.runTask(batchCallback);
  }

  private async syncBatch(entityType: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${entityType}`);
    if (!state) throw new Error(`Sync state not found for ${entityType}`);

    const api = this.getAPI();

    if (entityType === "tasks") {
      await this.syncTaskBatch(api, state, entityType);
    } else {
      await this.syncRecordBatch(api, entityType, state);
    }
  }

  private async syncRecordBatch(
    api: AttioAPI,
    entityType: string,
    state: SyncState
  ): Promise<void> {
    const result = await api.queryRecords(entityType, {
      cursor: state.cursor ?? undefined,
      limit: 50,
    });

    for (const record of result.data) {
      const link =
        entityType === "deals"
          ? await this.convertDealToLink(record, state.initialSync)
          : await this.convertPersonToLink(record, state.initialSync);

      await this.tools.integrations.saveLink(link);
    }

    if (result.next_cursor) {
      await this.set(`sync_state_${entityType}`, {
        cursor: result.next_cursor,
        batchNumber: state.batchNumber + 1,
        recordsProcessed: state.recordsProcessed + result.data.length,
        initialSync: state.initialSync,
      } satisfies SyncState);

      const nextBatch = await this.callback(this.syncBatch, entityType);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      await this.clear(`sync_state_${entityType}`);
    }
  }

  private async syncTaskBatch(
    api: AttioAPI,
    state: SyncState,
    entityType: string
  ): Promise<void> {
    const result = await api.queryTasks({
      cursor: state.cursor ?? undefined,
      limit: 50,
    });

    for (const task of result.data) {
      const link = await this.convertTaskToLink(task, state.initialSync);
      await this.tools.integrations.saveLink(link);
    }

    if (result.next_cursor) {
      await this.set(`sync_state_${entityType}`, {
        cursor: result.next_cursor,
        batchNumber: state.batchNumber + 1,
        recordsProcessed: state.recordsProcessed + result.data.length,
        initialSync: state.initialSync,
      } satisfies SyncState);

      const nextBatch = await this.callback(this.syncBatch, entityType);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      await this.clear(`sync_state_${entityType}`);
    }
  }

  /** Build an Attio web app URL for a record. */
  private async getWorkspaceSlug(): Promise<string | null> {
    let slug = await this.get<string>("workspace_slug");
    if (!slug) {
      try {
        const api = this.getAPI();
        const workspace = await api.getWorkspace();
        slug = workspace.slug;
        if (slug) await this.set("workspace_slug", slug);
      } catch {
        // Fall through — return null
      }
    }
    return slug || null;
  }

  private async buildRecordUrl(
    objectSlug: string,
    recordId: string
  ): Promise<string> {
    const workspace = await this.getWorkspaceSlug();
    if (workspace) {
      return `https://app.attio.com/${workspace}/${objectSlug}/record/${recordId}/overview`;
    }
    return `https://app.attio.com/${objectSlug}/record/${recordId}/overview`;
  }

  // ---- Data Transformation ----

  private async convertDealToLink(
    record: AttioRecord,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const v = record.values;
    const name = extractName(v) || "Untitled Deal";
    const stage = extractDealStage(v);
    const value = extractCurrencyValue(v);
    const recordId = record.id.record_id;

    const preview = value
      ? `${value.currency} ${value.amount.toLocaleString()}`
      : null;

    return {
      source: `attio:deal:${recordId}`,
      type: "deal",
      title: name,
      created: new Date(record.created_at),
      status: stage?.title ?? null,
      channelId: "attio",
      meta: {
        attioRecordId: recordId,
        attioObjectSlug: "deals",
        syncProvider: "attio",
        channelId: "attio",
      },
      sourceUrl: await this.buildRecordUrl("deals", recordId),
      preview,
      notes: [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  private async convertPersonToLink(
    record: AttioRecord,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const v = record.values;
    const name = extractPersonName(v);
    const email = extractEmail(v);
    const phone = extractPhone(v);
    const recordId = record.id.record_id;

    const author: NewContact | undefined = email
      ? { email, name: name || email }
      : name
        ? { name }
        : undefined;

    return {
      source: `attio:person:${recordId}`,
      type: "person",
      title: name || email || "Unknown Person",
      created: new Date(record.created_at),
      author,
      channelId: "attio",
      meta: {
        attioRecordId: recordId,
        attioObjectSlug: "people",
        syncProvider: "attio",
        channelId: "attio",
      },
      sourceUrl: await this.buildRecordUrl("person", recordId),
      preview: [email, phone].filter(Boolean).join(" | ") || null,
      notes: [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  private async convertTaskToLink(
    task: AttioTask,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const taskId = task.id.task_id;

    return {
      source: `attio:task:${taskId}`,
      type: "task",
      title: task.content_plaintext || "Untitled Task",
      created: new Date(task.created_at),
      status: task.is_completed ? "completed" : "open",
      channelId: "attio",
      meta: {
        attioTaskId: taskId,
        syncProvider: "attio",
        channelId: "attio",
      },
      sourceUrl: await this.buildRecordUrl("tasks", taskId),
      notes: [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  // ---- Webhooks ----

  private async setupAttioWebhook(): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook
      );

      // Skip webhook registration in development
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      const api = this.getAPI();
      const subscriptions: AttioWebhookSubscription[] = [
        { event_type: "record.created", filter: null },
        { event_type: "record.updated", filter: null },
        { event_type: "record.deleted", filter: null },
      ];
      const result = await api.createWebhook(webhookUrl, subscriptions);

      const webhookId = result?.data?.id?.webhook_id;
      if (webhookId) {
        await this.set("webhook_id", webhookId);
      }
    } catch (error) {
      console.error("Failed to set up Attio webhook:", error);
    }
  }

  private async onWebhook(request: WebhookRequest): Promise<void> {
    const payload = request.body as AttioWebhookEvent | undefined;
    if (!payload?.event_type) return;

    if (
      payload.event_type === "record.created" ||
      payload.event_type === "record.updated"
    ) {
      const record = payload.record;
      if (!record) return;

      // Determine entity type from the webhook event's object slug
      const objectSlug = payload.object?.slug;
      let link: NewLinkWithNotes;
      if (objectSlug === "deals") {
        link = await this.convertDealToLink(record, false);
      } else if (objectSlug === "people") {
        link = await this.convertPersonToLink(record, false);
      } else {
        return;
      }

      await this.tools.integrations.saveLink(link);
    } else if (payload.event_type === "record.deleted") {
      const recordId = payload.record?.id?.record_id;
      if (!recordId) return;

      await this.tools.integrations.archiveLinks({
        meta: {
          attioRecordId: recordId,
          syncProvider: "attio",
        },
      });
    }

    // Handle task webhooks
    if (payload.task) {
      const link = await this.convertTaskToLink(payload.task, false);
      await this.tools.integrations.saveLink(link);
    }
  }

  // ---- Write-backs ----

  /** Write back deal stage changes to Attio. */
  async onLinkUpdated(link: Link): Promise<void> {
    if (!link.status) return;

    const recordId = link.meta?.attioRecordId as string | undefined;
    if (!recordId) return;

    const api = this.getAPI();

    if (link.type === "deal") {
      // Status is the stage status_id from dynamic linkTypes
      await api.updateRecord("deals", recordId, {
        stage: link.status,
      });
    }
  }

  /** Write back notes/comments to Attio as notes on the record. */
  async onNoteCreated(note: Note, thread: Thread): Promise<void> {
    const recordId = thread.meta?.attioRecordId as string | undefined;
    const objectSlug = thread.meta?.attioObjectSlug as string | undefined;
    if (!recordId || !objectSlug) return;

    const api = this.getAPI();
    await api.createNote(objectSlug, recordId, "", note.content ?? "");
  }

}

// ---- Helpers ----

/** Heuristic: does this stage name indicate a won/closed-won deal? */
function isWonStage(title: string): boolean {
  const lower = title.toLowerCase();
  return lower.includes("won") || lower.includes("closed won");
}

/** Heuristic: does this stage name indicate a lost/closed-lost deal? */
function isLostStage(title: string): boolean {
  const lower = title.toLowerCase();
  return (
    lower.includes("lost") ||
    lower.includes("closed lost") ||
    lower.includes("churned")
  );
}

export default Attio;
