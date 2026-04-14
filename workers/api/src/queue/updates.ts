import type { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { Tag } from "@plotday/twister/tag";

import { type DB, createDb } from "../db";
import { type Bindings, type TwistBatchMessage } from "../env";
import { rpc, rpcUser } from "../rpc";
import { Usage } from "../state/usage";
import { twistFactory } from "../twist";
import { createLogger } from "@plotday/worker-util";
import { analyzeNote } from "./note-analysis";
import { checkAiLimit, recordAiUsage } from "../utils/ai-limits";
import { markThreadUnreadForOthers } from "../app/sync/notes";

/**
 * Process a batch of twist update messages from the queue.
 * Each message contains enriched entity data for a single twist instance.
 */
export async function processUpdates(
  batch: MessageBatch<TwistBatchMessage>,
  env: Bindings,
  ctx: ExecutionContext,
  postHog: PostHog
): Promise<void> {
  const db = createDb(env);

  try {
    for (const message of batch.messages) {
      await processTwistBatch(
        message.body,
        env,
        ctx,
        db,
        batch.queue,
        postHog
      );
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
    postHog.captureException(error as Error, undefined, {
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
async function processTwistBatch(
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
            undefined,
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
        postHog.captureException(error as Error, undefined, {
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
        postHog.captureException(error as Error, undefined, {
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
            undefined,
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
        postHog.captureException(error as Error, undefined, {
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
        postHog.captureException(error as Error, undefined, {
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
        postHog.captureException(error as Error, undefined, {
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
        const owner = await db
          .selectFrom("twist_instance")
          .select("owner_id")
          .where("id", "=", twistInstanceId)
          .executeTakeFirst();
        const ownerId = owner?.owner_id;

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
          ownerId &&
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
            postHog.captureException(
              analysisError instanceof Error ? analysisError : new Error(String(analysisError)),
              undefined,
              { context: "note-analysis:channelNote", note_id: note.id, twist_instance_id: twistInstanceId }
            );
          }
        }

        // Fallback: mark unread with default urgency if analysis didn't handle it
        if (!analysisHandledUnread && note.thread_id && ownerId) {
          const notePriorityId = note.priority_id;
          if (notePriorityId) {
            try {
              await markThreadUnreadForOthers(env, db, notePriorityId, note.thread_id, ownerId);
            } catch (error) {
              logger.error("Failed to mark thread unread (fallback)", error as Error, {
                note_id: note.id,
                thread_id: note.thread_id,
              });
              postHog.captureException(error as Error, undefined, {
                context: "markThreadUnreadForOthers:channelNote",
                note_id: note.id,
                thread_id: note.thread_id,
                twist_instance_id: twistInstanceId,
              });
            }
          }
        }

        // Notify UserSync DOs so the push notification pipeline fires
        if (note.thread_id && ownerId) {
          const notePriorityId = note.priority_id;
          if (notePriorityId) {
            try {
              const usersData = await rpc(db, "get_users_with_priority_access", {
                target_priority_id: notePriorityId,
              });
              const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];
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
            } catch (error) {
              logger.error("Failed to notify UserSync DOs for channel note", error as Error, {
                note_id: note.id,
              });
            }
          }
        }
      } catch (error) {
        logger.error("Error processing channel note create", error as Error, {
          note_id: note.id,
        });
        postHog.captureException(error as Error, undefined, {
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
        await twistWrapper.dispatch("Plot", {
          itemType: "thread_read" as const,
          item: threadRead,
        });
      } catch (error) {
        logger.error("Error processing thread read", error as Error, {
          thread_id: threadRead.thread_id,
          user_id: threadRead.user_id ?? undefined,
        });
        postHog.captureException(error as Error, undefined, {
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
        await twistWrapper.dispatch("Plot", {
          itemType: "schedule_contact" as const,
          item: scheduleContact,
        });
      } catch (error) {
        logger.error("Error processing schedule contact", error as Error, {
          schedule_id: scheduleContact.schedule_id,
          contact_id: scheduleContact.contact_id ?? undefined,
        });
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          twist_instance_id: twistInstanceId,
          schedule_id: scheduleContact.schedule_id,
          queue,
        });
      }
    }

    // Process thread schedule changes (for onThreadToDo callback)
    for (const threadSchedule of threadSchedules ?? []) {
      if (!threadSchedule.thread_id) continue;

      try {
        await twistWrapper.dispatch("Plot", {
          itemType: "thread_schedule" as const,
          item: threadSchedule,
        });
      } catch (error) {
        logger.error("Error processing thread schedule", error as Error, {
          thread_id: threadSchedule.thread_id,
          user_id: threadSchedule.user_id ?? undefined,
        });
        postHog.captureException(error as Error, undefined, {
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
        postHog.captureException(error as Error, undefined, {
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
      has_twist_instance_update: !!twistInstance,
    });
  } catch (error) {
    logger.error("Error processing twist batch", error as Error, {
      twist_instance_id: twistInstanceId,
      twist_id: String(twistId),
    });
    postHog.captureException(error as Error, undefined, {
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
