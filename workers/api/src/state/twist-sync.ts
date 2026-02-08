import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { DbError, type SupabaseClient, createClient, safeQuery } from "@plotday/db";

import type { ActivityTagChange, Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";

// Debouncing configuration (compile-time constants)
const MIN_WAIT_MS = 100; // Minimum time to wait before processing
const MIN_INTERVAL_MS = 100; // Minimum gap between queue messages
const MAX_ITEMS_PER_BATCH = 12; // Maximum items per batch in queue messages

interface TwistSyncState {
  lastNotifyTime: number;
  lastSyncTime: number;
  pendingAlarm: boolean;
}

interface SyncInfo {
  entity: string;
  operation: string;
  last_sync_at: string;
  last_update_at: string;
}

interface TagChangeRow {
  activity_id: string | null;
  occurrence: string | null;
  tag_id: number | null;
  actor_id: string | null;
  change_type: string | null;
}

export class TwistSync extends DurableObject<Bindings> {
  private supabase: SupabaseClient;
  private priorityTwistId: string | null = null;
  private state: TwistSyncState;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    this.supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);
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

      // Get the priority_twist with twist info
      const priorityTwist = await safeQuery(
        this.supabase
          .from("priority_twist")
          .select(
            "priority_id, twist_id, created_at, archived_at, twist:twist_id(version, environment)"
          )
          .eq("id", this.priorityTwistId)
          .single(),
        { table: "priority_twist" }
      );

      // Skip sync for archived priority_twists
      if (priorityTwist.archived_at) {
        logger.info("Skipping sync for archived priority_twist", {
          priority_twist_id: this.priorityTwistId,
        });
        return;
      }

      // Extract twist info
      const twist = Array.isArray(priorityTwist.twist)
        ? priorityTwist.twist[0]
        : priorityTwist.twist;
      if (!twist) {
        const error = new Error("No twist info found");
        logger.error(error.message, error, {
          priority_twist_id: this.priorityTwistId,
        });
        this.captureException(error);
        return;
      }

      // Get sync timestamps for each operation type
      const syncInfos: SyncInfo[] = await safeQuery(
        this.supabase
          .from("priority_twist_sync")
          .select("entity, operation, last_sync_at, last_update_at")
          .eq("priority_twist_id", this.priorityTwistId),
        { table: "priority_twist_sync" }
      );

      // Use the priority_twist's created_at as the minimum sync time
      // This ensures we don't send notifications for items that existed before the twist was added
      const minSyncAt = priorityTwist.created_at;

      const getSyncAt = (entity: string, operation: string): string => {
        const info = syncInfos.find(
          (s) => s.entity === entity && s.operation === operation
        );
        // Use the later of: last_sync_at or the priority_twist's created_at
        const lastSyncAt = info?.last_sync_at;
        if (!lastSyncAt) {
          return minSyncAt;
        }
        return lastSyncAt > minSyncAt ? lastSyncAt : minSyncAt;
      };

      const noteCreateLastSyncAt = getSyncAt("note", "create");
      const noteUpdateLastSyncAt = getSyncAt("note", "update");
      const activityCreateLastSyncAt = getSyncAt("activity", "create");
      const activityUpdateLastSyncAt = getSyncAt("activity", "update");

      const viewNames = [
        "priority_twist_activity_create",
        "priority_twist_activity_update",
        "priority_twist_note_create",
        "priority_twist_note_update",
      ] as const;

      const results = await Promise.allSettled([
        // Query new activities (for activity.created callback)
        // Uses priority_twist_activity_create view which filters by created_by = twist_id
        safeQuery(
          this.supabase
            .from("priority_twist_activity_create")
            .select("*")
            .eq("priority_twist_id", this.priorityTwistId)
            .gt("created_at", activityCreateLastSyncAt),
          { table: "priority_twist_activity_create" }
        ),

        // Query updated activities (for activity.updated callback)
        // Uses priority_twist_activity_update view which filters by created_by = twist_id
        // Note: No created_at filter needed - twists get updates for activities they created,
        // even if they haven't been through a "create" sync (they don't get create callbacks for their own activities)
        safeQuery(
          this.supabase
            .from("priority_twist_activity_update")
            .select("*")
            .eq("priority_twist_id", this.priorityTwistId)
            .gt("updated_at", activityUpdateLastSyncAt),
          { table: "priority_twist_activity_update" }
        ),

        // Query new notes (for note.created callback and mention handling)
        // Uses priority_twist_note_create view which filters by:
        // - twist created the activity, OR
        // - twist is mentioned AND note was created on/after first mention
        safeQuery(
          this.supabase
            .from("priority_twist_note_create")
            .select("*")
            .eq("priority_twist_id", this.priorityTwistId)
            .gt("created_at", noteCreateLastSyncAt),
          { table: "priority_twist_note_create" }
        ),

        // Query updated notes (for notes the twist created)
        // Uses priority_twist_note_update view which filters by created_by = twist_id
        safeQuery(
          this.supabase
            .from("priority_twist_note_update")
            .select("*")
            .eq("priority_twist_id", this.priorityTwistId)
            .gt("updated_at", noteUpdateLastSyncAt),
          { table: "priority_twist_note_update" }
        ),
      ]);

      // Extract successful results, defaulting to [] for failures
      const extractResult = <T>(result: PromiseSettledResult<T[]>, index: number): T[] => {
        if (result.status === "fulfilled") {
          return result.value;
        }
        const error = result.reason;
        const dbContext = error instanceof DbError ? error.toLogContext() : {};
        logger.error(`Failed to query ${viewNames[index]}`, error as Error, {
          priority_twist_id: this.priorityTwistId!,
          view: viewNames[index],
          ...dbContext,
        });
        this.captureException(error as Error, {
          view: viewNames[index],
          ...dbContext,
        });
        return [];
      };

      const newActivities = extractResult(results[0], 0);
      const updatedActivities = extractResult(results[1], 1);
      const newNotes = extractResult(results[2], 2);
      const updatedNotes = extractResult(results[3], 3);

      // DEBUG: Log specific items being synced
      if (
        newNotes.length > 0 ||
        updatedNotes.length > 0 ||
        newActivities.length > 0 ||
        updatedActivities.length > 0
      ) {
        logger.info("[DEBUG] TwistSync items to queue", {
          priority_twist_id: this.priorityTwistId,
          noteCreateLastSyncAt,
          noteUpdateLastSyncAt,
          activityCreateLastSyncAt,
          activityUpdateLastSyncAt,
          newNoteIds: newNotes.map((n) => n.id).join(", "),
          newNoteActivityIds: newNotes.map((n) => n.activity_id).join(", "),
          updatedNoteIds: updatedNotes.map((n) => n.id).join(", "),
          updatedNoteActivityIds: updatedNotes
            .map((n) => n.activity_id)
            .join(", "),
          newActivityIds: newActivities.map((a) => a.id).join(", "),
          newActivityTitles: newActivities
            .map((a) => a.title?.substring(0, 30))
            .join(", "),
          newActivityCreatedAts: newActivities
            .map((a) => a.created_at)
            .join(", "),
          updatedActivityIds: updatedActivities.map((a) => a.id).join(", "),
          updatedActivityTitles: updatedActivities
            .map((a) => a.title?.substring(0, 30))
            .join(", "),
          updatedActivityCreatedAts: updatedActivities
            .map((a) => a.created_at)
            .join(", "),
        });
      }

      // Helper to get max timestamp from database-fetched items (or keep existing if none)
      const getMaxTimestamp = (
        items: any[],
        timestampField: "created_at" | "updated_at",
        fallback: string
      ): string => {
        if (items.length === 0) return fallback;

        const timestamps = items
          .map((item) => item[timestampField])
          .filter((ts): ts is string => ts !== null && ts !== undefined);

        if (timestamps.length === 0) return fallback;

        // All timestamps are from database, already in UTC
        return timestamps.reduce((max, ts) => (ts > max ? ts : max));
      };

      // Calculate sync timestamps from database values for each entity/operation
      const activityCreateSyncAt = getMaxTimestamp(
        newActivities,
        "created_at",
        activityCreateLastSyncAt
      );

      const activityUpdateSyncAt = getMaxTimestamp(
        updatedActivities,
        "updated_at",
        activityUpdateLastSyncAt
      );

      const noteCreateSyncAt = getMaxTimestamp(
        newNotes,
        "created_at",
        noteCreateLastSyncAt
      );

      const noteUpdateSyncAt = getMaxTimestamp(
        updatedNotes,
        "updated_at",
        noteUpdateLastSyncAt
      );

      // Get the latest timestamp from database (current sync point)
      // This represents the most recent change detected by database triggers
      const currentSyncTimestamp = syncInfos.reduce((max, info) => {
        return info.last_update_at > max ? info.last_update_at : max;
      }, syncInfos[0]?.last_update_at ?? new Date(0).toISOString());

      // Query tag changes for the activity update time range
      // This provides tagsAdded/tagsRemoved data for the activity.updated callback
      // Use currentSyncTimestamp as upper bound to capture tag changes that occurred
      // after activity updates (since tag changes update activity_tag.updated_at, not activity.updated_at)
      let activityTagChanges: ActivityTagChange[] = [];
      try {
        const tagChanges: TagChangeRow[] = await safeQuery(
          this.supabase
            .from("priority_twist_activity_tag_change")
            .select("activity_id, occurrence, tag_id, actor_id, change_type")
            .eq("priority_twist_id", this.priorityTwistId)
            .gt("updated_at", activityUpdateLastSyncAt)
            .lte("updated_at", currentSyncTimestamp),
          { table: "priority_twist_activity_tag_change" }
        );

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
        const dbContext = error instanceof DbError ? (error as DbError).toLogContext() : {};
        logger.error("Failed to query priority_twist_activity_tag_change", error as Error, {
          priority_twist_id: this.priorityTwistId,
          view: "priority_twist_activity_tag_change",
          ...dbContext,
        });
        this.captureException(error as Error, {
          view: "priority_twist_activity_tag_change",
          ...dbContext,
        });
      }

      // Update each entity/operation pair with its specific timestamp
      // This ensures each operation advances independently based on items actually processed
      // Using database timestamps avoids clock skew and timezone issues
      await Promise.all([
        safeQuery(
          this.supabase
            .from("priority_twist_sync")
            .update({ last_sync_at: activityCreateSyncAt })
            .eq("priority_twist_id", this.priorityTwistId)
            .eq("entity", "activity")
            .eq("operation", "create"),
          { table: "priority_twist_sync", operation: "update", description: "activity create sync" }
        ),
        safeQuery(
          this.supabase
            .from("priority_twist_sync")
            .update({ last_sync_at: activityUpdateSyncAt })
            .eq("priority_twist_id", this.priorityTwistId)
            .eq("entity", "activity")
            .eq("operation", "update"),
          { table: "priority_twist_sync", operation: "update", description: "activity update sync" }
        ),
        safeQuery(
          this.supabase
            .from("priority_twist_sync")
            .update({ last_sync_at: noteCreateSyncAt })
            .eq("priority_twist_id", this.priorityTwistId)
            .eq("entity", "note")
            .eq("operation", "create"),
          { table: "priority_twist_sync", operation: "update", description: "note create sync" }
        ),
        safeQuery(
          this.supabase
            .from("priority_twist_sync")
            .update({ last_sync_at: noteUpdateSyncAt })
            .eq("priority_twist_id", this.priorityTwistId)
            .eq("entity", "note")
            .eq("operation", "update"),
          { table: "priority_twist_sync", operation: "update", description: "note update sync" }
        ),
      ]);

      // Calculate the number of batches needed (based on max items across all arrays)
      const maxItems = Math.max(
        newNotes.length,
        updatedNotes.length,
        newActivities.length,
        updatedActivities.length
      );
      const batchCount = Math.ceil(maxItems / MAX_ITEMS_PER_BATCH);

      // Send batches of up to MAX_ITEMS_PER_BATCH items each
      for (let i = 0; i < batchCount; i++) {
        const start = i * MAX_ITEMS_PER_BATCH;
        const end = start + MAX_ITEMS_PER_BATCH;

        const batchNewNotes = newNotes.slice(start, end);
        const batchUpdatedNotes = updatedNotes.slice(start, end);
        const batchNewActivities = newActivities.slice(start, end);
        const batchUpdatedActivities = updatedActivities.slice(start, end);

        // Filter tag changes to only include those relevant to activities in this batch
        // Include both new and updated activities for tag changes
        const batchActivityIds = new Set([
          ...batchNewActivities.map((a) => a.id),
          ...batchUpdatedActivities.map((a) => a.id),
        ]);
        const batchTagChanges = activityTagChanges.filter((tc) =>
          batchActivityIds.has(tc.activityId)
        );

        if (
          batchNewNotes.length > 0 ||
          batchUpdatedNotes.length > 0 ||
          batchNewActivities.length > 0 ||
          batchUpdatedActivities.length > 0
        ) {
          await this.env.UPDATES_QUEUE.send({
            type: "twist_batch",
            priorityTwistId: this.priorityTwistId,
            twistId: priorityTwist.twist_id,
            environment: twist.environment,
            version: twist.version,
            newNotes: batchNewNotes,
            updatedNotes: batchUpdatedNotes,
            newActivities: batchNewActivities,
            updatedActivities: batchUpdatedActivities,
            activityTagChanges: batchTagChanges,
            priorityTwist: null, // TODO: Handle priority_twist config updates
          });
        }
      }

      if (maxItems > 0) {
        logger.info("Twist sync completed and queued", {
          priority_twist_id: this.priorityTwistId,
          twist_id: String(priorityTwist.twist_id),
          new_note_count: newNotes.length,
          updated_note_count: updatedNotes.length,
          new_activity_count: newActivities.length,
          updated_activity_count: updatedActivities.length,
          tag_change_count: activityTagChanges.length,
          batch_count: batchCount,
        });
      }

      this.state.lastSyncTime = now;
    } catch (error) {
      const dbContext = error instanceof DbError ? (error as DbError).toLogContext() : {};
      logger.error("Error in TwistSync alarm", error as Error, {
        priority_twist_id: this.priorityTwistId,
        ...dbContext,
      });
      this.captureException(error as Error, dbContext);
    }
  }
}
