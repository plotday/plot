import type { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { Tag } from "@plotday/twister/tag";

import { type DB, createDb, isTransientDbError } from "../db";
import { type Bindings, type TwistBatchMessage } from "../env";
import { rpcUser } from "../rpc";
import { Usage } from "../state/usage";
import { twistFactory } from "../twist";
import type { ErrorWithTwistOwner } from "../twist/invoke-webhook";
import { createLogger } from "@plotday/worker-util";
import { analyzeNote } from "./note-analysis";
import { checkAiLimit, recordAiUsage } from "../utils/ai-limits";
import { markChannelNoteUnreadFallback } from "./channel-note-unread";
import { isQueueRetryExhausted } from "./retry";
import {
  isAuthError,
  isRateLimitError,
  isTransientDoResetError,
  isTransientError,
} from "../utils/transient-error";

/**
 * Capture an error thrown while processing a twist-batch item to PostHog Error
 * Tracking — UNLESS it's an expected infrastructure / provider blip. Every
 * per-item catch in `processTwistBatch` swallows the error and continues
 * (best-effort, no retry), so the only decision is whether to page Error
 * Tracking.
 *
 * Cloudflare Durable Object resets and other transient platform faults,
 * downstream provider rate-limits, and terminal auth errors are all expected —
 * self-resolving or user-driven — and are deliberately NOT paged by the other
 * queue consumers (`processWebhooks`, `Tasks.processQueue`) or
 * `handleTwistOperation`. Without this filter a single platform blip inside a
 * connector callback fans one fault out into a capture per affected item:
 * PostHog issue 019f277a saw the "starting up Durable Object storage caused
 * object to be reset" fault captured 30× from `Google.onThreadRead` alone
 * (sibling of the 214-capture webhook-queue flood). These markers survive the
 * `__TWIST_ERROR__` RPC-boundary wrapping because they are matched as
 * substrings. The error is still logged at the call site; we only skip the
 * PostHog capture.
 */
export function captureTwistBatchError(
  postHog: PostHog,
  error: unknown,
  distinctId: string,
  properties: Record<string, unknown>
): void {
  if (
    isTransientError(error) ||
    isTransientDoResetError(error) ||
    isRateLimitError(error) ||
    isAuthError(error)
  ) {
    return;
  }
  postHog.captureException(error as Error, distinctId, properties);
}

/**
 * A write-back dispatch that fails with one of these transient infrastructure
 * faults never reached the connector — the callback was NOT delivered. Mirrors
 * the retry set the other queue consumers use (`Tasks.processQueue`,
 * `processWebhooks`): a Cloudflare Durable Object storage reset
 * (`isTransientDoResetError`), an isolate OOM / network blip / deploy-time DO
 * code swap (`isTransientError`), or a Hyperdrive/pg connection drop
 * (`isTransientDbError`). These self-resolve on retry, so the message should be
 * redelivered rather than ACKed-and-dropped. Deliberately excludes rate-limit
 * and terminal-auth errors: those are per-item, provider-driven outcomes that
 * are dropped (see {@link captureTwistBatchError}), not retried.
 */
export function isRetriableDispatchError(error: unknown): boolean {
  return (
    isTransientDoResetError(error) ||
    isTransientDbError(error) ||
    isTransientError(error)
  );
}

/**
 * Decide what happens to an error thrown while dispatching one item of a twist
 * batch:
 *
 *   - THROW it (to redeliver the whole message) when the fault is a transient
 *     infrastructure blip AND the message is safe to re-deliver. The throw
 *     propagates out of `processTwistBatch` to `processUpdates`, which calls
 *     `message.retry()` so Cloudflare hands the identical message back.
 *   - Otherwise capture-and-continue via {@link captureTwistBatchError} (which
 *     itself skips paging for expected transient/provider blips), so one bad
 *     item can't wedge the batch.
 *
 * `redeliverable` gates the retry because re-delivery re-runs EVERY item in the
 * message, including ones that already succeeded. That is safe for idempotent
 * write-backs (mark-read, to-do, RSVP, reaction, link updates — set/PUT
 * semantics) but NOT for `onNoteCreated` reply sends, which most connectors
 * perform unconditionally and would therefore double-send. A message carrying a
 * note send is marked non-redeliverable by the caller, so its transient faults
 * fall through to capture-and-continue (today's drop behavior) rather than risk
 * a duplicate reply. When it rethrows, it tags the error with the owning user so
 * an exhaustion capture attributes to a real person rather than a random id.
 */
function handleTwistBatchItemError(
  postHog: PostHog,
  error: unknown,
  distinctId: string,
  properties: Record<string, unknown>,
  redeliverable: boolean
): void {
  if (redeliverable && isRetriableDispatchError(error)) {
    if (
      error instanceof Error &&
      !(error as ErrorWithTwistOwner).twistOwnerId
    ) {
      (error as ErrorWithTwistOwner).twistOwnerId = distinctId;
    }
    throw error;
  }
  captureTwistBatchError(postHog, error, distinctId, properties);
}

/**
 * Process a batch of twist update messages from the queue.
 *
 * Each message is delivered independently: a transient infrastructure fault
 * that prevents a connector write-back from being delivered retries THAT
 * message (Cloudflare redelivers it) instead of silently ACKing it away —
 * `processTwistBatch` rethrows such faults, everything else it isolates
 * in-place. The updates queue has no dead-letter queue, so a transient that
 * persists to the delivery cap is reported once and ACKed rather than left to
 * vanish. Mirrors `processWebhooks` / `Tasks.processQueue`.
 */
export async function processUpdates(
  batch: MessageBatch<TwistBatchMessage>,
  env: Bindings,
  ctx: ExecutionContext,
  postHog: PostHog
): Promise<void> {
  const db = createDb(env);
  const logger = createLogger({
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  try {
    for (const message of batch.messages) {
      const twistInstanceId = message.body.twistInstanceId;
      try {
        await processTwistBatch(
          message.body,
          env,
          ctx,
          db,
          batch.queue,
          postHog
        );
        message.ack();
      } catch (error) {
        // `processTwistBatch` only lets an error escape when it's a TRANSIENT
        // infrastructure fault on a redeliverable message (every genuine
        // per-item error is captured and swallowed inside it). Retry so
        // Cloudflare redelivers the identical message and the write-back
        // callbacks — which are idempotent for redeliverable messages — land on
        // a healthy isolate. A permanent error can still reach here from the
        // pre-dispatch twist_instance lookup; isolate it (ack) so it can't
        // storm the queue.
        if (
          isRetriableDispatchError(error) &&
          !isQueueRetryExhausted(message.attempts)
        ) {
          logger.warn("Twist batch transient fault, retrying", {
            twist_instance_id: twistInstanceId,
            attempts: message.attempts,
            error: String(error),
          });
          message.retry();
          continue;
        }

        // Reached here two ways: a transient that burned through every delivery
        // (the updates queue has NO dead-letter queue, so it would otherwise
        // vanish), or a genuine/unexpected error. Report once — attributed to
        // the owning user when the rethrow tagged it — and ACK so it neither
        // storms nor disappears silently.
        const transientExhausted = isRetriableDispatchError(error);
        const outcome = transientExhausted ? "transient_exhausted" : "failure";
        logger.error("Twist batch delivery failed", error as Error, {
          twist_instance_id: twistInstanceId,
          attempts: message.attempts,
          outcome,
        });
        const ownerId =
          (error as ErrorWithTwistOwner)?.twistOwnerId ??
          `twist:${twistInstanceId}`;
        postHog.captureException(error as Error, ownerId, {
          queue: batch.queue,
          twist_instance_id: twistInstanceId,
          attempts: message.attempts,
          outcome,
        });
        message.ack();
      }
    }
  } finally {
    await db.destroy();
  }
}

/**
 * Build tagsAdded/tagsRemoved from tag change events
 * Now includes occurrence-level changes grouped separately
 */
function buildTagChanges(
  activityId: string,
  tagChanges: TwistBatchMessage["threadTagChanges"]
): {
  tagsAdded: Record<number, string[]>;
  tagsRemoved: Record<number, string[]>;
  occurrenceChanges: Array<{
    occurrence: string;
    tagsAdded: Record<number, string[]>;
    tagsRemoved: Record<number, string[]>;
  }>;
} {
  const tagsAdded: Record<number, string[]> = {};
  const tagsRemoved: Record<number, string[]> = {};
  const occurrenceMap = new Map<
    string,
    {
      tagsAdded: Record<number, string[]>;
      tagsRemoved: Record<number, string[]>;
    }
  >();

  for (const change of tagChanges) {
    if (change.threadId !== activityId) continue;

    if (change.occurrence === null) {
      // Series-level change
      const target = change.changeType === "added" ? tagsAdded : tagsRemoved;
      if (!target[change.tagId]) {
        target[change.tagId] = [];
      }
      if (!target[change.tagId].includes(change.actorId)) {
        target[change.tagId].push(change.actorId);
      }
    } else {
      // Occurrence-level change
      if (!occurrenceMap.has(change.occurrence)) {
        occurrenceMap.set(change.occurrence, {
          tagsAdded: {},
          tagsRemoved: {},
        });
      }
      const occData = occurrenceMap.get(change.occurrence)!;
      const target =
        change.changeType === "added" ? occData.tagsAdded : occData.tagsRemoved;
      if (!target[change.tagId]) {
        target[change.tagId] = [];
      }
      if (!target[change.tagId].includes(change.actorId)) {
        target[change.tagId].push(change.actorId);
      }
    }
  }

  return {
    tagsAdded,
    tagsRemoved,
    occurrenceChanges: Array.from(occurrenceMap.entries()).map(
      ([occurrence, changes]) => ({
        occurrence,
        ...changes,
      })
    ),
  };
}

/**
 * Fail-closed removal of the Twisting tag from a single note.
 *
 * Called both per-note after dispatch and in a batch-level finally, so it must
 * stay idempotent and never throw — its contract is "best-effort last line of
 * defense; log+report and move on".
 */
async function clearTwistingTag(
  db: Kysely<DB>,
  logger: ReturnType<typeof createLogger>,
  postHog: PostHog,
  priorityTwistId: string,
  ownerId: string,
  noteId: string,
  authorId: string
): Promise<void> {
  try {
    await rpcUser(db, "update_note_tags", {
      user_id: ownerId,
      p_note_id: noteId,
      p_actor_id: authorId,
      p_client_id: 0,
      p_tag_updates: { [Tag.Twist]: false },
    });
  } catch (error) {
    logger.error(
      "Fail-closed: failed to remove Twisting tag",
      error as Error,
      {
        note_id: noteId,
        priority_twist_id: priorityTwistId,
      }
    );
    captureTwistBatchError(postHog, error, ownerId, {
      context: "twist:tag-cleanup",
      priority_twist_id: priorityTwistId,
      note_id: noteId,
    });
  }
}

/**
 * Walks new + updated notes and clears the Twisting tag for any that mention
 * this twist. Runs in a top-level finally so every note the batch saw gets its
 * tag cleared regardless of how dispatch finished (success, throw, early
 * return). Idempotent — safe to call after per-note cleanup has already run.
 */
async function cleanupAllTwistingTags(
  db: Kysely<DB>,
  logger: ReturnType<typeof createLogger>,
  postHog: PostHog,
  priorityTwistId: string,
  ownerId: string,
  newNotes: TwistBatchMessage["newNotes"],
  updatedNotes: TwistBatchMessage["updatedNotes"]
): Promise<void> {
  const seen = new Set<string>();
  for (const note of [...newNotes, ...updatedNotes]) {
    if (!note.id || seen.has(note.id)) continue;
    if (!(note.mentions ?? []).includes(priorityTwistId)) continue;
    const authorId = note.author_id ?? note.created_by ?? ownerId;
    if (!authorId) continue;
    seen.add(note.id);
    await clearTwistingTag(
      db,
      logger,
      postHog,
      priorityTwistId,
      ownerId,
      note.id,
      authorId
    );
  }
}

/**
 * Process a batched twist update message
 * Handles notes, activities, and twist_instance updates for a single twist
 */
export async function processTwistBatch(
  batchData: TwistBatchMessage,
  env: Bindings,
  ctx: ExecutionContext,
  db: Kysely<DB>,
  queue: string,
  postHog: PostHog
): Promise<void> {
  const {
    twistInstanceId,
    twistId,
    environment,
    version,
    newNotes,
    updatedNotes,
    updatedThreads: updatedActivities,
    threadTagChanges: activityTagChanges,
    channelNewLinks,
    channelUpdatedLinks,
    channelNewNotes,
    threadReads,
    threadSchedules,
    twistInstance,
  } = batchData;

  // Whether a transient fault may retry the WHOLE message. Re-delivery re-runs
  // every item, so it's only safe when none of them has a non-idempotent side
  // effect. Reply-send write-backs (`onNoteCreated` on newNotes, `onNoteUpdated`
  // on updatedNotes) ARE now safe: the runtime dedups a re-dispatched
  // onNoteCreated per (note, connector instance) at the dispatch seam (see
  // entrypoint.ts dispatchToTool / Integrations.wasNoteWrittenBack), so a resend
  // can't happen regardless of connector correctness, and onNoteUpdated edits in
  // place. The remaining direct write-backs (mark-read, to-do, RSVP, reaction,
  // link updates) are idempotent set/PUT operations.
  //
  // `channelNewNotes` stays non-redeliverable: its non-idempotency lives HERE in
  // the consumer (re-running fires push notifications and AI note-analysis
  // again), which the dispatch-seam guard does not address.
  const redeliverable = channelNewNotes.length === 0;

  const logger = createLogger({
    twist_instance_id: twistInstanceId,
    twist_id: String(twistId),
    environment,
    version,
    queue,
  });

  // Fetch priority_twist metadata early so we have owner_id available for the
  // fail-closed Twisting-tag cleanup even on early returns (suspended, quota).
  const twistStatus = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select([
      "twist_instance.suspended_at",
      "twist_instance.owner_id",
      "twist.execution_limit",
    ])
    .where("twist_instance.id", "=", twistInstanceId)
    .executeTakeFirst();

  if (!twistStatus?.owner_id) {
    logger.warn("Could not determine owner_id for twist batch", {
      twist_instance_id: twistInstanceId,
    });
    return;
  }

  const ownerId = twistStatus.owner_id;

  // Handle an error from a write-back dispatch: rethrow a transient fault to
  // retry the whole message when it's safe to redeliver, otherwise capture-and-
  // continue. Bound to this message's `redeliverable` so the call sites stay
  // terse.
  const handleItemError = (
    error: unknown,
    distinctId: string,
    properties: Record<string, unknown>
  ): void =>
    handleTwistBatchItemError(
      postHog,
      error,
      distinctId,
      properties,
      redeliverable
    );

  try {
    if (twistStatus.suspended_at) {
      logger.info("Skipping twist batch for suspended twist", {
        twist_instance_id: twistInstanceId,
      });
      return;
    }

    // Check execution quota
    const usage = Usage.Get(env, twistInstanceId);
    const withinQuota = await usage.checkExecutionQuota(
      twistStatus.execution_limit
    );
    if (!withinQuota) {
      logger.info("Skipping twist batch: execution quota exceeded", {
        twist_instance_id: twistInstanceId,
      });
      return;
    }

    // Get twist factory and create twist instance
    const factory = twistFactory({
      env,
      ctx,
      db,
    });

    const twistWrapper = await factory({
      version,
      twistInstanceId,
    });

    // Process new notes (for note.created callback and mention handling)
    for (const note of newNotes) {
      // Skip if note.id is null (shouldn't happen, but view types are nullable)
      if (!note.id) continue;
      const noteId = note.id;

      try {
        // Read sync_depth from the entity
        const syncDepth = note.sync_depth ?? 1;

        // Check cascade depth limit
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for note", {
            sync_depth: syncDepth,
            note_id: noteId,
            thread_id: note.thread_id ?? undefined,
          });

          postHog.captureException(
            new Error("Sync cascade depth limit reached"),
            ownerId,
            {
              sync_depth: syncDepth,
              twist_id: String(twistId),
              twist_instance_id: twistInstanceId,
              item_type: "note",
              item_id: noteId,
              thread_id: note.thread_id,
            }
          );
          continue;
        }

        // Dispatch to Plot tool (Twists) and Integrations tool (Sources)
        // Both dispatches run; whichever has no matching tool paths is a no-op.
        const noteDispatchArgs = {
          itemType: "note" as const,
          item: note,
          isCreate: true, // New notes
          syncDepth,
        };
        await twistWrapper.dispatch("Plot", noteDispatchArgs);
        await twistWrapper.dispatch("Integrations", noteDispatchArgs);
      } catch (error) {
        logger.error(
          "Error processing new note in twist batch",
          error as Error,
          {
            note_id: noteId,
            thread_id: note.thread_id ?? undefined,
          }
        );
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          note_id: noteId,
          thread_id: note.thread_id,
          queue,
        });
        // Twisting tag removal is handled by the batch-level finally.
      }
    }

    // Process updated notes (for notes the twist created)
    for (const note of updatedNotes) {
      // Skip if note.id is null (shouldn't happen, but view types are nullable)
      if (!note.id) continue;
      const noteId = note.id;

      try {
        const syncDepth = note.sync_depth ?? 1;

        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for updated note", {
            sync_depth: syncDepth,
            note_id: noteId,
            thread_id: note.thread_id ?? undefined,
          });
          continue;
        }

        // Dispatch to Plot tool (Twists) and Integrations tool (Sources)
        const updatedNoteDispatchArgs = {
          itemType: "note" as const,
          item: note,
          isCreate: false, // Updated notes
          syncDepth,
        };
        await twistWrapper.dispatch("Plot", updatedNoteDispatchArgs);
        await twistWrapper.dispatch("Integrations", updatedNoteDispatchArgs);
      } catch (error) {
        logger.error(
          "Error processing updated note in twist batch",
          error as Error,
          {
            note_id: noteId,
            thread_id: note.thread_id ?? undefined,
          }
        );
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          note_id: noteId,
          thread_id: note.thread_id,
          queue,
        });
      }
    }

    // Process updated activities (for activity.updated callback)
    for (const activity of updatedActivities) {
      // Skip if activity.id is null (shouldn't happen, but view types are nullable)
      if (!activity.id) continue;
      const activityId = activity.id;

      try {
        // Read sync_depth from the entity
        const syncDepth = activity.sync_depth ?? 1;

        // Check cascade depth limit
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for activity", {
            sync_depth: syncDepth,
            thread_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          });

          postHog.captureException(
            new Error("Sync cascade depth limit reached"),
            ownerId,
            {
              sync_depth: syncDepth,
              twist_id: String(twistId),
              twist_instance_id: twistInstanceId,
              item_type: "thread",
              item_id: activityId,
              priority_id: activity.priority_id,
            }
          );
          continue;
        }

        // Build tag changes for this activity
        const { tagsAdded, tagsRemoved, occurrenceChanges } = buildTagChanges(
          activityId,
          activityTagChanges
        );

        // Dispatch to Plot tool (Twists) and Integrations tool (Sources)
        const updatedThreadDispatchArgs = {
          itemType: "thread" as const,
          item: activity,
          isCreate: false, // Updated activities
          syncDepth,
          changes: {
            tagsAdded,
            tagsRemoved,
          },
        };
        await twistWrapper.dispatch("Plot", updatedThreadDispatchArgs);
        await twistWrapper.dispatch("Integrations", updatedThreadDispatchArgs);

        // Dispatch separate callbacks for occurrence-level tag changes
        for (const occChange of occurrenceChanges) {
          const occUpdateDispatchArgs = {
            itemType: "thread" as const,
            item: activity,
            isCreate: false,
            syncDepth,
            changes: {
              tagsAdded: occChange.tagsAdded,
              tagsRemoved: occChange.tagsRemoved,
              occurrence: { occurrence: occChange.occurrence },
            },
          };
          await twistWrapper.dispatch("Plot", occUpdateDispatchArgs);
          await twistWrapper.dispatch("Integrations", occUpdateDispatchArgs);
        }
      } catch (error) {
        logger.error(
          "Error processing activity in twist batch",
          error as Error,
          {
            thread_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          }
        );
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          thread_id: activityId,
          priority_id: activity.priority_id,
          queue,
        });
      }
    }

    // Process new links from connected source channels (for onLinkCreated callback)
    for (const link of channelNewLinks) {
      if (!link.id) continue;

      try {
        const syncDepth = link.sync_depth ?? 1;
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for channel link", {
            sync_depth: syncDepth,
            link_id: link.id,
          });
          continue;
        }

        const dispatchArgs = {
          itemType: "channel_link" as const,
          item: link,
          isCreate: true,
          syncDepth,
        };
        await twistWrapper.dispatch("Plot", dispatchArgs);
        await twistWrapper.dispatch("Integrations", dispatchArgs);
      } catch (error) {
        logger.error("Error processing channel link create", error as Error, {
          link_id: link.id,
        });
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          link_id: link.id,
          queue,
        });
      }
    }

    // Process updated links from connected source channels (for onLinkUpdated callback)
    for (const link of channelUpdatedLinks) {
      if (!link.id) continue;

      try {
        const syncDepth = link.sync_depth ?? 1;
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for channel link update", {
            sync_depth: syncDepth,
            link_id: link.id,
          });
          continue;
        }

        const dispatchArgs = {
          itemType: "channel_link" as const,
          item: link,
          isCreate: false,
          syncDepth,
        };
        await twistWrapper.dispatch("Plot", dispatchArgs);
        await twistWrapper.dispatch("Integrations", dispatchArgs);
      } catch (error) {
        logger.error("Error processing channel link update", error as Error, {
          link_id: link.id,
        });
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          link_id: link.id,
          queue,
        });
      }
    }

    // Process new notes on threads with links from connected channels (for onLinkNoteCreated)
    for (const note of channelNewNotes) {
      if (!note.id) continue;

      try {
        const syncDepth = note.sync_depth ?? 1;
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for channel note", {
            sync_depth: syncDepth,
            note_id: note.id,
          });
          continue;
        }

        await twistWrapper.dispatch("Plot", {
          itemType: "channel_note" as const,
          item: note,
          isCreate: true,
          syncDepth,
        });

        // Also dispatch to Integrations so sources can handle onNoteCreated
        await twistWrapper.dispatch("Integrations", {
          itemType: "channel_note" as const,
          item: note,
          isCreate: true,
          syncDepth,
        });

        // Unread marking: try AI analysis first, fall back to default marking.
        // This ensures notifications are always delivered even if analysis fails.
        let analysisHandledUnread = false;

        // AI note analysis for source notes (best-effort)
        // Skip notes created by the twist itself, and historical imports (> 7 days old)
        const sourceCreatedAt = note.source_created_at
          ? new Date(note.source_created_at).getTime()
          : Date.now();
        const isRecent =
          Date.now() - sourceCreatedAt < 7 * 24 * 60 * 60 * 1000;
        if (
          note.content &&
          note.author_id &&
          note.author_id !== twistInstanceId &&
          isRecent &&
          note.thread_id
        ) {
          try {
            const aiAllowed = await checkAiLimit(env, db, ownerId, "note_processing");
            if (aiAllowed.allowed) {
              analysisHandledUnread = await analyzeNote(env, note.id, note.thread_id, ownerId);
              recordAiUsage(env, ownerId, "note_processing");
            } else {
              logger.info("[note-analysis] AI limit reached, skipping", {
                note_id: note.id,
                user_id: ownerId,
              });
            }
          } catch (analysisError) {
            logger.warn("[note-analysis] Failed for source note", {
              note_id: note.id,
              error:
                analysisError instanceof Error
                  ? analysisError.message
                  : String(analysisError),
            });
            captureTwistBatchError(
              postHog,
              analysisError instanceof Error ? analysisError : new Error(String(analysisError)),
              ownerId,
              { context: "note-analysis:channelNote", note_id: note.id, twist_instance_id: twistInstanceId }
            );
          }
        }

        // Fallback: write default thread_state if analysis didn't handle it.
        // Passes the note's source time as the unread race guard so a
        // re-dispatched, already-read incoming note doesn't clobber the
        // recipient's read (see markChannelNoteUnreadFallback).
        try {
          await markChannelNoteUnreadFallback(
            env,
            db,
            note,
            ownerId,
            analysisHandledUnread,
          );
        } catch (error) {
          logger.error("Failed to mark thread unread (fallback)", error as Error, {
            note_id: note.id,
            thread_id: note.thread_id,
          });
          captureTwistBatchError(postHog, error, ownerId, {
            context: "markThreadUnreadForOthers:channelNote",
            note_id: note.id,
            thread_id: note.thread_id,
            twist_instance_id: twistInstanceId,
          });
        }

        // Notify UserSync DOs so the push notification pipeline fires
        if (note.thread_id) {
          try {
            const thread = await db
              .selectFrom("thread")
              .select("contacts")
              .where("id", "=", note.thread_id)
              .executeTakeFirst();

            if (thread?.contacts && thread.contacts.length > 0) {
              const users = await db
                .selectFrom("user_contact")
                .select("user_id")
                .where("contact_id", "in", thread.contacts as string[])
                .where("linked", "=", true)
                .where("archived_at", "is", null)
                .execute();

              const userIds = [...new Set(users.map((u) => u.user_id))];
              for (const userId of userIds) {
                if (userId === ownerId) continue;
                try {
                  const userSyncId = env.USER_SYNC.idFromName(userId);
                  const userSyncDO = env.USER_SYNC.get(userSyncId);
                  await userSyncDO.fetch(
                    new Request("http://do/notify", {
                      method: "POST",
                      body: JSON.stringify({ id: userId }),
                    })
                  );
                } catch (doError) {
                  logger.error(`Failed to notify UserSync for user ${userId}`, doError as Error);
                }
              }
            }
          } catch (error) {
            logger.error("Failed to notify UserSync DOs for channel note", error as Error, {
              note_id: note.id,
            });
          }
        }
      } catch (error) {
        logger.error("Error processing channel note create", error as Error, {
          note_id: note.id,
        });
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          note_id: note.id,
          queue,
        });
      }
    }

    // Process thread read status changes (for onThreadRead callback)
    for (const threadRead of threadReads) {
      if (!threadRead.thread_id) continue;

      try {
        const threadReadDispatchArgs = {
          itemType: "thread_read" as const,
          item: threadRead,
        };
        // Plot-tool path for twists that declare plotOptions.thread.access,
        // Integrations path for connectors (which don't declare Plot) so they
        // can write the read state back to the external account.
        await twistWrapper.dispatch("Plot", threadReadDispatchArgs);
        await twistWrapper.dispatch("Integrations", threadReadDispatchArgs);
      } catch (error) {
        logger.error("Error processing thread read", error as Error, {
          thread_id: threadRead.thread_id,
          user_id: threadRead.user_id ?? undefined,
        });
        handleItemError(error, threadRead.user_id ?? ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          thread_id: threadRead.thread_id,
          queue,
        });
      }
    }

    // Process schedule contact changes (for onScheduleContactUpdated callback)
    for (const scheduleContact of batchData.scheduleContacts ?? []) {
      if (!scheduleContact.schedule_id) continue;

      try {
        const scheduleContactDispatchArgs = {
          itemType: "schedule_contact" as const,
          item: scheduleContact,
        };
        // Plot-tool path for twists that declare plotOptions.thread.access,
        // Integrations path for connectors (which don't declare Plot).
        await twistWrapper.dispatch("Plot", scheduleContactDispatchArgs);
        await twistWrapper.dispatch("Integrations", scheduleContactDispatchArgs);
      } catch (error) {
        logger.error("Error processing schedule contact", error as Error, {
          schedule_id: scheduleContact.schedule_id,
          contact_id: scheduleContact.contact_id ?? undefined,
        });
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          schedule_id: scheduleContact.schedule_id,
          queue,
        });
      }
    }

    // Process per-actor note reaction changes (for onNoteReactionChanged callback).
    // Each row is one (note, actor, emoji) state transition pre-routed to the
    // reactor's connector instance, so we just hand it to the Integrations
    // dispatch path.
    for (const noteReaction of batchData.noteReactions ?? []) {
      if (!noteReaction.note_id || !noteReaction.emoji) continue;
      try {
        const noteReactionDispatchArgs = {
          itemType: "note_reaction" as const,
          item: noteReaction,
        };
        await twistWrapper.dispatch("Integrations", noteReactionDispatchArgs);
      } catch (error) {
        logger.error("Error processing note reaction", error as Error, {
          note_id: noteReaction.note_id,
          actor_id: noteReaction.actor_id ?? undefined,
          emoji: noteReaction.emoji,
        });
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          note_id: noteReaction.note_id,
          queue,
        });
      }
    }

    // Process thread schedule changes (for onThreadToDo callback)
    for (const threadSchedule of threadSchedules ?? []) {
      if (!threadSchedule.thread_id) continue;

      try {
        const dispatchArgs = {
          itemType: "thread_schedule" as const,
          item: threadSchedule,
        };
        // Plot-tool path for twists that declare plotOptions.thread.access,
        // Integrations path for connectors (which don't declare Plot).
        await twistWrapper.dispatch("Plot", dispatchArgs);
        await twistWrapper.dispatch("Integrations", dispatchArgs);
      } catch (error) {
        logger.error("Error processing thread schedule", error as Error, {
          thread_id: threadSchedule.thread_id,
          user_id: threadSchedule.user_id ?? undefined,
        });
        handleItemError(error, threadSchedule.user_id ?? ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          thread_id: threadSchedule.thread_id,
          queue,
        });
      }
    }

    // Process twist_instance config changes (no sync_depth for config)
    if (twistInstance) {
      try {
        // Dispatch twist_instance config change to the twist (Plot and Integrations)
        const configDispatchArgs = {
          itemType: "twist_instance" as const,
          item: twistInstance,
          syncDepth: undefined, // Config changes don't cascade
        };
        await twistWrapper.dispatch("Plot", configDispatchArgs);
        await twistWrapper.dispatch("Integrations", configDispatchArgs);

        logger.info("Priority twist config processed", {
          twist_instance_id: twistInstanceId,
        });
      } catch (error) {
        logger.error(
          "Error processing twist_instance in batch",
          error as Error,
          {
            twist_instance_id: twistInstanceId,
          }
        );
        handleItemError(error, ownerId, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          queue,
        });
      }
    }

    logger.info("Twist batch processed successfully", {
      new_note_count: newNotes.length,
      updated_note_count: updatedNotes.length,
      updated_activity_count: updatedActivities.length,
      tag_change_count: activityTagChanges.length,
      channel_new_link_count: channelNewLinks.length,
      channel_updated_link_count: channelUpdatedLinks.length,
      channel_new_note_count: channelNewNotes.length,
      thread_read_count: threadReads.length,
      thread_schedule_count: threadSchedules?.length ?? 0,
      schedule_contact_count: batchData.scheduleContacts?.length ?? 0,
      note_reaction_count: batchData.noteReactions?.length ?? 0,
      has_twist_instance_update: !!twistInstance,
    });
  } catch (error) {
    logger.error("Error processing twist batch", error as Error, {
      twist_instance_id: twistInstanceId,
      twist_id: String(twistId),
    });
    handleItemError(error, ownerId, {
      twist_id: String(twistId),
      twist_instance_id: twistInstanceId,
      queue,
    });
  } finally {
    // Fail-closed: always clear the Twisting tag for every note in the batch
    // that mentions this twist. This runs after every code path above —
    // successful dispatch, thrown callback, suspended twist, quota exceeded,
    // sync-depth limit, factory build failure. The `finally` waits for the
    // whole dispatch chain to complete, so the tag stays visible for the full
    // duration of the twist's work (including long LLM calls).
    await cleanupAllTwistingTags(
      db,
      logger,
      postHog,
      twistInstanceId,
      ownerId,
      newNotes,
      updatedNotes
    );
  }
}
