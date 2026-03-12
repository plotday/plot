import type { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { Tag } from "@plotday/twister/tag";

import { type DB, createDb } from "../db";
import { type Bindings, type TwistBatchMessage } from "../env";
import { rpcUser } from "../rpc";
import { Usage } from "../state/usage";
import { twistFactory } from "../twist";
import { createLogger } from "@plotday/worker-util";

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
 * Process a batched twist update message
 * Handles notes, activities, and priority_twist updates for a single twist
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
    priorityTwistId,
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
    priorityTwist,
  } = batchData;

  const logger = createLogger({
    priority_twist_id: priorityTwistId,
    twist_id: String(twistId),
    environment,
    version,
    queue,
  });

  // Check if twist is suspended before processing
  const twistStatus = await db
    .selectFrom("priority_twist")
    .innerJoin("twist", "twist.id", "priority_twist.twist_id")
    .select(["priority_twist.suspended_at", "twist.execution_limit"])
    .where("priority_twist.id", "=", priorityTwistId)
    .executeTakeFirst();

  if (twistStatus?.suspended_at) {
    logger.info("Skipping twist batch for suspended twist", {
      priority_twist_id: priorityTwistId,
    });
    return;
  }

  // Check execution quota
  const usage = Usage.Get(env, priorityTwistId);
  const withinQuota = await usage.checkExecutionQuota(
    twistStatus?.execution_limit
  );
  if (!withinQuota) {
    logger.info("Skipping twist batch: execution quota exceeded", {
      priority_twist_id: priorityTwistId,
    });
    return;
  }

  try {
    // Get twist factory and create twist instance
    const factory = twistFactory({
      env,
      ctx,
      db,
    });

    // Always fetch the twist's actual priority_id from priority_twist table.
    // Using item priority_ids is incorrect because items may be in child
    // subpriorities (e.g. Twist Development), narrowing the twist's scope.
    const pt = await db
      .selectFrom("priority_twist")
      .select("priority_id")
      .where("id", "=", priorityTwistId)
      .executeTakeFirst();

    if (!pt) {
      logger.warn("Could not determine priority_id for twist batch");
      return;
    }

    const priorityId = String(pt.priority_id);

    const twistWrapper = await factory({
      version,
      priorityId,
      priorityTwistId,
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
              priority_twist_id: priorityTwistId,
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
          priority_twist_id: priorityTwistId,
          note_id: noteId,
          thread_id: note.thread_id,
          queue,
        });

        // Safety net: remove Twisting tag if this note mentions the twist
        const isMentioned = (note.mentions ?? []).includes(priorityTwistId);
        if (isMentioned && note.author_id) {
          try {
            const pt = await db
              .selectFrom("priority_twist")
              .select("owner_id")
              .where("id", "=", priorityTwistId)
              .executeTakeFirst();

            if (pt?.owner_id) {
              await rpcUser(db, "update_note_tags", {
                user_id: pt.owner_id,
                p_note_id: noteId,
                p_actor_id: note.author_id,
                p_client_id: 0,
                p_tag_updates: { [Tag.Twist]: false },
              });
            }
          } catch (tagError) {
            logger.warn("Failed to remove Twisting tag in safety net", {
              note_id: noteId,
              error: tagError instanceof Error ? tagError.message : String(tagError),
            });
          }
        }
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
          priority_twist_id: priorityTwistId,
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
              priority_twist_id: priorityTwistId,
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
          priority_twist_id: priorityTwistId,
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

        await twistWrapper.dispatch("Plot", {
          itemType: "channel_link" as const,
          item: link,
          isCreate: true,
          syncDepth,
        });
      } catch (error) {
        logger.error("Error processing channel link create", error as Error, {
          link_id: link.id,
        });
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
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

        await twistWrapper.dispatch("Plot", {
          itemType: "channel_link" as const,
          item: link,
          isCreate: false,
          syncDepth,
        });
      } catch (error) {
        logger.error("Error processing channel link update", error as Error, {
          link_id: link.id,
        });
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
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
      } catch (error) {
        logger.error("Error processing channel note create", error as Error, {
          note_id: note.id,
        });
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
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
          priority_twist_id: priorityTwistId,
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
          priority_twist_id: priorityTwistId,
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
          priority_twist_id: priorityTwistId,
          thread_id: threadSchedule.thread_id,
          queue,
        });
      }
    }

    // Process priority_twist config changes (no sync_depth for config)
    if (priorityTwist) {
      try {
        // Dispatch priority_twist config change to the twist (Plot and Integrations)
        const configDispatchArgs = {
          itemType: "priority_twist" as const,
          item: priorityTwist,
          syncDepth: undefined, // Config changes don't cascade
        };
        await twistWrapper.dispatch("Plot", configDispatchArgs);
        await twistWrapper.dispatch("Integrations", configDispatchArgs);

        logger.info("Priority twist config processed", {
          priority_twist_id: priorityTwistId,
        });
      } catch (error) {
        logger.error(
          "Error processing priority_twist in batch",
          error as Error,
          {
            priority_twist_id: priorityTwistId,
          }
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
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
      has_priority_twist_update: !!priorityTwist,
    });
  } catch (error) {
    logger.error("Error processing twist batch", error as Error, {
      priority_twist_id: priorityTwistId,
      twist_id: String(twistId),
    });
    postHog.captureException(error as Error, undefined, {
      twist_id: String(twistId),
      priority_twist_id: priorityTwistId,
      queue,
    });
  }
}
