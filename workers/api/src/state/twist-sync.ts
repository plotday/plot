import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { sql } from "kysely";

import { withDb } from "../db";
import type { ActivityTagChange, Bindings, TwistBatchMessage } from "../env";
import { createLogger } from "@plotday/worker-util";

// Debouncing configuration (compile-time constants)
const MIN_WAIT_MS = 100; // Minimum time to wait before processing
const MIN_INTERVAL_MS = 100; // Minimum gap between queue messages
const MAX_JITTER_MS = 2000; // Random jitter to stagger concurrent alarms across DOs
const MAX_ITEMS_PER_BATCH = 12; // Maximum items per batch in queue messages
const MAX_BATCH_BYTES = 120_000; // Maximum batch size in bytes (128KB limit minus 8KB headroom)

interface TwistSyncState {
  lastNotifyTime: number;
  lastSyncTime: number;
  pendingAlarm: boolean;
}

interface TagChangeRow {
  activity_id: string | null;
  occurrence: string | null;
  tag_id: number | null;
  actor_id: string | null;
  change_type: string | null;
}

export class TwistSync extends DurableObject<Bindings> {
  private priorityTwistId: string | null = null;
  private state: TwistSyncState;

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
      priority_twist_id: this.priorityTwistId,
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
  private async notify(priorityTwistId: string): Promise<void> {
    // Store priorityTwistId on first notify
    if (!this.priorityTwistId) {
      this.priorityTwistId = priorityTwistId;
      await this.ctx.storage.put("priorityTwistId", priorityTwistId);
    }

    const now = Date.now();
    this.state.lastNotifyTime = now;

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

    // Get priorityTwistId from storage
    if (!this.priorityTwistId) {
      const storedId = await this.ctx.storage.get<string>("priorityTwistId");
      if (storedId) {
        this.priorityTwistId = storedId;
      } else {
        const error = new Error(
          "TwistSync DO has no stored priorityTwistId - notify() was never called"
        );
        logger.error(error.message);
        this.captureException(error);
        return;
      }
    }

    try {
      const now = Date.now();

      const priorityTwistId = this.priorityTwistId;
      await withDb(this.env, async (db) => {
      // Get the priority_twist with twist info
      // Read created_at as text to preserve full μs precision for sync cursors
      const priorityTwist = await db
        .selectFrom("priority_twist")
        .select([
          "priority_twist.priority_id",
          "priority_twist.twist_id",
          "priority_twist.archived_at",
          "priority_twist.suspended_at",
        ])
        .select(sql<string>`priority_twist.created_at::text`.as("created_at_text"))
        .where("priority_twist.id", "=", priorityTwistId)
        .executeTakeFirstOrThrow();

      // Skip sync for archived priority_twists
      if (priorityTwist.archived_at) {
        logger.info("Skipping sync for archived priority_twist", {
          priority_twist_id: priorityTwistId,
        });
        return;
      }

      // Skip sync for suspended twists (timestamps don't advance, enabling catch-up on resume)
      if (priorityTwist.suspended_at) {
        logger.info("Skipping sync for suspended priority_twist", {
          priority_twist_id: priorityTwistId,
        });
        return;
      }

      // Fetch twist info separately
      const twist = await db
        .selectFrom("twist")
        .select(["version", "environment"])
        .where("id", "=", priorityTwist.twist_id)
        .executeTakeFirst();
      if (!twist) {
        const error = new Error("No twist info found");
        logger.error(error.message, error, {
          priority_twist_id: priorityTwistId,
        });
        this.captureException(error);
        return;
      }

      // Get sync timestamps as text to preserve full μs precision
      const syncInfos = await db
        .selectFrom("priority_twist_sync")
        .select(["entity", "operation"])
        .select(sql<string>`last_sync_at::text`.as("last_sync_at_text"))
        .select(sql<string>`last_update_at::text`.as("last_update_at_text"))
        .where("priority_twist_id", "=", priorityTwistId)
        .execute();

      // Use the priority_twist's created_at (as text) as the minimum sync time
      // This ensures we don't send notifications for items that existed before the twist was added
      const minSyncAtText = priorityTwist.created_at_text;

      // Returns a SQL expression that evaluates to timestamptz with full precision
      // Uses GREATEST in PG to avoid JS Date comparison losing μs digits
      const getSyncAtExpr = (entity: string, operation: string) => {
        const info = syncInfos.find(
          (s) => s.entity === entity && s.operation === operation
        );
        const text = info?.last_sync_at_text;
        if (!text) return sql<Date>`${minSyncAtText}::timestamptz`;
        return sql<Date>`GREATEST(${text}::timestamptz, ${minSyncAtText}::timestamptz)`;
      };

      const viewNames = [
        "priority_twist_activity_create",
        "priority_twist_activity_update",
        "priority_twist_note_create",
        "priority_twist_note_update",
      ] as const;

      const results = await Promise.allSettled([
        // Query new activities (for activity.created callback)
        // Uses priority_twist_activity_create view which filters by created_by = twist_id
        db
          .selectFrom("priority_twist_activity_create")
          .selectAll()
          .select(sql<string>`MAX(created_at) OVER()::text`.as("_max_ts"))
          .where("priority_twist_id", "=", priorityTwistId)
          .where("created_at", ">", getSyncAtExpr("activity", "create"))
          .orderBy("created_at", "asc")
          .limit(100)
          .execute(),

        // Query updated activities (for activity.updated callback)
        // Uses priority_twist_activity_update view which filters by created_by = twist_id
        // Note: No created_at filter needed - twists get updates for activities they created,
        // even if they haven't been through a "create" sync (they don't get create callbacks for their own activities)
        db
          .selectFrom("priority_twist_activity_update")
          .selectAll()
          .select(sql<string>`MAX(updated_at) OVER()::text`.as("_max_ts"))
          .where("priority_twist_id", "=", priorityTwistId)
          .where("updated_at", ">", getSyncAtExpr("activity", "update"))
          .orderBy("updated_at", "asc")
          .limit(100)
          .execute(),

        // Query new notes (for note.created callback and mention handling)
        // Uses priority_twist_note_create view which filters by:
        // - twist created the activity, OR
        // - twist is mentioned AND note was created on/after first mention
        db
          .selectFrom("priority_twist_note_create")
          .selectAll()
          .select(sql<string>`MAX(created_at) OVER()::text`.as("_max_ts"))
          .where("priority_twist_id", "=", priorityTwistId)
          .where("created_at", ">", getSyncAtExpr("note", "create"))
          .orderBy("created_at", "asc")
          .limit(100)
          .execute(),

        // Query updated notes (for notes the twist created)
        // Uses priority_twist_note_update view which filters by created_by = twist_id
        db
          .selectFrom("priority_twist_note_update")
          .selectAll()
          .select(sql<string>`MAX(updated_at) OVER()::text`.as("_max_ts"))
          .where("priority_twist_id", "=", priorityTwistId)
          .where("updated_at", ">", getSyncAtExpr("note", "update"))
          .orderBy("updated_at", "asc")
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
          priority_twist_id: priorityTwistId!,
          view: viewNames[index],
        });
        this.captureException(error as Error, {
          view: viewNames[index],
        });
        return [];
      };

      const newActivities = extractResult(results[0], 0);
      const updatedActivities = extractResult(results[1], 1);
      const newNotes = extractResult(results[2], 2);
      const updatedNotes = extractResult(results[3], 3);

      // Extract max timestamps as PG-precision text strings from window functions
      // null if no items were returned for that query
      const activityCreateMaxTs: string | null =
        newActivities.length > 0 ? (newActivities[0] as any)._max_ts : null;
      const activityUpdateMaxTs: string | null =
        updatedActivities.length > 0 ? (updatedActivities[0] as any)._max_ts : null;
      const noteCreateMaxTs: string | null =
        newNotes.length > 0 ? (newNotes[0] as any)._max_ts : null;
      const noteUpdateMaxTs: string | null =
        updatedNotes.length > 0 ? (updatedNotes[0] as any)._max_ts : null;

      // Get the latest update timestamp from sync info as text for tag change upper bound
      // PG text representation (YYYY-MM-DD HH:MI:SS.ffffff+TZ) is lexicographically sortable
      const currentSyncTimestampText = syncInfos.length > 0
        ? syncInfos.reduce((max, info) =>
            info.last_update_at_text > max ? info.last_update_at_text : max,
          syncInfos[0].last_update_at_text)
        : null;

      // Query tag changes for the activity update time range
      // This provides tagsAdded/tagsRemoved data for the activity.updated callback
      // Use currentSyncTimestamp as upper bound to capture tag changes that occurred
      // after activity updates (since tag changes update activity_tag.updated_at, not activity.updated_at)
      let activityTagChanges: ActivityTagChange[] = [];
      try {
        const tagChanges: TagChangeRow[] = await db
          .selectFrom("priority_twist_activity_tag_change")
          .select(["activity_id", "occurrence", "tag_id", "actor_id", "change_type"])
          .where("priority_twist_id", "=", priorityTwistId)
          .where("updated_at", ">", getSyncAtExpr("activity", "update"))
          .where("updated_at", "<=", currentSyncTimestampText
            ? sql<Date>`${currentSyncTimestampText}::timestamptz`
            : sql<Date>`now()`)
          .execute();

        // Transform tag changes into the expected format, filtering out any with null required fields
        activityTagChanges = tagChanges
          .filter(
            (tc) =>
              tc.activity_id !== null &&
              tc.tag_id !== null &&
              tc.actor_id !== null &&
              tc.change_type !== null
          )
          .map((tc) => ({
            activityId: tc.activity_id!,
            occurrence: tc.occurrence,
            tagId: tc.tag_id!,
            actorId: tc.actor_id!,
            changeType: tc.change_type as "added" | "removed",
          }));
      } catch (error) {
        logger.error("Failed to query priority_twist_activity_tag_change", error as Error, {
          priority_twist_id: priorityTwistId,
          view: "priority_twist_activity_tag_change",
        });
        this.captureException(error as Error, {
          view: "priority_twist_activity_tag_change",
        });
      }

      // Strip internal _max_ts field from items before building queue messages
      const stripMaxTs = <T extends Record<string, any>>(items: T[]): T[] =>
        items.map(({ _max_ts, ...rest }) => rest as T);

      const cleanNewNotes = stripMaxTs(newNotes);
      const cleanUpdatedNotes = stripMaxTs(updatedNotes);
      const cleanNewActivities = stripMaxTs(newActivities);
      const cleanUpdatedActivities = stripMaxTs(updatedActivities);

      // Build size-aware batches to stay under Cloudflare's 128KB queue message limit.
      // Items are added sequentially (all newNotes, then updatedNotes, then newActivities,
      // then updatedActivities). The consumer processes each array independently, so
      // co-location of items from different arrays in the same batch is not required.
      type TaggedItem =
        | { array: "newNotes"; item: (typeof cleanNewNotes)[number]; size: number }
        | { array: "updatedNotes"; item: (typeof cleanUpdatedNotes)[number]; size: number }
        | { array: "newActivities"; item: (typeof cleanNewActivities)[number]; size: number }
        | { array: "updatedActivities"; item: (typeof cleanUpdatedActivities)[number]; size: number };

      const taggedItems: TaggedItem[] = [
        ...cleanNewNotes.map((item) => ({ array: "newNotes" as const, item, size: JSON.stringify(item).length })),
        ...cleanUpdatedNotes.map((item) => ({ array: "updatedNotes" as const, item, size: JSON.stringify(item).length })),
        ...cleanNewActivities.map((item) => ({ array: "newActivities" as const, item, size: JSON.stringify(item).length })),
        ...cleanUpdatedActivities.map((item) => ({ array: "updatedActivities" as const, item, size: JSON.stringify(item).length })),
      ];

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
        const batchNewActivities = batch.filter((t) => t.array === "newActivities").map((t) => t.item);
        const batchUpdatedActivities = batch.filter((t) => t.array === "updatedActivities").map((t) => t.item);

        // Filter tag changes to only include those relevant to activities in this batch
        // Include both new and updated activities for tag changes
        const batchActivityIds = new Set([
          ...batchNewActivities.map((a) => a.id),
          ...batchUpdatedActivities.map((a) => a.id),
        ]);
        const batchTagChanges = activityTagChanges.filter((tc) =>
          batchActivityIds.has(tc.activityId)
        );

        // Note: Kysely returns Date objects for timestamps, but TwistBatchMessage uses
        // supabase view types with string timestamps. The queue serializes to JSON anyway,
        // so the data is equivalent.
        const message = {
          type: "twist_batch" as const,
          priorityTwistId: priorityTwistId,
          twistId: Number(priorityTwist.twist_id),
          environment: twist.environment,
          version: twist.version,
          newNotes: batchNewNotes,
          updatedNotes: batchUpdatedNotes,
          newActivities: batchNewActivities,
          updatedActivities: batchUpdatedActivities,
          activityTagChanges: batchTagChanges,
          priorityTwist: null, // TODO: Handle priority_twist config updates
        } as TwistBatchMessage;

        try {
          await this.env.UPDATES_QUEUE.send(message);
        } catch (error) {
          if (batch.length === 1) {
            // Single oversized item — log and skip so other batches can proceed
            logger.error("Queue send failed for oversized single item, skipping", error as Error, {
              priority_twist_id: priorityTwistId,
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

      // UPSERT sync cursors with full-precision text timestamps cast to timestamptz
      // Only upsert when items were found (non-null max timestamp).
      // UPSERT (INSERT...ON CONFLICT) fixes Bug 1: the trigger only creates rows for the
      // twist that created the activity, but the create view returns items for other twists.
      // Text-based timestamps fix Bug 2: no JS Date round-trip means no μs precision loss.
      const syncUpdates: Array<{ name: string; promise: Promise<any> }> = [];

      if (activityCreateMaxTs) {
        syncUpdates.push({
          name: "activity create sync",
          promise: db.insertInto("priority_twist_sync")
            .values({
              priority_twist_id: priorityTwistId,
              entity: sql`'activity'`,
              operation: sql`'create'`,
              last_sync_at: sql`${activityCreateMaxTs}::timestamptz`,
              last_update_at: sql`${activityCreateMaxTs}::timestamptz`,
            })
            .onConflict((oc) =>
              oc.columns(["priority_twist_id", "entity", "operation"]).doUpdateSet({
                last_sync_at: sql`${activityCreateMaxTs}::timestamptz`,
              })
            )
            .execute(),
        });
      }

      if (activityUpdateMaxTs) {
        syncUpdates.push({
          name: "activity update sync",
          promise: db.insertInto("priority_twist_sync")
            .values({
              priority_twist_id: priorityTwistId,
              entity: sql`'activity'`,
              operation: sql`'update'`,
              last_sync_at: sql`${activityUpdateMaxTs}::timestamptz`,
              last_update_at: sql`${activityUpdateMaxTs}::timestamptz`,
            })
            .onConflict((oc) =>
              oc.columns(["priority_twist_id", "entity", "operation"]).doUpdateSet({
                last_sync_at: sql`${activityUpdateMaxTs}::timestamptz`,
              })
            )
            .execute(),
        });
      }

      if (noteCreateMaxTs) {
        syncUpdates.push({
          name: "note create sync",
          promise: db.insertInto("priority_twist_sync")
            .values({
              priority_twist_id: priorityTwistId,
              entity: sql`'note'`,
              operation: sql`'create'`,
              last_sync_at: sql`${noteCreateMaxTs}::timestamptz`,
              last_update_at: sql`${noteCreateMaxTs}::timestamptz`,
            })
            .onConflict((oc) =>
              oc.columns(["priority_twist_id", "entity", "operation"]).doUpdateSet({
                last_sync_at: sql`${noteCreateMaxTs}::timestamptz`,
              })
            )
            .execute(),
        });
      }

      if (noteUpdateMaxTs) {
        syncUpdates.push({
          name: "note update sync",
          promise: db.insertInto("priority_twist_sync")
            .values({
              priority_twist_id: priorityTwistId,
              entity: sql`'note'`,
              operation: sql`'update'`,
              last_sync_at: sql`${noteUpdateMaxTs}::timestamptz`,
              last_update_at: sql`${noteUpdateMaxTs}::timestamptz`,
            })
            .onConflict((oc) =>
              oc.columns(["priority_twist_id", "entity", "operation"]).doUpdateSet({
                last_sync_at: sql`${noteUpdateMaxTs}::timestamptz`,
              })
            )
            .execute(),
        });
      }

      const syncUpdateResults = await Promise.allSettled(
        syncUpdates.map((u) => u.promise)
      );

      // Log any failed sync timestamp updates
      for (let i = 0; i < syncUpdateResults.length; i++) {
        const result = syncUpdateResults[i];
        if (result.status === "rejected") {
          const error = result.reason;
          logger.error(`Failed to update ${syncUpdates[i].name}`, error as Error, {
            priority_twist_id: priorityTwistId!,
          });
          this.captureException(error as Error, {
            sync_update: syncUpdates[i].name,
          });
        }
      }

      if (taggedItems.length > 0) {
        logger.info("Twist sync completed and queued", {
          priority_twist_id: priorityTwistId,
          twist_id: String(priorityTwist.twist_id),
          new_note_count: newNotes.length,
          updated_note_count: updatedNotes.length,
          new_activity_count: newActivities.length,
          updated_activity_count: updatedActivities.length,
          tag_change_count: activityTagChanges.length,
          batch_count: batches.length,
        });
      }

      this.state.lastSyncTime = now;
      }); // end withDb
    } catch (error) {
      logger.error("Error in TwistSync alarm", error as Error, {
        priority_twist_id: this.priorityTwistId,
      });
      this.captureException(error as Error);
    }
  }
}
