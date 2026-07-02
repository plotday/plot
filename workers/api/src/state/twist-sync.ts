import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import { sql } from "kysely";

import {
  withDb,
  createDb,
  isLockContentionError,
  isTransientDbError,
} from "../db";
import type { ThreadTagChange, Bindings, TwistBatchMessage } from "../env";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import { processTwistBatch } from "../queue/updates";
import { transientErrorReason } from "../utils/transient-error";
import { TransientAlarmRetry, isTransientAlarmError } from "./alarm-retry";
import {
  utf8ByteLength,
  buildSizeAwareBatches,
  splitBatch,
} from "./twist-sync-batching";
import {
  selectCursorsToAdvance,
  type CursorEntityCount,
} from "./twist-sync-cursor";

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
  // Owning user of this twist_instance, cached for PostHog exception
  // attribution. The Flutter app identifies this user_id with their email/name
  // on login, so passing it as the captureException distinctId makes errors
  // resolve to a real person (email) instead of a random per-event UUID.
  // Immutable per twist_instance (see prevent_twist_instance_immutable_changes).
  private ownerId: string | null = null;
  private state: TwistSyncState;
  private lastFingerprint: string | null = null;
  private repeatCount: number = 0;
  private consecutiveEmptyAlarms: number = 0;
  private retry = new TransientAlarmRetry();

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
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.captureException(error, this.ownerId ?? undefined, {
      durable_object: "TwistSync",
      twist_instance_id: this.twistInstanceId,
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  /**
   * Emit a `push.transient` counter (NOT a captureException) for each
   * suppressed transient platform blip, so a SUSTAINED spike trips the
   * server-side volume alert (infra/posthog/alerts.tf) even though individual
   * occurrences self-heal via the retry ladder. Shares the event + `reason`
   * breakdown with PushNotify/UserSync/EmailNotify; `durable_object`
   * distinguishes this DO.
   */
  private captureTransientCounter(error: unknown) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    postHog.capture({
      distinctId: "system",
      event: "push.transient",
      properties: {
        durable_object: "TwistSync",
        reason: transientErrorReason(error),
      },
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  // Process a single oversized batch message inline, bypassing the queue.
  // Reached only when one sync item exceeds Cloudflare Queues' 128KB limit and
  // therefore can't be enqueued. Runs in the background (caller passes this to
  // ctx.waitUntil), so it must not throw — it owns its own DB connection and
  // PostHog client and reports unexpected failures itself.
  private async dispatchInline(message: TwistBatchMessage): Promise<void> {
    const db = createDb(this.env);
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
      before_send: exceptionFingerprintBeforeSend,
    });
    try {
      await processTwistBatch(
        message,
        this.env,
        // DurableObjectState exposes the waitUntil/exports surface the twist
        // factory actually uses; processTwistBatch's ExecutionContext param is
        // satisfied at runtime (see twistFactory's ctx-narrowing in factory.ts).
        this.ctx as unknown as ExecutionContext,
        db,
        "UPDATES_QUEUE-inline",
        postHog
      );
    } catch (error) {
      this.captureException(error as Error, {
        context: "inline-oversized-dispatch",
      });
    } finally {
      await db.destroy();
      await postHog.shutdown();
    }
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
    // Fresh activity also restores the transient-retry budget.
    this.retry.reset();

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

    // Restore the cached owning user for exception attribution. A re-hydrated
    // DO loses the in-memory field; reloading it here means even an exception
    // thrown by this run's first DB query (before the twist_instance read
    // below) is still attributed to the right user.
    if (!this.ownerId) {
      this.ownerId = (await this.ctx.storage.get<string>("ownerId")) ?? null;
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
          "twist_instance.owner_id",
          "twist_instance.archived_at",
          "twist_instance.suspended_at",
        ])
        .where("twist_instance.id", "=", twistInstanceId)
        .executeTakeFirst();

      // The twist_instance is gone — hard-deleted while this DO still had a
      // scheduled alarm (an abandoned draft is hard-deleted; an uninstall
      // cascades the row away). There is nothing to sync, so stop quietly.
      // This is an expected lifecycle race, not a fault: previously
      // executeTakeFirstOrThrow() surfaced it as a captured Kysely
      // "no result" NoResultError (PostHog 019c4dff), inflating the error
      // count with noise the retry layer can never fix (the row won't return).
      if (!twistInstance) {
        logger.info("TwistSync twist_instance no longer exists; stopping sync", {
          twist_instance_id: twistInstanceId,
        });
        return;
      }

      // Cache the owning user for PostHog exception attribution (immutable per
      // twist_instance). Persist so a later cold-start alarm can attribute an
      // error from its very first query without re-reading this row.
      if (this.ownerId !== twistInstance.owner_id) {
        this.ownerId = twistInstance.owner_id;
        await this.ctx.storage.put("ownerId", twistInstance.owner_id);
      }

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
        "twist_instance_note_reaction_change",
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

        // Query per-user thread_state changes (for onThreadToDo callback)
        db
          .selectFrom("twist_instance_thread_schedule")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("thread_schedule", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("thread_id", "asc")
          .orderBy("user_id", "asc")
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

        // Query note reaction changes (for onNoteReactionChanged callback).
        // Routed per-actor — only this twist_instance_id's rows come back,
        // and only when the reactor is the owner of this connector instance.
        db
          .selectFrom("twist_instance_note_reaction_change")
          .selectAll()
          .where("twist_instance_id", "=", twistInstanceId)
          .where("seq", ">=", getSyncSeqExpr("note_reaction", "update"))
          .where(sql<boolean>`seq < ${horizonSeq}::xid8`)
          .orderBy("seq", "asc")
          .orderBy("id", "asc")
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

      // The twist_instance_thread_update view UNION-ALLs thread changes with
      // thread_tag changes, so a thread can appear twice in one window when
      // both seqs land in [cursor, horizon). Keep the row with the larger
      // seq. Postgres types `id` and `seq` as nullable through UNION ALL,
      // but both halves always select non-null values from indexed columns.
      const rawUpdatedActivities = extractResult(results[0], 0);
      const dedupedActivities = new Map<string, (typeof rawUpdatedActivities)[number]>();
      for (const row of rawUpdatedActivities) {
        if (row.id == null || row.seq == null) continue;
        const existing = dedupedActivities.get(row.id);
        if (!existing || BigInt(row.seq as string) > BigInt(existing.seq as string)) {
          dedupedActivities.set(row.id, row);
        }
      }
      const updatedActivities = Array.from(dedupedActivities.values());
      const newNotes = extractResult(results[1], 1);
      const updatedNotes = extractResult(results[2], 2);
      const channelNewLinks = extractResult(results[3], 3);
      const channelUpdatedLinks = extractResult(results[4], 4);
      const channelNewNotes = extractResult(results[5], 5);
      const threadReads = extractResult(results[6], 6);
      const threadSchedules = extractResult(results[7], 7);
      const scheduleContacts = extractResult(results[8], 8);
      const noteReactions = extractResult(results[9], 9);

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
        | { array: "scheduleContacts"; item: (typeof scheduleContacts)[number]; size: number }
        | { array: "noteReactions"; item: (typeof noteReactions)[number]; size: number };

      let taggedItems: TaggedItem[] = [
        ...newNotes.map((item) => ({ array: "newNotes" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...updatedNotes.map((item) => ({ array: "updatedNotes" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...updatedActivities.map((item) => ({ array: "updatedActivities" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...channelNewLinks.map((item) => ({ array: "channelNewLinks" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...channelUpdatedLinks.map((item) => ({ array: "channelUpdatedLinks" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...channelNewNotes.map((item) => ({ array: "channelNewNotes" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...threadReads.map((item) => ({ array: "threadReads" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...threadSchedules.map((item) => ({ array: "threadSchedules" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...scheduleContacts.map((item) => ({ array: "scheduleContacts" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
        ...noteReactions.map((item) => ({ array: "noteReactions" as const, item, size: utf8ByteLength(JSON.stringify(item)) })),
      ];

      // Loop detection: if we keep fetching the same items, skip processing to break the loop.
      // Each view exposes its primary identifier under a different column name, so pick the
      // right one per array — using a generic `.id` collapses every item from thread_read /
      // thread_schedule / schedule_contact to `undefined`, producing false-positive matches.
      const fingerprintId = (t: TaggedItem): string => {
        const item = t.item as Record<string, unknown>;
        switch (t.array) {
          case "threadReads":
            return `${item.thread_id ?? ""}:${item.user_id ?? ""}`;
          case "threadSchedules":
            return String(item.schedule_id ?? "");
          case "scheduleContacts":
            return String(item.schedule_contact_id ?? "");
          case "noteReactions":
            return `${item.note_id ?? ""}:${item.actor_id ?? ""}:${item.emoji ?? ""}:${item.archived_at ? "removed" : "added"}`;
          default:
            return String(item.id ?? "");
        }
      };
      const itemFingerprint = taggedItems.length > 0
        ? taggedItems.map((t) => `${t.array}:${fingerprintId(t)}`).sort().join(",")
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

      const batches = buildSizeAwareBatches(
        taggedItems,
        MAX_BATCH_BYTES,
        MAX_ITEMS_PER_BATCH
      );

      // Build the queue message for a single batch of tagged items.
      const buildMessage = (batch: TaggedItem[]): TwistBatchMessage => {
        const batchNewNotes = batch.filter((t) => t.array === "newNotes").map((t) => t.item);
        const batchUpdatedNotes = batch.filter((t) => t.array === "updatedNotes").map((t) => t.item);
        const batchUpdatedActivities = batch.filter((t) => t.array === "updatedActivities").map((t) => t.item);
        const batchChannelNewLinks = batch.filter((t) => t.array === "channelNewLinks").map((t) => t.item);
        const batchChannelUpdatedLinks = batch.filter((t) => t.array === "channelUpdatedLinks").map((t) => t.item);
        const batchChannelNewNotes = batch.filter((t) => t.array === "channelNewNotes").map((t) => t.item);
        const batchThreadReads = batch.filter((t) => t.array === "threadReads").map((t) => t.item);
        const batchThreadSchedules = batch.filter((t) => t.array === "threadSchedules").map((t) => t.item);
        const batchScheduleContacts = batch.filter((t) => t.array === "scheduleContacts").map((t) => t.item);
        const batchNoteReactions = batch.filter((t) => t.array === "noteReactions").map((t) => t.item);

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
        return {
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
          noteReactions: batchNoteReactions,
          twistInstance: null, // TODO: Handle twist_instance config updates
        } as TwistBatchMessage;
      };

      const isPayloadTooLarge = (error: unknown): boolean =>
        error instanceof Error && error.message.includes("Payload Too Large");

      // Send one batch, recovering from Cloudflare's 128KB per-message limit:
      //   - Multi-item batch over the limit (e.g. uncounted tag-change overhead):
      //     split in half and retry so every item is still delivered.
      //   - Single item over the limit (can't be split): dispatch it inline in
      //     the background instead of dropping the callback. Mirrors the
      //     oversized-webhook fallback in webhook.ts.
      const sendBatch = async (batch: TaggedItem[]): Promise<void> => {
        const message = buildMessage(batch);
        try {
          await this.env.UPDATES_QUEUE.send(message);
        } catch (error) {
          if (!isPayloadTooLarge(error)) {
            throw error;
          }

          if (batch.length > 1) {
            logger.warn("Queue batch too large, splitting and retrying", {
              twist_instance_id: twistInstanceId,
              batch_items: batch.length,
            });
            const [left, right] = splitBatch(batch);
            await sendBatch(left);
            await sendBatch(right);
            return;
          }

          // Genuinely oversized single item: deliver inline rather than drop it.
          logger.warn("Single sync item too large for queue, dispatching inline", {
            twist_instance_id: twistInstanceId,
            item_array: batch[0].array,
            item_size: batch[0].size,
          });
          this.ctx.waitUntil(this.dispatchInline(message));
        }
      };

      // Send queue messages BEFORE updating sync timestamps
      // This ensures twist callbacks are always delivered even if timestamp updates fail
      // (transient PostgREST 500s). If timestamps fail to advance, the next alarm will
      // re-fetch the same items, causing duplicate but harmless callbacks.
      for (const batch of batches) {
        await sendBatch(batch);
      }

      // Advance seq cursors to the horizon for the 10 (entity, operation) pairs.
      // We batch these into a single multi-row UPSERT. selectCursorsToAdvance
      // skips only pairs whose existing cursor is already at/past horizonSeq
      // (genuine no-ops). Pairs that returned items, or whose cursor is behind
      // the horizon, are upserted so SyncRecovery doesn't see perpetually stale
      // rows and re-notify every 30s. Pairs with NO existing cursor row are
      // SEEDED at the horizon even on a 0-item poll — otherwise the entity has
      // no cursor and falls back to the twist's install-seq floor on every
      // alarm, re-scanning its entire global seq history forever (the dominant
      // cost of these polls; see twist-sync-cursor.ts).
      const cursorEntities: ReadonlyArray<CursorEntityCount> = [
        { entity: "thread", operation: "update", itemCount: updatedActivities.length },
        { entity: "note", operation: "create", itemCount: newNotes.length },
        { entity: "note", operation: "update", itemCount: updatedNotes.length },
        { entity: "channel_link", operation: "create", itemCount: channelNewLinks.length },
        { entity: "channel_link", operation: "update", itemCount: channelUpdatedLinks.length },
        { entity: "channel_note", operation: "create", itemCount: channelNewNotes.length },
        { entity: "thread_read", operation: "update", itemCount: threadReads.length },
        { entity: "thread_schedule", operation: "update", itemCount: threadSchedules.length },
        { entity: "schedule_contact", operation: "update", itemCount: scheduleContacts.length },
        { entity: "note_reaction", operation: "update", itemCount: noteReactions.length },
      ];

      const cursorRows = selectCursorsToAdvance(
        cursorEntities,
        syncInfos,
        horizonSeq
      ).map(({ entity, operation }) => ({
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
          // Bound the lock wait for the cursor advance. These twist_instance_sync
          // rows are also UPSERTed by the high-frequency sync_twist_for_* write-
          // path triggers (same PK), which hold the row lock for the life of the
          // connector/API write transaction that fired them. If one of those runs
          // long, a plain UPSERT here would block until the connection's 30s
          // statement_timeout — surfacing as a captured "canceling statement due
          // to statement timeout" (PostHog 019ed540) and, worse, pinning a
          // Hyperdrive pool slot for 30s, which feeds the pool-exhaustion that is
          // this DO's other failure mode. SET LOCAL scopes the shorter timeout to
          // this one statement (it resets on commit); the advance is idempotent,
          // so on a bail the cursor stays stale, SyncRecovery re-notifies within
          // ~30s, and the next alarm retries.
          await db.transaction().execute(async (trx) => {
            await sql`SET LOCAL lock_timeout = '5000ms'`.execute(trx);
            await trx
              .insertInto("twist_instance_sync")
              .values(cursorRows as any)
              .onConflict((oc) =>
                oc.columns(["twist_instance_id", "entity", "operation"]).doUpdateSet({
                  last_sync_at: sql`now()`,
                  last_sync_seq: sql`GREATEST(twist_instance_sync.last_sync_seq, EXCLUDED.last_sync_seq)`,
                } as any)
              )
              .execute();
          });
        } catch (error) {
          // Two expected, self-healing failure modes here — log but don't report
          // either as a bug (the advance is idempotent, so on a bail the cursor
          // stays stale, SyncRecovery re-notifies within ~30s, and the next alarm
          // retries):
          //   1. Row-lock contention with a concurrent write-path transaction
          //      (isLockContentionError).
          //   2. Transient Hyperdrive pool exhaustion / connection recycling
          //      (isTransientDbError). This transaction runs on the withDb pool
          //      but OUTSIDE withDb's retry (the error is caught here, not
          //      rethrown), so a single "open slot in the pool" timeout was being
          //      captured immediately — the dominant source of PostHog 019ed540.
          //      These bursts are expected and drain on their own.
          // Anything else is a genuine fault worth capturing.
          if (isLockContentionError(error) || isTransientDbError(error)) {
            logger.warn(
              "Cursor advance hit expected transient contention on twist_instance_sync; retrying next alarm",
              {
                twist_instance_id: twistInstanceId!,
                cursor_count: cursorRows.length,
                pg_code: (error as { code?: string })?.code,
              }
            );
          } else {
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

      this.retry.reset();
    } catch (error) {
      // Transient platform faults (DO reset, Hyperdrive drop) self-heal:
      // reschedule the alarm so this DO retries directly instead of leaning
      // on SyncRecovery's next sweep (which adds ~30-60s of sync latency).
      // Queue sends already happened-or-not atomically per batch and cursor
      // advances are idempotent, so a re-run is safe. After the ladder is
      // exhausted the error is captured — SyncRecovery remains the backstop.
      if (isTransientAlarmError(error)) {
        this.captureTransientCounter(error);
        const handled = await this.retry.reschedule({
          storage: this.ctx.storage,
          logger,
          error,
          durableObject: "TwistSync",
          logContext: { twist_instance_id: this.twistInstanceId ?? undefined },
          beforeSchedule: () => {
            this.state.pendingAlarm = true;
          },
          onScheduleFailed: () => {
            this.state.pendingAlarm = false;
          },
        });
        if (handled) return;
      }
      logger.error("Error in TwistSync alarm", error as Error, {
        twist_instance_id: this.twistInstanceId,
      });
      this.captureException(error as Error);
    }
  }
}
