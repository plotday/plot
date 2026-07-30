import {
  type Link,
  type NewLinkWithNotes,
  type NewTags,
  type Note,
  type NoteWriteBackResult,
  Tag,
  type Thread,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";

import {
  HubSpotAPI,
  type HubSpotEngagementType,
  type HubSpotObject,
  type HubSpotObjectType,
  type HubSpotPipeline,
  type HubSpotRecordType,
  OBJECT_PROPERTIES,
  LAST_MODIFIED_PROPERTY,
  contactDisplayName,
  escapeHtml,
  formatDealAmount,
  plainTextToHtml,
} from "./hubspot-api";

/** The connector's single channel id (`singleChannel = true`). */
const CHANNEL_ID = "hubspot";

/** CRM record types that become threads. */
const RECORD_TYPES: readonly HubSpotRecordType[] = [
  "contacts",
  "companies",
  "deals",
];

/** Engagement types synced as notes on their associated records' threads. */
const ENGAGEMENT_TYPES: readonly HubSpotEngagementType[] = ["notes", "tasks"];

/**
 * All five independent batch chains started by onChannelEnabled — the three
 * record types plus the two engagement types. Used to track which of them
 * have finished their initial sync (see markSyncTypeComplete).
 */
const ALL_SYNC_TYPES: readonly HubSpotObjectType[] = [
  ...RECORD_TYPES,
  ...ENGAGEMENT_TYPES,
];

/** Maps HubSpot object types to connector link type identifiers. */
const OBJECT_TO_LINK_TYPE: Record<HubSpotRecordType, string> = {
  contacts: "contact",
  companies: "company",
  deals: "deal",
};

/** HubSpot's object type ids, used in app record URLs. */
const RECORD_TYPE_IDS: Record<HubSpotRecordType, string> = {
  contacts: "0-1",
  companies: "0-2",
  deals: "0-3",
};

/** List-endpoint page size for the initial crawl (the endpoint's max). */
const PAGE_SIZE = 100;

/**
 * HubSpot exposes webhooks only at the app level (one shared endpoint
 * configured in the developer app, delivering events for every installed
 * portal) — there is no per-account subscription API this connector could
 * register against. Incremental sync therefore polls the CRM search API
 * for recently modified objects instead.
 */
const POLL_TASK_KEY = "change-poll";
const POLL_INTERVAL_MS = 5 * 60 * 1000;

/** Search pages consumed per object type per poll; leftovers resume next poll. */
const MAX_POLL_PAGES = 5;

/**
 * HubSpot's search index can lag writes by a few seconds. Never advance the
 * poll high-water mark closer to "now" than this buffer, so a record whose
 * index entry lands late is still caught by the next poll. Costs at most a
 * re-upsert of anything modified inside the buffer window.
 */
const SEARCH_INDEX_LAG_MS = 60 * 1000;

const HUBSPOT_LOGO = "https://api.iconify.design/logos/hubspot.svg";

/**
 * Statuses for the standalone `task` link type, mapped 1:1 from HubSpot's
 * `hs_task_status` values so write-back needs no translation.
 */
const TASK_STATUSES = [
  { status: "NOT_STARTED", label: "To do", icon: "todo" as StatusIcon, todo: true as const },
  { status: "IN_PROGRESS", label: "In progress", icon: "inProgress" as StatusIcon },
  { status: "WAITING", label: "Waiting", icon: "blocked" as StatusIcon },
  { status: "DEFERRED", label: "Deferred", icon: "backlog" as StatusIcon },
  { status: "COMPLETED", label: "Done", done: true as const, icon: "done" as StatusIcon },
];

type SyncState = {
  after: string | null;
  batchNumber: number;
  itemsProcessed: number;
  initialSync: boolean;
};

/** Owner-map entry, indexed under both `owner:<id>` and `user:<userId>`. */
type OwnerEntry = {
  name: string;
  email: string | null;
  /** Canonical platform identity for this person (see resolveOwnerEntry). */
  accountId: string;
  /**
   * The HubSpot owner id for this person — the value `hubspot_owner_id`
   * properties take on write-back (assignee changes PATCH this, whichever
   * id space the Plot-side actor resolved through).
   */
  ownerId: string;
};

/** True when a HubSpot API error means the entity no longer exists. */
function isNotFound(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { status?: unknown }).status === 404
  );
}

/**
 * HubSpot CRM connector — syncs contacts, companies, and deals. Note and
 * task engagements are synced as notes on their associated records'
 * threads. Notes added in Plot write back to HubSpot, and deal stage
 * changes in either direction stay in sync.
 */
export class HubSpot extends Connector<HubSpot> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.HubSpot;
  readonly scopes = [
    // Notes/tasks engagements are gated on the contacts scopes, so the
    // write scope is required for note write-backs, not contact edits.
    "crm.objects.contacts.read",
    "crm.objects.contacts.write",
    "crm.objects.companies.read",
    "crm.objects.deals.read",
    "crm.objects.deals.write",
    "crm.objects.owners.read",
  ];
  readonly singleChannel = true;
  readonly access = [
    "Reads your contacts, companies, and deals",
    "Adds notes and updates deal stages you change in Plot",
    "Keeps Plot up to date as records change in HubSpot",
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.hubapi.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Owner-map refresh guard, so an unresolvable author triggers at most one
   * re-fetch per execution. Instance state does not persist across
   * executions — that's exactly the lifetime we want here.
   */
  private ownersRefreshed = false;

  /** Build a HubSpotAPI client using the channel's OAuth token. */
  private async getAPI(): Promise<HubSpotAPI> {
    const token = await this.tools.integrations.get(CHANNEL_ID);
    if (!token) throw new Error("No HubSpot authentication token available");
    return new HubSpotAPI(token.token);
  }

  // ---- Account Identity ----

  /**
   * Returns the connected portal's domain (e.g. "acme.hubspot.com") and
   * caches the hub id used in `source` keys and record URLs.
   */
  override async getAccountName(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<string | null> {
    if (!token) return null;
    try {
      const api = new HubSpotAPI(token.token);
      const info = await api.getAccessTokenInfo();
      await this.set("hub_id", String(info.hub_id));
      if (info.user_id != null) {
        await this.set("hub_user_id", String(info.user_id));
      }
      return info.hub_domain || info.user || null;
    } catch {
      return null;
    }
  }

  /**
   * The portal (hub) id qualifying `source` keys and record URLs, plus
   * the connecting user's id (Done-tag attribution fallback). Cached at
   * connect time by getAccountName; fetched lazily as a fallback.
   */
  private async getHubInfo(
    api: HubSpotAPI
  ): Promise<{ hubId: string; userId: string | null }> {
    const storedHub = await this.get<string>("hub_id");
    if (storedHub) {
      return { hubId: storedHub, userId: await this.get<string>("hub_user_id") };
    }
    const info = await api.getAccessTokenInfo();
    const hubId = String(info.hub_id);
    await this.set("hub_id", hubId);
    const userId = info.user_id != null ? String(info.user_id) : null;
    if (userId) await this.set("hub_user_id", userId);
    return { hubId, userId };
  }

  private async getHubId(api: HubSpotAPI): Promise<string> {
    return (await this.getHubInfo(api)).hubId;
  }

  /**
   * The connecting user as an actor — the Done-tag attribution fallback
   * for completed tasks with no resolvable assignee or creator (HubSpot
   * records no "completed by").
   */
  private async connectionOwnerActor(): Promise<NewContact | null> {
    const api = await this.getAPI();
    const info = await this.getHubInfo(api);
    if (info.userId == null) return null;
    return this.resolveAuthor(`user:${info.userId}`);
  }

  // ---- Channel Lifecycle ----

  /**
   * Returns the single HubSpot channel. Deal statuses are the portal's
   * pipeline stages, fetched dynamically; when the portal has more than
   * one deal pipeline, stage labels are prefixed with the pipeline name.
   */
  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    let dealStatuses: Array<{
      status: string;
      label: string;
      icon: StatusIcon;
      done?: true;
    }> = [];
    if (token) {
      try {
        const api = new HubSpotAPI(token.token);
        const pipelines = await api.listPipelines("deals");
        dealStatuses = buildDealStatuses(pipelines);
      } catch (error) {
        console.warn("Failed to fetch HubSpot deal pipelines:", error);
      }
    }

    return [
      {
        id: CHANNEL_ID,
        title: "HubSpot",
        linkTypes: [
          {
            type: "deal",
            label: "Deal",
            sharingModel: "channel" as const,
            logo: HUBSPOT_LOGO,
            statuses: dealStatuses,
            supportsAssignee: true,
          },
          {
            type: "contact",
            label: "Contact",
            sharingModel: "channel" as const,
            logo: HUBSPOT_LOGO,
            statuses: [],
            defaultCreateThreads: "actionable",
          },
          {
            type: "company",
            label: "Company",
            sharingModel: "channel" as const,
            logo: HUBSPOT_LOGO,
            statuses: [],
            defaultCreateThreads: "actionable",
          },
          // Standalone tasks only — tasks associated with a record sync as
          // to-do notes on that record's thread instead (see
          // saveEngagementsOnParents).
          {
            type: "task",
            label: "Task",
            sharingModel: "channel" as const,
            logo: HUBSPOT_LOGO,
            statuses: TASK_STATUSES,
            supportsAssignee: true,
          },
        ],
      },
    ];
  }

  async onChannelEnabled(
    _channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>("sync_history_min");
      if (
        storedMin &&
        new Date(storedMin) <= syncHistoryMin &&
        !context?.recovering
      ) {
        return; // Already synced with wider range
      }
      await this.set("sync_history_min", syncHistoryMin.toISOString());
    }

    await this.set("sync_enabled", true);

    // Anything modified after this instant is the poll's responsibility;
    // the initial crawl below picks up everything that already exists.
    const pollBaseline = new Date().toISOString();
    for (const type of ALL_SYNC_TYPES) {
      await this.set(`poll_since_${type}`, pollBaseline);
    }
    await this.schedulePoll();

    // Track completion of all five independent batch chains kicked off
    // below. They all sync under this connector's single channel, so the
    // platform's initial-sync-done signal must wait for every chain to
    // finish, not just the first. Reset unconditionally: this method can
    // be re-dispatched (auto-enable, recovery), and startBatchSync always
    // starts each chain as a fresh initial sync when it runs.
    await this.set("initial_sync_pending", [...ALL_SYNC_TYPES]);

    for (const type of ALL_SYNC_TYPES) {
      await this.startBatchSync(type);
    }
  }

  async onChannelDisabled(_channel: Channel): Promise<void> {
    await this.cancelScheduledTask(POLL_TASK_KEY);

    for (const type of ALL_SYNC_TYPES) {
      await this.clear(`sync_state_${type}`);
      await this.clear(`poll_since_${type}`);
    }
    await this.clear("sync_enabled");
    await this.clear("initial_sync_pending");
    await this.clear("owners_map");
  }

  // ---- Batch Sync (initial crawl) ----

  private async startBatchSync(type: HubSpotObjectType): Promise<void> {
    await this.set(`sync_state_${type}`, {
      after: null,
      batchNumber: 1,
      itemsProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, type);
    await this.runTask(batchCallback);
  }

  private async syncBatch(type: HubSpotObjectType): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${type}`);
    if (!state) throw new Error(`Sync state not found for ${type}`);

    const api = await this.getAPI();

    if (type === "notes" || type === "tasks") {
      await this.syncEngagementBatch(api, type, state);
    } else {
      await this.syncRecordBatch(api, type, state);
    }
  }

  private async syncRecordBatch(
    api: HubSpotAPI,
    type: HubSpotRecordType,
    state: SyncState
  ): Promise<void> {
    const page = await api.listObjects(type, {
      after: state.after,
      limit: PAGE_SIZE,
      properties: OBJECT_PROPERTIES[type],
    });

    for (const record of page.results) {
      const link = await this.convertRecordToLink(
        api,
        type,
        record,
        state.initialSync
      );
      await this.tools.integrations.saveLink(link);
    }

    await this.continueOrFinishChain(
      type,
      state,
      page.results.length,
      page.paging?.next?.after ?? null
    );
  }

  private async syncEngagementBatch(
    api: HubSpotAPI,
    type: HubSpotEngagementType,
    state: SyncState
  ): Promise<void> {
    const page = await api.listObjects(type, {
      after: state.after,
      limit: PAGE_SIZE,
      properties: OBJECT_PROPERTIES[type],
      associations: [...RECORD_TYPES],
    });

    await this.saveEngagementsOnParents(api, type, page.results, state.initialSync);

    await this.continueOrFinishChain(
      type,
      state,
      page.results.length,
      page.paging?.next?.after ?? null
    );
  }

  /**
   * Persist continuation state and queue the next page of a batch chain,
   * or run the chain's terminal branch when the cursor is exhausted.
   */
  private async continueOrFinishChain(
    type: HubSpotObjectType,
    state: SyncState,
    pageLength: number,
    nextAfter: string | null
  ): Promise<void> {
    if (nextAfter) {
      await this.set(`sync_state_${type}`, {
        after: nextAfter,
        batchNumber: state.batchNumber + 1,
        itemsProcessed: state.itemsProcessed + pageLength,
        initialSync: state.initialSync,
      } satisfies SyncState);

      const nextBatch = await this.callback(this.syncBatch, type);
      await this.runTask(nextBatch);
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
        await this.markSyncTypeComplete(type);
      }
      await this.clear(`sync_state_${type}`);
    }
  }

  /**
   * Mark one of the five independent initial-sync chains (contacts,
   * companies, deals, notes, tasks) as finished, and signal
   * `integrations.channelSyncCompleted` for the shared channel once all
   * five have finished.
   *
   * All five chains are started together from onChannelEnabled under this
   * connector's single channel and then run concurrently as independent
   * runTask chains, each with its own pagination. Completion of any *one*
   * chain is not sufficient signal that the connection's initial sync is
   * done — without waiting for all five, the platform's "Syncing…"
   * indicator would clear (and the stuck-sync watchdog would stop tracking
   * the connection) while the other chains are still backfilling. The
   * pending-set read-modify-write is guarded by a short-lived lock because
   * two chains can legitimately finish around the same time, and a naive
   * get+filter+set would race and could drop an update — see "Locks" in
   * TOOLS_GUIDE.md.
   *
   * Throws if the lock can never be acquired (rather than silently giving
   * up) so the caller's terminal branch does NOT clear `sync_state_*` for
   * this chain — leaving it in place lets a future retry of this batch
   * actually record the completion.
   */
  private async markSyncTypeComplete(type: HubSpotObjectType): Promise<void> {
    const lockKey = "initial_sync_pending_lock";
    const maxAttempts = 10;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      if (await this.tools.store.acquireLock(lockKey, 10_000)) {
        let allComplete = false;
        try {
          const pending = await this.get<string[]>("initial_sync_pending");
          if (pending === null) {
            // Never initialized (or a concurrent completion already
            // cleared it). We can't safely tell how many of the other
            // chains are still outstanding, so skip signaling rather than
            // risk firing channelSyncCompleted while they're still
            // backfilling.
            return;
          }
          const remaining = pending.filter((t) => t !== type);
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
        // for contention with the other chains.
        if (allComplete) {
          await this.tools.integrations.channelSyncCompleted(CHANNEL_ID);
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
      `HubSpot: failed to acquire initial_sync_pending_lock after ${maxAttempts} attempts ` +
        `while completing "${type}" sync`
    );
  }

  // ---- Incremental sync (poll) ----

  /**
   * Register the recurring change poll. `scheduleRecurring` is a keyed
   * singleton the platform re-arms every interval, so re-registering on
   * every enable (auto-enable, recovery) is safe and never stacks chains.
   */
  private async schedulePoll(): Promise<void> {
    const callback = await this.callback(this.pollChanges);
    await this.scheduleRecurring(POLL_TASK_KEY, callback, {
      intervalMs: POLL_INTERVAL_MS,
    });
  }

  /**
   * Poll each object type's recently modified items via the CRM search
   * API and upsert them. Each type advances an independent high-water
   * mark, so a partially consumed backlog resumes where it left off.
   */
  private async pollChanges(): Promise<void> {
    const enabled = await this.get<boolean>("sync_enabled");
    if (!enabled) return;

    const api = await this.getAPI();
    for (const type of ALL_SYNC_TYPES) {
      await this.pollType(api, type);
    }
  }

  private async pollType(
    api: HubSpotAPI,
    type: HubSpotObjectType
  ): Promise<void> {
    const pollStart = new Date();
    const sinceIso = await this.get<string>(`poll_since_${type}`);
    const since = sinceIso
      ? new Date(sinceIso)
      : new Date(pollStart.getTime() - 2 * POLL_INTERVAL_MS);

    let after: string | null = null;
    let highWater: Date | null = null;
    let sawAnyPage = false;

    for (let pageNum = 0; pageNum < MAX_POLL_PAGES; pageNum++) {
      const page = await api.searchModifiedSince(type, {
        since,
        after,
        limit: PAGE_SIZE,
        properties: OBJECT_PROPERTIES[type],
      });
      sawAnyPage = true;

      if (type === "notes" || type === "tasks") {
        await this.pollEngagements(api, type, page.results);
      } else {
        for (const record of page.results) {
          const link = await this.convertRecordToLink(api, type, record, false);
          await this.tools.integrations.saveLink(link);
        }
      }

      for (const item of page.results) {
        const modified = item.properties[LAST_MODIFIED_PROPERTY[type]];
        const ts = modified ? new Date(modified) : null;
        if (ts && !Number.isNaN(ts.getTime())) {
          if (!highWater || ts > highWater) highWater = ts;
        }
      }

      after = page.paging?.next?.after ?? null;
      if (!after) break;
    }

    // Advance the high-water mark, but never closer to "now" than the
    // search-index lag buffer (re-upserting the buffer window is cheap;
    // missing an index-lagged write is not). With results, resume just
    // past the newest item seen so a capped backlog continues next poll.
    const lagFloor = new Date(pollStart.getTime() - SEARCH_INDEX_LAG_MS);
    let nextSince: Date;
    if (highWater) {
      nextSince = new Date(
        Math.min(highWater.getTime() + 1, lagFloor.getTime())
      );
    } else if (sawAnyPage) {
      nextSince = lagFloor;
    } else {
      return;
    }
    if (nextSince > since) {
      await this.set(`poll_since_${type}`, nextSince.toISOString());
    }
  }

  /**
   * The search API doesn't return associations, so polled engagements are
   * re-fetched individually with their associated record ids before being
   * saved onto their parents' threads.
   */
  private async pollEngagements(
    api: HubSpotAPI,
    type: HubSpotEngagementType,
    engagements: HubSpotObject[]
  ): Promise<void> {
    const withAssociations: HubSpotObject[] = [];
    for (const engagement of engagements) {
      try {
        withAssociations.push(
          await api.getObject(type, engagement.id, OBJECT_PROPERTIES[type], [
            ...RECORD_TYPES,
          ])
        );
      } catch (error) {
        if (isNotFound(error)) continue; // deleted between search and fetch
        throw error;
      }
    }
    await this.saveEngagementsOnParents(api, type, withAssociations, false);
  }

  // ---- Engagements → notes on parent threads ----

  /**
   * Save note/task engagements as notes on each associated record's
   * thread. Parent records are batch-read per page so the upserted links
   * carry real titles and fields — an engagement's association only holds
   * ids, and upserting a bare id-only link would create an untitled
   * thread whenever the parent hasn't been imported yet. Parents deleted
   * upstream (absent from the batch read) are skipped.
   */
  private async saveEngagementsOnParents(
    api: HubSpotAPI,
    type: HubSpotEngagementType,
    engagements: HubSpotObject[],
    initialSync: boolean
  ): Promise<void> {
    // Collect unique parent ids per record type across the page.
    const parentIds: Record<HubSpotRecordType, Set<string>> = {
      contacts: new Set(),
      companies: new Set(),
      deals: new Set(),
    };
    for (const engagement of engagements) {
      for (const recordType of RECORD_TYPES) {
        for (const assoc of engagement.associations?.[recordType]?.results ??
          []) {
          parentIds[recordType].add(assoc.id);
        }
      }
    }

    // Batch-read each type's parents (100 per call — one page's worth).
    const parents: Record<HubSpotRecordType, Map<string, HubSpotObject>> = {
      contacts: new Map(),
      companies: new Map(),
      deals: new Map(),
    };
    for (const recordType of RECORD_TYPES) {
      const ids = [...parentIds[recordType]];
      for (let i = 0; i < ids.length; i += 100) {
        const batch = await api.batchReadObjects(
          recordType,
          ids.slice(i, i + 100),
          OBJECT_PROPERTIES[recordType]
        );
        for (const record of batch) parents[recordType].set(record.id, record);
      }
    }

    for (const engagement of engagements) {
      const hasAssociations = RECORD_TYPES.some(
        (recordType) =>
          (engagement.associations?.[recordType]?.results ?? []).length > 0
      );

      // A task with no record associations is a top-level to-do in
      // HubSpot's Tasks queue — sync it as its own thread. (A note without
      // associations has no record to give it context; skip those.)
      if (!hasAssociations) {
        if (type === "tasks") {
          const link = await this.convertTaskToLink(api, engagement, initialSync);
          await this.tools.integrations.saveLink(link);
        }
        continue;
      }

      const note = await this.buildEngagementNote(type, engagement);
      if (!note) continue;

      for (const recordType of RECORD_TYPES) {
        for (const assoc of engagement.associations?.[recordType]?.results ??
          []) {
          const parent = parents[recordType].get(assoc.id);
          if (!parent) continue;

          const link = await this.convertRecordToLink(
            api,
            recordType,
            parent,
            initialSync
          );
          link.notes = [note];
          await this.tools.integrations.saveLink(link);
        }
      }
    }
  }

  /**
   * Build the Plot note for a note/task engagement, or null for
   * engagements with no content. Note bodies are raw HubSpot HTML —
   * passed through with `contentType: "html"` for server-side markdown
   * conversion, and emitted verbatim so the write-back baseline
   * (onNoteCreated/onNoteUpdated `externalContent`) matches exactly.
   */
  private async buildEngagementNote(
    type: HubSpotEngagementType,
    engagement: HubSpotObject
  ): Promise<NonNullable<NewLinkWithNotes["notes"]>[number] | null> {
    const p = engagement.properties;
    const author = await this.resolveUserAuthor(p.hs_created_by_user_id);

    if (type === "notes") {
      const body = p.hs_note_body;
      if (!body) return null;
      return {
        key: `note-${engagement.id}`,
        content: body,
        contentType: "html" as const,
        created: new Date(p.hs_timestamp ?? engagement.createdAt),
        author,
      } as NonNullable<NewLinkWithNotes["notes"]>[number];
    }

    const subject = p.hs_task_subject || "Untitled Task";
    const completed = p.hs_task_status === "COMPLETED";

    // The task's to-do state rides on note tags, not text: the assignee
    // holds Tag.Todo (so it lands on their to-do list) and completed
    // tasks carry Tag.Done (rendered checked-off). Both keys are always
    // set explicitly — an empty actor list REMOVES the tag on re-sync, so
    // a task reopened or reassigned in HubSpot clears the stale state in
    // Plot (omitting a key would leave it untouched).
    const assignee = await this.resolveOwnerContact(p.hubspot_owner_id);
    const tags: NewTags = {
      [Tag.Todo]: assignee ? [assignee] : [],
      [Tag.Done]: [],
    };
    if (completed) {
      // HubSpot records no "completed by" — attribute to the assignee,
      // else the creator, else the connecting user.
      const completer =
        assignee ?? author ?? (await this.connectionOwnerActor());
      if (completer) tags[Tag.Done] = [completer];
    }

    // For tasks, hs_timestamp is the due date — use createdAt for the
    // note's timestamp instead.
    const content =
      `<p><strong>${escapeHtml(subject)}</strong></p>` + (p.hs_task_body ?? "");
    return {
      key: `task-${engagement.id}`,
      content,
      contentType: "html" as const,
      created: new Date(engagement.createdAt),
      author,
      tags,
    } as NonNullable<NewLinkWithNotes["notes"]>[number];
  }

  /**
   * Convert a standalone task (no record associations) into its own
   * thread — a top-level to-do from HubSpot's Tasks queue. Statuses
   * mirror `hs_task_status` verbatim (see TASK_STATUSES), so status
   * write-back needs no translation.
   */
  private async convertTaskToLink(
    api: HubSpotAPI,
    task: HubSpotObject,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const hubId = await this.getHubId(api);
    const p = task.properties;
    const author = await this.resolveUserAuthor(p.hs_created_by_user_id);
    const assignee = await this.resolveOwnerContact(p.hubspot_owner_id);

    // hs_timestamp is the task's due date.
    const due = p.hs_timestamp ? new Date(p.hs_timestamp) : null;
    const preview =
      due && !Number.isNaN(due.getTime())
        ? `Due ${due.toISOString().slice(0, 10)}`
        : null;

    const body = p.hs_task_body;
    return {
      source: `hubspot:${hubId}:task:${task.id}`,
      type: "task",
      title: p.hs_task_subject || "Untitled Task",
      created: new Date(task.createdAt),
      status: p.hs_task_status ?? null,
      author,
      ...(assignee ? { assignee } : {}),
      channelId: CHANNEL_ID,
      meta: {
        hubspotObjectType: "tasks",
        hubspotRecordId: task.id,
        syncProvider: "hubspot",
        channelId: CHANNEL_ID,
      },
      // Tasks have no per-record page in the HubSpot app — link to the
      // portal's Tasks queue.
      sourceUrl: `https://app.hubspot.com/tasks/${hubId}`,
      preview,
      notes: body
        ? [
            {
              key: "description",
              content: body,
              contentType: "html" as const,
              created: new Date(task.createdAt),
              author,
            } as NonNullable<NewLinkWithNotes["notes"]>[number],
          ]
        : [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  // ---- Author Attribution ----

  /**
   * Load (and cache) the portal's owners as a lookup map indexed under
   * both `owner:<ownerId>` (the value of `hubspot_owner_id` properties)
   * and `user:<userId>` (the value of `hs_created_by_user_id`
   * properties). Each entry carries one canonical `accountId` so the same
   * person resolves to a single platform identity regardless of which id
   * space referenced them.
   */
  private async getOwnerMap(
    api: HubSpotAPI,
    refresh = false
  ): Promise<Record<string, OwnerEntry>> {
    if (!refresh) {
      const cached = await this.get<Record<string, OwnerEntry>>("owners_map");
      if (cached) return cached;
    }

    let owners: Awaited<ReturnType<HubSpotAPI["listAllOwners"]>> = [];
    try {
      owners = await api.listAllOwners();
    } catch (error) {
      // Missing scope or a transient failure — degrade to id-only
      // attribution rather than blocking the sync. Don't cache the miss.
      console.warn("Failed to list HubSpot owners:", error);
      return {};
    }

    const map: Record<string, OwnerEntry> = {};
    for (const owner of owners) {
      const entry: OwnerEntry = {
        name: [owner.firstName, owner.lastName].filter(Boolean).join(" "),
        email: owner.email ?? null,
        accountId:
          owner.userId != null ? `user:${owner.userId}` : `owner:${owner.id}`,
        ownerId: owner.id,
      };
      map[`owner:${owner.id}`] = entry;
      if (owner.userId != null) map[`user:${owner.userId}`] = entry;
    }
    if (owners.length) await this.set("owners_map", map);
    return map;
  }

  /**
   * Resolve a HubSpot id (in the `owner:`/`user:` key space) to a Plot
   * contact. Unknown ids trigger one owner-map refresh per execution
   * (a newly added teammate won't be in a stale cache), then degrade to
   * id-only attribution — the platform resolves a contact by accountId
   * even without an email.
   */
  private async resolveAuthor(key: string): Promise<NewContact | null> {
    const api = await this.getAPI();
    let map = await this.getOwnerMap(api);
    let entry = map[key];
    if (!entry && !this.ownersRefreshed) {
      this.ownersRefreshed = true;
      map = await this.getOwnerMap(api, true);
      entry = map[key];
    }
    if (entry) {
      return {
        name: entry.name,
        ...(entry.email ? { email: entry.email } : {}),
        source: { accountId: entry.accountId },
      };
    }
    return { name: "", source: { accountId: key } };
  }

  /**
   * Resolve a record's `hs_created_by_user_id` to its creator. Null when
   * the property is unset — records created by imports, forms, or
   * workflows have no human creator, and an explicit `null` documents
   * that (see "Authorship" in the connector guide).
   */
  private async resolveUserAuthor(
    userId: string | null | undefined
  ): Promise<NewContact | null> {
    if (!userId) return null;
    return this.resolveAuthor(`user:${userId}`);
  }

  /** Resolve a record's `hubspot_owner_id` to its assigned owner. */
  private async resolveOwnerContact(
    ownerId: string | null | undefined
  ): Promise<NewContact | null> {
    if (!ownerId) return null;
    return this.resolveAuthor(`owner:${ownerId}`);
  }

  // ---- Data Transformation ----

  private async convertRecordToLink(
    api: HubSpotAPI,
    type: HubSpotRecordType,
    record: HubSpotObject,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const hubId = await this.getHubId(api);
    const p = record.properties;
    // The author is the user who created the record in HubSpot — NOT the
    // person a contact record describes (the subject).
    const author = await this.resolveUserAuthor(p.hs_created_by_user_id);

    let title: string;
    let preview: string | null = null;
    let status: string | null = null;
    let assignee: NewContact | null = null;

    if (type === "contacts") {
      title = contactDisplayName(p);
      preview = [p.email, p.phone].filter(Boolean).join(" | ") || null;
    } else if (type === "companies") {
      title = p.name || p.domain || "Untitled Company";
      preview = p.domain || null;
    } else {
      title = p.dealname || "Untitled Deal";
      preview = formatDealAmount(p);
      status = p.dealstage ?? null;
      assignee = await this.resolveOwnerContact(p.hubspot_owner_id);
    }

    const linkType = OBJECT_TO_LINK_TYPE[type];
    return {
      source: `hubspot:${hubId}:${linkType}:${record.id}`,
      type: linkType,
      title,
      created: new Date(p.createdate ?? record.createdAt),
      status,
      author,
      ...(assignee ? { assignee } : {}),
      channelId: CHANNEL_ID,
      meta: {
        hubspotObjectType: type,
        hubspotRecordId: record.id,
        syncProvider: "hubspot",
        channelId: CHANNEL_ID,
      },
      sourceUrl: `https://app.hubspot.com/contacts/${hubId}/record/${RECORD_TYPE_IDS[type]}/${record.id}`,
      preview,
      notes: [],
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  // ---- Write-backs ----

  /**
   * Write back deal stage changes to HubSpot. The stage id alone is
   * ambiguous across pipelines, so the target stage's pipeline is looked
   * up and written alongside it (a stage change within one pipeline
   * writes the same pipeline id back — a no-op).
   */
  async onLinkUpdated(link: Link): Promise<void> {
    if (!link.status) return;

    const recordId = link.meta?.hubspotRecordId as string | undefined;
    if (!recordId) return;

    // Standalone-task threads: statuses are hs_task_status values
    // verbatim, so completing (or re-opening) the thread in Plot writes
    // the status straight back.
    if (link.type === "task") {
      const api = await this.getAPI();
      await api.updateObject("tasks", recordId, {
        hs_task_status: link.status,
      });
      return;
    }

    if (link.type !== "deal") return;

    const api = await this.getAPI();
    const properties: Record<string, string> = { dealstage: link.status };
    try {
      const pipelines = await api.listPipelines("deals");
      const pipeline = pipelines.find((pl) =>
        pl.stages.some((stage) => stage.id === link.status)
      );
      if (pipeline) properties.pipeline = pipeline.id;
    } catch (error) {
      // Stage → pipeline resolution is best-effort; within-pipeline stage
      // changes (the common case) succeed without it.
      console.warn("Failed to resolve HubSpot pipeline for stage:", error);
    }
    await api.updateObject("deals", recordId, properties);
  }

  /**
   * Write back a Plot note as a HubSpot note engagement on the record.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime can (a) key the
   * Plot note for future upserts and (b) hash the external representation
   * as the sync baseline. Sync-in ({@link buildEngagementNote}) emits
   * `hs_note_body` verbatim, so the baseline is the body HubSpot now
   * stores — taken from the create response.
   */
  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const recordId = thread.meta?.hubspotRecordId as string | undefined;
    const objectType = thread.meta?.hubspotObjectType as
      | HubSpotRecordType
      | undefined;
    if (!recordId || !objectType) return;

    const body = plainTextToHtml(markdownToPlainText(note.content ?? ""));
    const api = await this.getAPI();
    const created = await api.createNote(body, new Date(), objectType, recordId);
    if (!created?.id) return;

    return {
      key: `note-${created.id}`,
      externalContent: created.properties?.hs_note_body ?? body,
    };
  }

  /**
   * Push a local note change back to HubSpot. `note-<id>` keys write
   * their edited body back; `task-<id>` keys write their to-do state
   * back (see writeBackTaskNote).
   */
  async onNoteUpdated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const taskMatch = note.key?.match(/^task-(.+)$/);
    if (taskMatch) return this.writeBackTaskNote(taskMatch[1], note);

    if (!note.key?.startsWith("note-")) return;
    const recordId = thread.meta?.hubspotRecordId as string | undefined;
    if (!recordId) return;

    const noteId = note.key.slice("note-".length);
    const body = plainTextToHtml(markdownToPlainText(note.content ?? ""));
    const api = await this.getAPI();
    const updated = await api.updateObject("notes", noteId, {
      hs_note_body: body,
    });

    return {
      externalContent: updated.properties?.hs_note_body ?? body,
    };
  }

  /**
   * Write back to-do state changes on a record-scoped task note: checking
   * the note done in Plot completes the HubSpot task, un-checking it
   * reopens it, and reassigning the Todo tag moves the task to the new
   * owner. The current status is read first so reopening restores
   * NOT_STARTED without clobbering an IN_PROGRESS/WAITING/DEFERRED task
   * that was never completed, and so an unchanged state writes nothing.
   *
   * Content edits are NOT written back — the note folds hs_task_subject
   * and hs_task_body into one HTML block that can't be split apart
   * reliably, so the next sync-in restores HubSpot's version.
   */
  private async writeBackTaskNote(
    taskId: string,
    note: Note
  ): Promise<NoteWriteBackResult | void> {
    const api = await this.getAPI();
    let current;
    try {
      current = await api.getObject("tasks", taskId, [
        "hs_task_status",
        "hubspot_owner_id",
      ]);
    } catch (error) {
      if (isNotFound(error)) return; // deleted upstream
      throw error;
    }

    const properties: Record<string, string> = {};
    const wantDone = (note.tags?.[Tag.Done] ?? []).length > 0;
    const isDone = current.properties.hs_task_status === "COMPLETED";
    if (wantDone && !isDone) properties.hs_task_status = "COMPLETED";
    if (!wantDone && isDone) properties.hs_task_status = "NOT_STARTED";

    let deliveryError: NoteWriteBackResult["deliveryError"];
    const todoActors = note.tags?.[Tag.Todo] ?? [];
    if (todoActors.length > 0) {
      const accountId = note.tagActors?.[todoActors[0]]?.source?.accountId;
      const ownerId = accountId
        ? await this.ownerIdForAccountId(accountId)
        : null;
      if (!ownerId) {
        deliveryError = {
          code: "invalid_recipient",
          message: "Assignee is not a HubSpot user",
        };
      } else if (ownerId !== current.properties.hubspot_owner_id) {
        properties.hubspot_owner_id = ownerId;
      }
    }

    if (Object.keys(properties).length > 0) {
      await api.updateObject("tasks", taskId, properties);
    }
    if (deliveryError) return { deliveryError };
  }

  /** Map a tag actor's platform accountId back to a HubSpot owner id. */
  private async ownerIdForAccountId(accountId: string): Promise<string | null> {
    const api = await this.getAPI();
    let map = await this.getOwnerMap(api);
    let entry = map[accountId];
    if (!entry && !this.ownersRefreshed) {
      this.ownersRefreshed = true;
      map = await this.getOwnerMap(api, true);
      entry = map[accountId];
    }
    if (entry?.ownerId) return entry.ownerId;
    // owner:<id> account ids carry the owner id directly.
    const m = accountId.match(/^owner:(.+)$/);
    return m ? m[1] : null;
  }
}

// ---- Helpers ----

/**
 * Flatten a portal's deal pipelines into the channel's status list. Stage
 * ids are unique across pipelines, so every stage from every pipeline is
 * offered; labels are prefixed with the pipeline name when the portal has
 * more than one pipeline so same-named stages stay distinguishable.
 * Closed-won stages map to "done", closed-lost to "cancelled", and open
 * stages to "inProgress" (a deal sitting in any open stage is actively
 * being worked).
 */
export function buildDealStatuses(pipelines: HubSpotPipeline[]): Array<{
  status: string;
  label: string;
  icon: StatusIcon;
  done?: true;
}> {
  const sorted = [...pipelines].sort(
    (a, b) => a.displayOrder - b.displayOrder
  );
  const multiple = sorted.length > 1;
  return sorted.flatMap((pipeline) =>
    [...pipeline.stages]
      .sort((a, b) => a.displayOrder - b.displayOrder)
      .map((stage) => {
        const isClosed =
          stage.metadata?.isClosed === true ||
          stage.metadata?.isClosed === "true";
        const probability = Number(stage.metadata?.probability ?? NaN);
        const won = isClosed && probability === 1;
        const lost = isClosed && probability === 0;
        return {
          status: stage.id,
          label: multiple ? `${pipeline.label}: ${stage.label}` : stage.label,
          icon: (won ? "done" : lost ? "cancelled" : "inProgress") as StatusIcon,
          ...(isClosed ? { done: true as const } : {}),
        };
      })
  );
}

export default HubSpot;
