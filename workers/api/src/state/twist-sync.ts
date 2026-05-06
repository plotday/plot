import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { sql } from "kysely";

import { withDb } from "../db";
import type { ThreadTagChange, Bindings, TwistBatchMessage } from "../env";
import { createLogger } from "@plotday/worker-util";

// Debouncing configuration (compile-time constants)
const MIN_WAIT_MS = 500; // Minimum time to wait before processing (allows better batching)
const MIN_INTERVAL_MS = 500; // Minimum gap between queue messages
const MAX_JITTER_MS = 2000; // Random jitter to stagger concurrent alarms across DOs
const MAX_ITEMS_PER_BATCH = 12; // Maximum items per batch in queue messages
const MAX_BATCH_BYTES = 120_000; // Maximum batch size in bytes (128KB limit minus 8KB headroom)

interface TwistSyncState {
  lastNotifyTime: number;
  lastSyncTime: number;
  pendingAlarm: boolean;
}

interface TagChangeRow {
  thread_id: string | null;
  occurrence: string | null;
  tag_id: number | null;
  actor_id: string | null;
  change_type: string | null;
}

// Circuit breaker: if TwistSync fires this many consecutive alarms without
// finding any items to process, stop scheduling new alarms. SyncRecovery
// will re-trigger if genuine stale state appears later.
const MAX_CONSECUTIVE_EMPTY_ALARMS = 5;

export class TwistSync extends DurableObject<Bindings> {
  private twistInstanceId: string | null = null;
  private state: TwistSyncState;
  private lastFingerprint: string | null = null;
  private repeatCount: number = 0;
  private consecutiveEmptyAlarms: number = 0;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.state = {
      lastNotifyTime: 0,
      lastSyncTime: 0,
      pendingAlarm: false,
    };
  }

  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, undefined, {
      durable_object: "TwistSync",
      twist_instance_id: this.twistInstanceId,
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/notify" && request.method === "POST") {
      const body = await request.json<{ id: string }>();
      if (!body.id) {
        return new Response("Missing id", { status: 400 });
      }
      await this.notify(body.id);
      return new Response("OK", { status: 200 });
    }

    return new Response("Not found", { status: 404 });
  }

  /**
   * Called when the API receives a sync notification
   * Schedules an alarm based on debouncing rules
   */
  private async notify(twistInstanceId: string): Promise<void> {
    // Store twistInstanceId on first notify
    if (!this.twistInstanceId) {
      this.twistInstanceId = twistInstanceId;
      await this.ctx.storage.put("twistInstanceId", twistInstanceId);
    }

    const now = Date.now();
    this.state.lastNotifyTime = now;

    // Reset circuit breaker on fresh notification — a new notify() means
    // something changed externally and we should try processing again.
    this.consecutiveEmptyAlarms = 0;

    // If we have a pending alarm, let it handle the sync
    if (this.state.pendingAlarm) {
      return;
    }

    // Calculate when we should sync
    const timeSinceLastSync = now - this.state.lastSyncTime;
    let delayMs: number;

    if (timeSinceLastSync < MIN_INTERVAL_MS) {
      // If we synced recently, wait until MIN_INTERVAL_MS has passed
      delayMs = MIN_INTERVAL_MS - timeSinceLastSync;
    } else {
      // Otherwise, use MIN_WAIT_MS to allow batching
      delayMs = MIN_WAIT_MS;
    }

    // Add random jitter to prevent thundering herd when many TwistSync DOs
    // are notified simultaneously (e.g., change on a shared priority fans out
    // to all active twists). Without jitter, all DOs fire alarms within ~100ms
    // and hit the database with concurrent heavy queries that degrade from 36ms
    // to 28+ minutes under contention.
    delayMs += Math.floor(Math.random() * MAX_JITTER_MS);

    // Schedule the alarm
    this.state.pendingAlarm = true;
    await this.ctx.storage.setAlarm(now + delayMs);
  }

  /**
   * Called when the alarm fires
   * Gathers and queues updates for the twist
   */
  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "TwistSync",
      operation: "alarm",
    });

    this.state.pendingAlarm = false;

    // Circuit breaker: stop processing if too many consecutive alarms found no items.
    // This prevents runaway cost from feedback loops where triggers create stale
    // twist_instance_sync state but views correctly filter out self-writes.
    // Reset by a fresh notify() call (e.g., from SyncNotify for a real change).
    if (this.consecutiveEmptyAlarms >= MAX_CONSECUTIVE_EMPTY_ALARMS) {
      return;
    }

    // Get twistInstanceId from storage
    if (!this.twistInstanceId) {
      const storedId = await this.ctx.storage.get<string>("twistInstanceId");
      if (storedId) {
        this.twistInstanceId = storedId;
      } else {
        const error = new Error(
          "TwistSync DO has no stored twistInstanceId - notify() was never called"
        );
        logger.error(error.message);
        this.captureException(error);
        return;
      }
    }

    try {
      const now = Date.now();

      const twistInstanceId = this.twistInstanceId;
      await withDb(this.env, async (db) => {
      // Get the twist_instance with twist info
      const twistInstance = await db
        .selectFrom("twist_instance")
        .select([
          "twist_instance.twist_id",
          "twist_instance.archived_at",
          "twist_instance.suspended_at",
        ])
        .where("twist_instance.id", "=", twistInstanceId)
        .executeTakeFirstOrThrow();

      // Skip sync for archived twist_instances
      if (twistInstance.archived_at) {
        logger.info("Skipping sync for archived twist_instance", {
          twist_instance_id: twistInstanceId,
        });
        return;
      }

      // Skip sync for suspended twists (timestamps don't advance, enabling catch-up on resume)
      if (twistInstance.suspended_at) {
        logger.info("Skipping sync for suspended twist_instance", {
          twist_instance_id: twistInstanceId,
        });
        return;
      }

      // Fetch twist info separately
      const twist = await db
        .selectFrom("twist")
        .select(["version", "environment"])
        .where("id", "=", twistInstance.twist_id)
        .executeTakeFirst();
      if (!twist) {
        const error = new Error("No twist info found");
        logger.error(error.message, error, {
          twist_instance_id: twistInstanceId,
        });
        this.captureException(error);
        return;
      }
      // Read the safe horizon: anything with seq < horizonSeq is committed and
      // visible to our snapshot. This is the xmin of the current snapshot.
      const horizonResult = await sql<{ horizon: string }>`SELECT pg_snapshot_xmin(pg_current_snapshot())::text AS horizon`.execute(db);
      const horizonSeq = horizonResult.rows[0]?.horizon ?? "0";

      // Get sync seq cursors for all (entity, operation) pairs
      const syncInfos = await db
        .selectFrom("twist_instance_sync")
        .select(["entity", "operation"])
        .select(sql<string>`last_sync_seq::text`.as("last_sync_seq_text"))
        .where("twist_instance_id", "=", twistInstanceId)
        .execute();

      // Use the twist_instance's seq as the minimum cursor floor.
      // This ensures we don't send notifications for items that existed before
      // the twist was installed.
      const minSyncSeqText = await sql<{ seq: string }>`SELECT seq::text AS seq FROM twist_instance WHERE id = ${twistInstanceId}`.execute(db).then((r) => r.rows[0]?.seq ?? "0");

      // Returns a SQL expression (xid8) for the lower bound of the given entity/operation.
      // Uses GREATEST in PG so we take whichever is larger: the stored cursor or the
      // twist_instance floor seq.
      const getSyncSeqExpr = (entity: string, operation: string) => {
        const info = syncInfos.find(
          (s) => s.entity === entity && s.operation === operation
        );
        if (!info) return sql<string>`${minSyncSeqText}::xid8`;
        return sql<string>`GREATEST(${info.last_sync_seq_text}::xid8, ${minSyncSeqText}::xid8)`;
      };

      const viewNames = [
        "twist_instance_thread_update",
        "twist_instance_note_create",
        "twist_instance_note_update",
        "twist_instance_channel_link_create",
        "twist_instance_channel_link_update",
        "twist_instance_channel_note_create",
        "twist_instance_thread_read",
        "twist_instance_thread_schedule",
        "twist_instance_schedule_contact",
      ] as const;

      const results = await Promise.allSettled([
        // Query updated threads (for thread.updated callback)
        // Uses twist_instance_thread_update view which filters by created_by = twist_id
        db
          .selectFrom("twist_instance_thread_update")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("thread", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query new notes (for note.created callback and mention handling)
        // Uses twist_instance_note_create view which filters by:
        // - twist is mentioned AND note was created on/after first mention
        db
          .selectFrom("twist_instance_note_create")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("note", "create"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query updated notes (for notes the twist created)
        // Uses twist_instance_note_update view which filters by created_by = twist_id
        db
          .selectFrom("twist_instance_note_update")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("note", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query new links from connected source channels (for onLinkCreated callback)
        db
          .selectFrom("twist_instance_channel_link_create")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("channel_link", "create"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query updated links from connected source channels (for onLinkUpdated callback)
        db
          .selectFrom("twist_instance_channel_link_update")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("channel_link", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query new notes on threads with links from connected channels (for onLinkNoteCreated callback)
        db
          .selectFrom("twist_instance_channel_note_create")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("channel_note", "create"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
          .limit(100)
          .execute(),

        // Query thread read status changes (for onThreadRead callback)
        db
          .selectFrom("twist_instance_thread_read")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("thread_read", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("thread_id", "asc")
          .limit(100)
          .execute(),

        // Query thread schedule changes (for onThreadToDo callback)
        db
          .selectFrom("twist_instance_thread_schedule")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("thread_schedule", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("schedule_id", "asc")
          .limit(100)
          .execute(),

        // Query schedule contact changes (for onScheduleContactUpdated callback)
        db
          .selectFrom("twist_instance_schedule_contact")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("schedule_contact", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("schedule_contact_id", "asc")
          .limit(100)
          .execute(),
      ]);

      // Extract successful results, defaulting to [] for failures
      const extractResult = <T>(result: PromiseSettledResult<T[]>, index: number): T[] => {
        if (result.status === "fulfilled") {
          return result.value;
        }
        const error = result.reason;
        logger.error(`Failed to query ${viewNames[index]}`, error as Error, {
          twist_instance_id: twistInstanceId!,
          view: viewNames[index],
        });
        this.captureException(error as Error, {
          view: viewNames[index],
        });
        return [];
      };

      const updatedActivities = extractResult(results[0], 0);
      const newNotes = extractResult(results[1], 1);
      const updatedNotes = extractResult(results[2], 2);
      const channelNewLinks = extractResult(results[3], 3);
      const channelUpdatedLinks = extractResult(results[4], 4);
      const channelNewNotes = extractResult(results[5], 5);
      const threadReads = extractResult(results[6], 6);
      const threadSchedules = extractResult(results[7], 7);
      const scheduleContacts = extractResult(results[8], 8);

      // Query tag changes for the thread update seq range
      // This provides tagsAdded/tagsRemoved data for the thread.updated callback
      let activityTagChanges: ThreadTagChange[] = [];
      try {
        const tagChanges: TagChangeRow[] = await db
          .selectFrom("twist_instance_thread_tag_change")
          .select(["thread_id", "occurrence", "tag_id", "actor_id", "change_type"])
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("thread", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .execute();

        // Transform tag changes into the expected format, filtering out any with null required fields
        activityTagChanges = tagChanges
          .filter(
            (tc) =>
              tc.thread_id !== null &&
              tc.tag_id !== null &&
              tc.actor_id !== null &&
              tc.change_type !== null
          )
          .map((tc) => ({
            threadId: tc.thread_id!,
            occurrence: tc.occurrence,
            tagId: tc.tag_id!,
            actorId: tc.actor_id!,
            changeType: tc.change_type as "added" | "removed",
          }));
      } catch (error) {
        logger.error("Failed to query twist_instance_activity_tag_change", error as Error, {
          twist_instance_id: twistInstanceId,
          view: "twist_instance_thread_tag_change",
        });
        this.captureException(error as Error, {
          view: "twist_instance_thread_tag_change",
        });
      }

      // Build size-aware batches to stay under Cloudflare's 128KB queue message limit.
      // Items are added sequentially (all newNotes, then updatedNotes, then updatedActivities, etc.).
      // The consumer processes each array independently, so co-location of items from different
      // arrays in the same batch is not required.
      type TaggedItem =
        | { array: "newNotes"; item: (typeof newNotes)[number]; size: number }
        | { array: "updatedNotes"; item: (typeof updatedNotes)[number]; size: number }
        | { array: "updatedActivities"; item: (typeof updatedActivities)[number]; size: number }
        | { array: "channelNewLinks"; item: (typeof channelNewLinks)[number]; size: number }
        | { array: "channelUpdatedLinks"; item: (typeof channelUpdatedLinks)[number]; size: number }
        | { array: "channelNewNotes"; item: (typeof channelNewNotes)[number]; size: number }
        | { array: "threadReads"; item: (typeof threadReads)[number]; size: number }
        | { array: "threadSchedules"; item: (typeof threadSchedules)[number]; size: number }
        | { array: "scheduleContacts"; item: (typeof scheduleContacts)[number]; size: number };

      let taggedItems: TaggedItem[] = [
        ...newNotes.map((item) => ({ array: "newNotes" as const, item, size: JSON.stringify(item).length })),
        ...updatedNotes.map((item) => ({ array: "updatedNotes" as const, item, size: JSON.stringify(item).length })),
        ...updatedActivities.map((item) => ({ array: "updatedActivities" as const, item, size: JSON.stringify(item).length })),
        ...channelNewLinks.map((item) => ({ array: "channelNewLinks" as const, item, size: JSON.stringify(item).length })),
        ...channelUpdatedLinks.map((item) => ({ array: "channelUpdatedLinks" as const, item, size: JSON.stringify(item).length })),
        ...channelNewNotes.map((item) => ({ array: "channelNewNotes" as const, item, size: JSON.stringify(item).length })),
        ...threadReads.map((item) => ({ array: "threadReads" as const, item, size: JSON.stringify(item).length })),
        ...threadSchedules.map((item) => ({ array: "threadSchedules" as const, item, size: JSON.stringify(item).length })),
        ...scheduleContacts.map((item) => ({ array: "scheduleContacts" as const, item, size: JSON.stringify(item).length })),
      ];

      // Loop detection: if we keep fetching the same items, skip processing to break the loop
      const itemFingerprint = taggedItems.length > 0
        ? taggedItems.map((t) => `${t.array}:${(t.item as any).id}`).sort().join(",")
        : "";
      if (itemFingerprint && itemFingerprint === this.lastFingerprint) {
        this.repeatCount++;
        if (this.repeatCount >= 3) {
          logger.warn("TwistSync loop detected: same items fetched 3+ consecutive times, skipping", {
            twist_instance_id: twistInstanceId,
            repeat_count: this.repeatCount,
            item_count: taggedItems.length,
          });
          // Clear items so we skip batch sending but still advance cursors below
          taggedItems.length = 0;
        }
      } else {
        this.repeatCount = 0;
      }
      this.lastFingerprint = itemFingerprint;

      const batches: TaggedItem[][] = [];
      let currentBatch: TaggedItem[] = [];
      let currentBatchSize = 0;

      for (const tagged of taggedItems) {
        // Start a new batch if adding this item would exceed limits (but always allow at least 1 item)
        if (
          currentBatch.length > 0 &&
          (currentBatchSize + tagged.size > MAX_BATCH_BYTES || currentBatch.length >= MAX_ITEMS_PER_BATCH)
        ) {
          batches.push(currentBatch);
          currentBatch = [];
          currentBatchSize = 0;
        }
        currentBatch.push(tagged);
        currentBatchSize += tagged.size;
      }
      if (currentBatch.length > 0) {
        batches.push(currentBatch);
      }

      // Send queue messages BEFORE updating sync timestamps
      // This ensures twist callbacks are always delivered even if timestamp updates fail
      // (transient PostgREST 500s). If timestamps fail to advance, the next alarm will
      // re-fetch the same items, causing duplicate but harmless callbacks.
      for (const batch of batches) {
        const batchNewNotes = batch.filter((t) => t.array === "newNotes").map((t) => t.item);
        const batchUpdatedNotes = batch.filter((t) => t.array === "updatedNotes").map((t) => t.item);
        const batchUpdatedActivities = batch.filter((t) => t.array === "updatedActivities").map((t) => t.item);
        const batchChannelNewLinks = batch.filter((t) => t.array === "channelNewLinks").map((t) => t.item);
        const batchChannelUpdatedLinks = batch.filter((t) => t.array === "channelUpdatedLinks").map((t) => t.item);
        const batchChannelNewNotes = batch.filter((t) => t.array === "channelNewNotes").map((t) => t.item);
        const batchThreadReads = batch.filter((t) => t.array === "threadReads").map((t) => t.item);
        const batchThreadSchedules = batch.filter((t) => t.array === "threadSchedules").map((t) => t.item);
        const batchScheduleContacts = batch.filter((t) => t.array === "scheduleContacts").map((t) => t.item);

        // Filter tag changes to only include those relevant to activities in this batch
        const batchActivityIds = new Set([
          ...batchUpdatedActivities.map((a) => a.id),
        ]);
        const batchTagChanges = activityTagChanges.filter((tc) =>
          batchActivityIds.has(tc.threadId)
        );

        // Note: Kysely returns Date objects for timestamps, but TwistBatchMessage uses
        // supabase view types with string timestamps. The queue serializes to JSON anyway,
        // so the data is equivalent.
        const message = {
          type: "twist_batch" as const,
          twistInstanceId: twistInstanceId,
          twistId: Number(twistInstance.twist_id),
          environment: twist.environment,
          version: twist.version,
          newNotes: batchNewNotes,
          updatedNotes: batchUpdatedNotes,
          updatedThreads: batchUpdatedActivities,
          threadTagChanges: batchTagChanges,
          channelNewLinks: batchChannelNewLinks,
          channelUpdatedLinks: batchChannelUpdatedLinks,
          channelNewNotes: batchChannelNewNotes,
          threadReads: batchThreadReads,
          threadSchedules: batchThreadSchedules,
          scheduleContacts: batchScheduleContacts,
          twistInstance: null, // TODO: Handle twist_instance config updates
        } as TwistBatchMessage;

        try {
          await this.env.UPDATES_QUEUE.send(message);
        } catch (error) {
          if (batch.length === 1) {
            // Single oversized item — log and skip so other batches can proceed
            logger.error("Queue send failed for oversized single item, skipping", error as Error, {
              twist_instance_id: twistInstanceId,
              item_array: batch[0].array,
              item_size: batch[0].size,
            });
            this.captureException(error as Error, {
              item_array: batch[0].array,
              item_size: batch[0].size,
            });
            continue;
          }
          throw error;
        }
      }

      // Advance seq cursors to the horizon for the 9 (entity, operation) pairs.
      // We batch these into a single multi-row UPSERT and skip pairs whose
      // cursor is already at or past horizonSeq with nothing to send — those
      // rows would have no-op'd anyway. Pairs that returned items, or whose
      // cursor is behind the horizon, are upserted so SyncRecovery doesn't see
      // perpetually stale rows and re-notify every 30s.
      const cursorEntities: ReadonlyArray<readonly [string, string, number]> = [
        ["thread", "update", updatedActivities.length],
        ["note", "create", newNotes.length],
        ["note", "update", updatedNotes.length],
        ["channel_link", "create", channelNewLinks.length],
        ["channel_link", "update", channelUpdatedLinks.length],
        ["channel_note", "create", channelNewNotes.length],
        ["thread_read", "update", threadReads.length],
        ["thread_schedule", "update", threadSchedules.length],
        ["schedule_contact", "update", scheduleContacts.length],
      ];

      const horizonSeqBig = BigInt(horizonSeq);
      const cursorRows = cursorEntities
        .filter(([entity, operation, itemCount]) => {
          if (itemCount > 0) return true;
          const info = syncInfos.find(
            (s) => s.entity === entity && s.operation === operation
          );
          // No existing row: nothing to advance — let triggers bootstrap when
          // real data arrives. Existing row already at/past horizon: no-op.
          if (!info) return false;
          try {
            return BigInt(info.last_sync_seq_text) < horizonSeqBig;
          } catch {
            return true;
          }
        })
        .map(([entity, operation]) => ({
          twist_instance_id: twistInstanceId,
          entity: sql`${entity}`,
          operation: sql`${operation}`,
          last_update_at: sql`now()`,
          last_update_seq: sql`${horizonSeq}::xid8`,
          last_sync_at: sql`now()`,
          last_sync_seq: sql`${horizonSeq}::xid8`,
        }));

      if (cursorRows.length > 0) {
        try {
          await db
            .insertInto("twist_instance_sync")
            .values(cursorRows as any)
            .onConflict((oc) =>
              oc.columns(["twist_instance_id", "entity", "operation"]).doUpdateSet({
                last_sync_at: sql`now()`,
                last_sync_seq: sql`GREATEST(twist_instance_sync.last_sync_seq, EXCLUDED.last_sync_seq)`,
              } as any)
            )
            .execute();
        } catch (error) {
          logger.error("Failed to advance twist_instance_sync cursors", error as Error, {
            twist_instance_id: twistInstanceId!,
            cursor_count: cursorRows.length,
          });
          this.captureException(error as Error, {
            sync_update: "batch cursor advance",
            cursor_count: cursorRows.length,
          });
        }
      }

      if (taggedItems.length > 0) {
        this.consecutiveEmptyAlarms = 0;
        logger.info("Twist sync completed and queued", {
          twist_instance_id: twistInstanceId,
          twist_id: String(twistInstance.twist_id),
          new_note_count: newNotes.length,
          updated_note_count: updatedNotes.length,
          updated_activity_count: updatedActivities.length,
          tag_change_count: activityTagChanges.length,
          channel_new_link_count: channelNewLinks.length,
          channel_updated_link_count: channelUpdatedLinks.length,
          channel_new_note_count: channelNewNotes.length,
          thread_read_count: threadReads.length,
          thread_schedule_count: threadSchedules.length,
          batch_count: batches.length,
        });
      } else {
        this.consecutiveEmptyAlarms++;
        if (this.consecutiveEmptyAlarms >= MAX_CONSECUTIVE_EMPTY_ALARMS) {
          logger.warn("TwistSync circuit breaker: too many consecutive empty alarms, stopping", {
            twist_instance_id: twistInstanceId,
            consecutive_empty: this.consecutiveEmptyAlarms,
          });
        }
      }

      this.state.lastSyncTime = now;
      }); // end withDb
    } catch (error) {
      logger.error("Error in TwistSync alarm", error as Error, {
        twist_instance_id: this.twistInstanceId,
      });
      this.captureException(error as Error);
    }
  }
}
