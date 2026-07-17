import {
  type Link,
  type NewLinkWithNotes,
  type Note,
  type NoteWriteBackResult,
  type Thread,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Options } from "@plotday/twister/options";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";

import {
  AttioAPI,
  type AttioNote,
  type AttioRecord,
  type AttioTask,
  type AttioWebhookPayload,
  type AttioWebhookSubscription,
  extractName,
  extractPersonName,
  extractEmail,
  extractPhone,
  extractDealStage,
  extractCurrencyValue,
  extractDomain,
} from "./attio-api";

/** Maps Attio object slugs to connector link type identifiers. */
const OBJECT_TO_LINK_TYPE: Record<string, string> = {
  deals: "deal",
  people: "person",
  companies: "company",
};

/**
 * Batch page size for record/task/note crawls. Attio's list endpoints
 * return no cursor — a page shorter than this is the end-of-collection
 * signal, so every query must pass the same limit it checks against.
 */
const PAGE_SIZE = 50;

/** Drain key for webhook-driven incremental sync. */
const WEBHOOK_DRAIN_KEY = "webhook-events";

type SyncState = {
  offset: number;
  batchNumber: number;
  recordsProcessed: number;
  initialSync: boolean;
};

/** True when an Attio API error means the entity no longer exists. */
function isNotFound(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { status?: unknown }).status === 404
  );
}

/**
 * Attio CRM connector — syncs deals, people, and companies from Attio.
 * Tasks and notes are synced as notes on their parent records.
 *
 * Uses API key authentication via Options.
 */
export class Attio extends Connector<Attio> {
  static readonly handleReplies = true;
  readonly singleChannel = true;
  readonly access = [
    "Reads your records — people, companies, and deals",
    "Updates records and adds notes you make in Plot",
  ];

  /** Record types synced under the single channel. */
  private static readonly ENTITY_TYPES = ["deals", "people", "companies"] as const;

  /**
   * All five independent batch chains started by onChannelEnabled — the
   * three record entity types plus tasks and notes. Used to track which of
   * them have finished their initial sync (see markSyncTypeComplete).
   */
  private static readonly ALL_SYNC_TYPES = [
    ...Attio.ENTITY_TYPES,
    "tasks",
    "notes",
  ] as const;

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
    await this.set("workspace_id", workspace.id);
    return workspace.name;
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns a single channel with all link types (deals, people, companies).
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
      icon: StatusIcon;
      done?: true;
      todo?: true;
    }> = [];
    try {
      const stages = await api.getStatusOptions("deals", "stage");
      const nonArchived = stages.filter((s) => !s.is_archived);
      dealStatuses = nonArchived.map((stage) => ({
        status: stage.title,
        label: stage.title,
        // Won → done, lost → cancelled, all other pipeline stages → inProgress
        // (a deal sitting in any open stage is actively being worked).
        icon: (isWonStage(stage.title)
          ? "done"
          : isLostStage(stage.title)
            ? "cancelled"
            : "inProgress") as StatusIcon,
        ...(isWonStage(stage.title) ? { done: true as const } : {}),
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
            sharingModel: "channel" as const,
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: dealStatuses,
            supportsAssignee: true,
          },
          {
            type: "person",
            label: "Person",
            sharingModel: "channel" as const,
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: [],
            defaultCreateThreads: "actionable",
          },
          {
            type: "company",
            label: "Company",
            sharingModel: "channel" as const,
            logo: "https://plot.day/assets/logo-attio.svg",
            logoDark: "https://plot.day/assets/logo-attio-dark.svg",
            statuses: [],
            defaultCreateThreads: "actionable",
          },
        ],
      },
    ];
  }

  async onChannelEnabled(_channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>("sync_history_min");
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        return; // Already synced with wider range
      }
      await this.set("sync_history_min", syncHistoryMin.toISOString());
    }

    await this.set("sync_enabled", true);

    // Queue webhook setup as a separate task to avoid blocking the HTTP response
    const webhookCallback = await this.callback(this.setupAttioWebhook);
    await this.runTask(webhookCallback);

    // Track completion of all five independent batch chains kicked off
    // below. They all sync under this connector's single channel ("attio"),
    // so the platform's initial-sync-done signal must wait for every chain
    // to finish, not just the first. Reset unconditionally: this method can
    // be re-dispatched (auto-enable, recovery), and startBatchSync always
    // starts each chain as a fresh initial sync when it runs.
    await this.set("initial_sync_pending", [...Attio.ALL_SYNC_TYPES]);

    for (const entityType of Attio.ENTITY_TYPES) {
      await this.startBatchSync(entityType);
    }
    // Tasks and notes are items on records — sync them as notes on parent threads
    await this.startBatchSync("tasks");
    await this.startBatchSync("notes");
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

    // Stop draining queued webhook events
    await this.cancelDrain(WEBHOOK_DRAIN_KEY);

    // Clean up per-entity sync state
    for (const entityType of Attio.ENTITY_TYPES) {
      await this.clear(`sync_state_${entityType}`);
    }
    await this.clear("sync_state_tasks");
    await this.clear("sync_state_notes");
    await this.clear("sync_enabled");
    await this.clear("initial_sync_pending");
    await this.clear("attio_object_slugs");
  }

  // ---- Batch Sync ----

  private async startBatchSync(entityType: string): Promise<void> {
    await this.set(`sync_state_${entityType}`, {
      offset: 0,
      batchNumber: 1,
      recordsProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, entityType);
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Persist continuation state and queue the next page of a batch chain,
   * or run the chain's terminal branch when the page was partial (Attio
   * returns no cursor — a full page is the only "more may remain" signal).
   */
  private async continueOrFinishChain(
    entityType: string,
    state: SyncState,
    pageLength: number
  ): Promise<void> {
    if (pageLength === PAGE_SIZE) {
      await this.set(`sync_state_${entityType}`, {
        offset: state.offset + pageLength,
        batchNumber: state.batchNumber + 1,
        recordsProcessed: state.recordsProcessed + pageLength,
        initialSync: state.initialSync,
      } satisfies SyncState);

      const nextBatch = await this.callback(this.syncBatch, entityType);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // No more pages left to schedule for this chain — one of the five
      // initial-sync chains is done. Signal completion (once all five have
      // reported in) so the platform stamps initial_sync_completed_at;
      // otherwise the stuck-sync watchdog eventually force-flags a healthy
      // connection as needing reconnection. Gating on initialSync avoids a
      // pointless call for incremental re-syncs. markSyncTypeComplete may
      // throw (lock starvation) — that must happen BEFORE the clear() so a
      // retry of this batch can still record the completion.
      if (state.initialSync) {
        await this.markSyncTypeComplete(entityType);
      }
      await this.clear(`sync_state_${entityType}`);
    }
  }

  /**
   * Mark one of the five independent initial-sync chains (deals, people,
   * companies, tasks, notes) as finished, and signal
   * `integrations.channelSyncCompleted` for the shared "attio" channel once
   * all five have finished.
   *
   * All five chains are started together from onChannelEnabled under this
   * connector's single channel (`singleChannel = true`) and then run
   * concurrently as independent runTask chains, each with its own
   * pagination. Completion of any *one* chain is not sufficient signal that
   * the connection's initial sync is done — without waiting for all five,
   * the platform's "Syncing…" indicator would clear (and the stuck-sync
   * watchdog would stop tracking the connection) while the other chains are
   * still backfilling. The pending-set read-modify-write is guarded by a
   * short-lived lock because two chains can legitimately finish around the
   * same time, and a naive get+filter+set would race and could drop an
   * update — see "Locks" in TOOLS_GUIDE.md.
   *
   * Throws if the lock can never be acquired (rather than silently giving
   * up) so the caller's terminal branch does NOT clear `sync_state_*` for
   * this chain — leaving it in place lets a future retry of this batch
   * actually record the completion. Silently swallowing this would strand
   * `entityType` in `initial_sync_pending` forever, and channelSyncCompleted
   * would never fire even though every chain genuinely finished — the exact
   * bug class this fix exists to eliminate, reintroduced one level down.
   */
  private async markSyncTypeComplete(entityType: string): Promise<void> {
    const lockKey = "initial_sync_pending_lock";
    const maxAttempts = 10;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (await this.tools.store.acquireLock(lockKey, 10_000)) {
        let allComplete = false;
        try {
          const pending = await this.get<string[]>("initial_sync_pending");
          if (pending === null) {
            // Never initialized (or a concurrent completion already
            // cleared it) — most likely a connection whose chains were
            // started under pre-fix code that didn't write this key at
            // all. We can't safely tell how many of the other four chains
            // are still outstanding, so skip signaling rather than risk
            // firing channelSyncCompleted while they're still backfilling.
            return;
          }
          const remaining = pending.filter((type) => type !== entityType);
          if (remaining.length > 0) {
            await this.set("initial_sync_pending", remaining);
          } else {
            await this.clear("initial_sync_pending");
            allComplete = true;
          }
        } finally {
          await this.tools.store.releaseLock(lockKey);
        }
        // Call outside the lock — channelSyncCompleted is a network call,
        // and holding the lock across it would needlessly widen the window
        // for contention with the other four chains.
        if (allComplete) {
          await this.tools.integrations.channelSyncCompleted("attio");
        }
        return;
      }
      // Another chain is updating the pending set right now — brief
      // backoff and retry rather than silently dropping this chain's
      // completion (which could leave the connection stuck "Syncing"
      // forever if it happened to be the last chain to finish).
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(
      `Attio: failed to acquire initial_sync_pending_lock after ${maxAttempts} attempts ` +
        `while completing "${entityType}" sync`
    );
  }

  private async syncBatch(entityType: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${entityType}`);
    if (!state) throw new Error(`Sync state not found for ${entityType}`);

    // A state persisted by a previous connector version has no `offset`
    // (it tracked a cursor that Attio's API never actually returned).
    // Restart that chain from the beginning — upserts make this idempotent.
    if (typeof state.offset !== "number") state.offset = 0;

    const api = this.getAPI();

    if (entityType === "tasks") {
      await this.syncTaskBatch(api, state, entityType);
    } else if (entityType === "notes") {
      await this.syncNoteBatch(api, state, entityType);
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
      offset: state.offset,
      limit: PAGE_SIZE,
    });

    for (const record of result.data) {
      const link = await this.convertRecordToLink(
        entityType,
        record,
        state.initialSync
      );
      if (!link) continue;
      await this.tools.integrations.saveLink(link);
    }

    await this.continueOrFinishChain(entityType, state, result.data.length);
  }

  private async syncTaskBatch(
    api: AttioAPI,
    state: SyncState,
    entityType: string
  ): Promise<void> {
    const result = await api.queryTasks({
      offset: state.offset,
      limit: PAGE_SIZE,
    });

    for (const task of result.data) {
      await this.saveTaskAsNotes(task, state.initialSync);
    }

    await this.continueOrFinishChain(entityType, state, result.data.length);
  }

  private async syncNoteBatch(
    api: AttioAPI,
    state: SyncState,
    entityType: string
  ): Promise<void> {
    const result = await api.queryNotes({
      offset: state.offset,
      limit: PAGE_SIZE,
    });

    for (const note of result.data) {
      await this.saveNoteOnParent(note, state.initialSync);
    }

    await this.continueOrFinishChain(entityType, state, result.data.length);
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
        if (workspace.id) await this.set("workspace_id", workspace.id);
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

  /**
   * Convert a record to a link based on its object slug. Returns null for
   * object types this connector doesn't sync.
   */
  private async convertRecordToLink(
    objectSlug: string,
    record: AttioRecord,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    if (objectSlug === "deals") {
      return this.convertDealToLink(record, initialSync);
    }
    if (objectSlug === "people") {
      return this.convertPersonToLink(record, initialSync);
    }
    if (objectSlug === "companies") {
      return this.convertCompanyToLink(record, initialSync);
    }
    return null;
  }

  /**
   * Fetch a record, treating 404 as "deleted upstream" (null). `objectRef`
   * may be a slug or the object's UUID — Attio accepts either in the path.
   */
  private async fetchRecordOrNull(
    objectRef: string,
    recordId: string
  ): Promise<AttioRecord | null> {
    try {
      const result = await this.getAPI().getRecord(objectRef, recordId);
      return result.data;
    } catch (error) {
      if (isNotFound(error)) return null;
      throw error;
    }
  }

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

    const workspaceId = record.id.workspace_id;

    return {
      source: `attio:${workspaceId}:deal:${recordId}`,
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

    const workspaceId = record.id.workspace_id;

    return {
      source: `attio:${workspaceId}:person:${recordId}`,
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

  private async convertCompanyToLink(
    record: AttioRecord,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const v = record.values;
    const name = extractName(v) || "Untitled Company";
    const domain = extractDomain(v);
    const recordId = record.id.record_id;
    const workspaceId = record.id.workspace_id;

    return {
      source: `attio:${workspaceId}:company:${recordId}`,
      type: "company",
      title: name,
      created: new Date(record.created_at),
      channelId: "attio",
      meta: {
        attioRecordId: recordId,
        attioObjectSlug: "companies",
        syncProvider: "attio",
        channelId: "attio",
      },
      sourceUrl: await this.buildRecordUrl("companies", recordId),
      preview: domain || null,
      notes: [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Save an Attio task as a note on each of its linked parent records.
   * Tasks without linked_records are skipped.
   *
   * The parent record is fetched so the upserted link carries the real
   * title and fields — the task payload holds only ids, and upserting a
   * bare id-only link would create an untitled thread whenever the parent
   * hasn't been imported yet. Parents deleted upstream (404) are skipped.
   */
  private async saveTaskAsNotes(
    task: AttioTask,
    initialSync: boolean
  ): Promise<void> {
    const taskId = task.id.task_id;
    if (!task.linked_records?.length) return;

    const statusSuffix = task.is_completed ? " ✅" : "";
    const content =
      (task.content_plaintext || "Untitled Task") + statusSuffix;

    for (const linked of task.linked_records) {
      if (!OBJECT_TO_LINK_TYPE[linked.target_object]) continue;

      const record = await this.fetchRecordOrNull(
        linked.target_object,
        linked.target_record_id
      );
      if (!record) continue;

      const link = await this.convertRecordToLink(
        linked.target_object,
        record,
        initialSync
      );
      if (!link) continue;

      link.notes = [
        {
          key: `task-${taskId}`,
          content,
          created: new Date(task.created_at),
        } as any,
      ];
      await this.tools.integrations.saveLink(link);
    }
  }

  /**
   * Save an Attio note as a Plot note on its parent record.
   *
   * Fetches the parent record for the same reason as {@link saveTaskAsNotes}:
   * the note payload carries only the parent's ids, and a note can reference
   * a record the record chains never imported. Notes whose parent was
   * deleted in Attio (404) are skipped entirely rather than creating an
   * untitled stub thread.
   */
  private async saveNoteOnParent(
    note: AttioNote,
    initialSync: boolean
  ): Promise<void> {
    const noteId = note.id.note_id;
    if (!OBJECT_TO_LINK_TYPE[note.parent_object]) return;

    const content = note.content_plaintext || note.title || "";
    if (!content) return;

    const record = await this.fetchRecordOrNull(
      note.parent_object,
      note.parent_record_id
    );
    if (!record) return;

    const link = await this.convertRecordToLink(
      note.parent_object,
      record,
      initialSync
    );
    if (!link) return;

    link.notes = [
      {
        key: `note-${noteId}`,
        content: note.title
          ? `**${note.title}**\n\n${note.content_plaintext}`
          : content,
        created: new Date(note.created_at),
      } as any,
    ];
    await this.tools.integrations.saveLink(link);
  }

  // ---- Webhooks ----

  async setupAttioWebhook(): Promise<void> {
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

    // This method re-runs on every channel re-enable/recovery; delete the
    // previous registration so Attio doesn't accumulate duplicate webhooks
    // (each duplicate re-delivers every event).
    const previousId = await this.get<string>("webhook_id");
    if (previousId) {
      try {
        await api.deleteWebhook(previousId);
      } catch (error) {
        // Already gone (or revoked) is fine — anything else still shouldn't
        // block registering the replacement.
        if (!isNotFound(error)) {
          console.warn("Failed to delete previous Attio webhook:", error);
        }
      }
    }

    const subscriptions: AttioWebhookSubscription[] = [
      { event_type: "record.created", filter: null },
      { event_type: "record.updated", filter: null },
      { event_type: "record.deleted", filter: null },
      { event_type: "note.created", filter: null },
      { event_type: "note.updated", filter: null },
      { event_type: "note-content.updated", filter: null },
      { event_type: "task.created", filter: null },
      { event_type: "task.updated", filter: null },
    ];
    // Registration failures propagate: this runs as a queued task, so
    // throwing lets the queue retry instead of silently leaving the
    // connection without any incremental sync.
    const result = await api.createWebhook(webhookUrl, subscriptions);

    const webhookId = result?.data?.id?.webhook_id;
    if (webhookId) {
      await this.set("webhook_id", webhookId);
    }
  }

  /**
   * Attio delivers events batched — `{ webhook_id, events: [...] }` — and
   * each event carries only ids, never the full entity. Queue the ids for
   * the drain (which fetches each entity), except deletions, which need no
   * fetch and archive inline.
   */
  private async onWebhook(request: WebhookRequest): Promise<void> {
    const payload = request.body as AttioWebhookPayload | undefined;
    const events = Array.isArray(payload?.events) ? payload.events : [];
    if (!events.length) return;

    const ids: string[] = [];
    for (const event of events) {
      switch (event.event_type) {
        case "record.created":
        case "record.updated":
          if (event.id.object_id && event.id.record_id) {
            ids.push(`record:${event.id.object_id}:${event.id.record_id}`);
          }
          break;
        case "record.deleted":
          if (event.id.record_id) {
            await this.tools.integrations.archiveLinks({
              meta: {
                attioRecordId: event.id.record_id,
                syncProvider: "attio",
              },
            });
          }
          break;
        case "note.created":
        case "note.updated":
        case "note-content.updated":
          if (event.id.note_id) {
            ids.push(`note:${event.id.note_id}`);
          }
          break;
        case "task.created":
        case "task.updated":
          if (event.id.task_id) {
            ids.push(`task:${event.id.task_id}`);
          }
          break;
        default:
          break;
      }
    }

    if (ids.length) {
      await this.scheduleDrain(WEBHOOK_DRAIN_KEY, this.drainWebhookEvents, {
        ids,
      });
    }
  }

  /**
   * Drain handler for webhook events: fetches each changed entity by id
   * and upserts it. Entities deleted between notification and drain (404)
   * are skipped. Always incremental — never sets `unread: false`.
   */
  async drainWebhookEvents(ids: string[]): Promise<void> {
    const api = this.getAPI();

    for (const id of ids) {
      const [kind, ...rest] = id.split(":");

      if (kind === "record") {
        const [objectId, recordId] = rest;
        const slug = await this.getObjectSlug(objectId);
        if (!slug || !OBJECT_TO_LINK_TYPE[slug]) continue;

        const record = await this.fetchRecordOrNull(objectId, recordId);
        if (!record) continue;

        const link = await this.convertRecordToLink(slug, record, false);
        if (!link) continue;
        await this.tools.integrations.saveLink(link);
      } else if (kind === "note") {
        const note = await this.fetchNoteOrNull(api, rest[0]);
        if (!note) continue;
        await this.saveNoteOnParent(note, false);
      } else if (kind === "task") {
        const task = await this.fetchTaskOrNull(api, rest[0]);
        if (!task) continue;
        await this.saveTaskAsNotes(task, false);
      }
    }
  }

  private async fetchNoteOrNull(
    api: AttioAPI,
    noteId: string
  ): Promise<AttioNote | null> {
    try {
      return (await api.getNote(noteId)).data;
    } catch (error) {
      if (isNotFound(error)) return null;
      throw error;
    }
  }

  private async fetchTaskOrNull(
    api: AttioAPI,
    taskId: string
  ): Promise<AttioTask | null> {
    try {
      return (await api.getTask(taskId)).data;
    } catch (error) {
      if (isNotFound(error)) return null;
      throw error;
    }
  }

  /**
   * Resolve an object UUID (the only object identifier webhook events
   * carry) to its API slug, caching the workspace's object map.
   */
  private async getObjectSlug(objectId: string): Promise<string | null> {
    const cached = await this.get<Record<string, string>>(
      "attio_object_slugs"
    );
    if (cached?.[objectId]) return cached[objectId];

    const objects = await this.getAPI().listObjects();
    const map: Record<string, string> = {};
    for (const object of objects) {
      map[object.id.object_id] = object.api_slug;
    }
    await this.set("attio_object_slugs", map);
    return map[objectId] ?? null;
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

  /**
   * Write back notes/comments to Attio as notes on the record.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime can (a) key the
   * Plot note for future upserts and (b) hash the external representation
   * as the sync baseline. The baseline matches the exact string the
   * sync-in path ({@link saveNoteOnParent}) will build on the next pass:
   * Attio falls back to `title = "Comment from Plot"` when we send an
   * empty title, so sync-in reconstructs the note as
   * `**Comment from Plot**\n\n{content_plaintext}`.
   */
  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const recordId = thread.meta?.attioRecordId as string | undefined;
    const objectSlug = thread.meta?.attioObjectSlug as string | undefined;
    if (!recordId || !objectSlug) return;

    // Attio posts notes with `format: "plaintext"` (attio-api.ts), so
    // render Plot markdown to readable plain text first.
    const content = markdownToPlainText(note.content ?? "");
    const api = this.getAPI();
    const result = await api.createNote(objectSlug, recordId, "", content);
    const noteId = result?.data?.id?.note_id;
    if (!noteId) return;

    // Must match the form saveNoteOnParent will reconstruct on sync-in.
    // saveNoteOnParent uses contentType default (= "markdown") — keep that
    // in sync here so the baseline hash matches.
    const externalContent = `**Comment from Plot**\n\n${content}`;

    return {
      key: `note-${noteId}`,
      externalContent,
    };
  }

  /**
   * Attio's public REST API exposes only create/get/list/delete for notes —
   * there is no update endpoint (verified against
   * https://docs.attio.com/rest-api/endpoint-reference/notes). Without a
   * stable update path we can't safely rewrite an existing note (delete +
   * recreate would change the note id, breaking the `note-<id>` key that
   * the next sync pass uses for upsert). Leaving this as a no-op means
   * edits to Plot notes are not written back; the next full sync will
   * still reflect any server-side edits from the Attio side.
   */
  async onNoteUpdated(
    _note: Note,
    _thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    return;
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
