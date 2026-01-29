import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import { type Bindings, type TwistBatchMessage } from "../env";
import { twistFactory } from "../twist";
import { createLogger } from "../utils/logger";

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
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

  for (const message of batch.messages) {
    await processTwistBatch(
      message.body,
      env,
      ctx,
      supabase,
      batch.queue,
      postHog
    );
  }
}

/**
 * Build tagsAdded/tagsRemoved from tag change events
 * Now includes occurrence-level changes grouped separately
 */
function buildTagChanges(
  activityId: string,
  tagChanges: TwistBatchMessage["activityTagChanges"]
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
    if (change.activityId !== activityId) continue;

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
  supabase: SupabaseClient,
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
    newActivities,
    updatedActivities,
    activityTagChanges,
    priorityTwist,
  } = batchData;

  const logger = createLogger({
    priority_twist_id: priorityTwistId,
    twist_id: String(twistId),
    environment,
    version,
    queue,
  });

  try {
    // Get twist factory and create twist instance
    const factory = twistFactory({
      env,
      ctx,
      supabase,
    });

    // Get priority_id from the first item or fetch it
    let priorityId: string | undefined;
    if (newActivities.length > 0) {
      priorityId = String(newActivities[0].priority_id);
    } else if (updatedActivities.length > 0) {
      priorityId = String(updatedActivities[0].priority_id);
    } else if (newNotes.length > 0) {
      priorityId = String(newNotes[0].priority_id);
    } else if (updatedNotes.length > 0) {
      priorityId = String(updatedNotes[0].priority_id);
    } else {
      // Fallback: fetch priority_id from priority_twist table
      const { data: pt } = await supabase
        .from("priority_twist")
        .select("priority_id")
        .eq("id", priorityTwistId)
        .single();
      if (pt) {
        priorityId = String(pt.priority_id);
      }
    }

    if (!priorityId) {
      logger.warn("Could not determine priority_id for twist batch");
      return;
    }

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

        // DEBUG: Log each new note being processed
        logger.info("[DEBUG] Processing new note", {
          note_id: noteId,
          activity_id: note.activity_id ?? undefined,
          created_by: note.created_by ?? undefined,
          activity_created_by: note.activity_created_by ?? undefined,
          sync_depth: syncDepth,
        });

        // Check cascade depth limit
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for note", {
            sync_depth: syncDepth,
            note_id: noteId,
            activity_id: note.activity_id ?? undefined,
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
              activity_id: note.activity_id,
            }
          );
          continue;
        }

        // Dispatch to Plot tool - this is a new note (created callback)
        await twistWrapper.dispatch("Plot", {
          itemType: "note",
          item: note,
          isCreate: true, // New notes
          syncDepth,
        });
      } catch (error) {
        logger.error(
          "Error processing new note in twist batch",
          error as Error,
          {
            note_id: noteId,
            activity_id: note.activity_id ?? undefined,
          }
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
          note_id: noteId,
          activity_id: note.activity_id,
          queue,
        });
      }
    }

    // Process updated notes (for notes the twist created)
    for (const note of updatedNotes) {
      // Skip if note.id is null (shouldn't happen, but view types are nullable)
      if (!note.id) continue;
      const noteId = note.id;

      try {
        const syncDepth = note.sync_depth ?? 1;

        // DEBUG: Log each updated note being processed
        logger.info("[DEBUG] Processing updated note", {
          note_id: noteId,
          activity_id: note.activity_id ?? undefined,
          created_by: note.created_by ?? undefined,
          sync_depth: syncDepth,
        });

        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for updated note", {
            sync_depth: syncDepth,
            note_id: noteId,
            activity_id: note.activity_id ?? undefined,
          });
          continue;
        }

        // Dispatch to Plot tool - this is an update to a note the twist created
        await twistWrapper.dispatch("Plot", {
          itemType: "note",
          item: note,
          isCreate: false, // Updated notes
          syncDepth,
        });
      } catch (error) {
        logger.error(
          "Error processing updated note in twist batch",
          error as Error,
          {
            note_id: noteId,
            activity_id: note.activity_id ?? undefined,
          }
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
          note_id: noteId,
          activity_id: note.activity_id,
          queue,
        });
      }
    }

    // Process new activities (for activity.created callback)
    for (const activity of newActivities) {
      // Skip if activity.id is null (shouldn't happen, but view types are nullable)
      if (!activity.id) continue;
      const activityId = activity.id;

      try {
        // Read sync_depth from the entity
        const syncDepth = activity.sync_depth ?? 1;

        // DEBUG: Log each new activity being processed
        logger.info("[DEBUG] Processing new activity", {
          activity_id: activityId,
          title: activity.title?.substring(0, 50) ?? undefined,
          created_by: activity.created_by ?? undefined,
          sync_depth: syncDepth,
        });

        // Check cascade depth limit
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for new activity", {
            sync_depth: syncDepth,
            activity_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          });

          postHog.captureException(
            new Error("Sync cascade depth limit reached"),
            undefined,
            {
              sync_depth: syncDepth,
              twist_id: String(twistId),
              priority_twist_id: priorityTwistId,
              item_type: "activity",
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

        // Dispatch to Plot tool - this is a new activity (created callback)
        await twistWrapper.dispatch("Plot", {
          itemType: "activity",
          item: activity,
          isCreate: true, // New activities
          syncDepth,
          changes: {
            tagsAdded,
            tagsRemoved,
          },
        });

        // Dispatch separate callbacks for occurrence-level tag changes
        for (const occChange of occurrenceChanges) {
          await twistWrapper.dispatch("Plot", {
            itemType: "activity",
            item: activity,
            isCreate: true,
            syncDepth,
            changes: {
              tagsAdded: occChange.tagsAdded,
              tagsRemoved: occChange.tagsRemoved,
              occurrence: { occurrence: occChange.occurrence },
            },
          });
        }
      } catch (error) {
        logger.error(
          "Error processing new activity in twist batch",
          error as Error,
          {
            activity_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          }
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
          activity_id: activityId,
          priority_id: activity.priority_id,
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

        // DEBUG: Log each updated activity being processed
        logger.info("[DEBUG] Processing updated activity", {
          activity_id: activityId,
          title: activity.title?.substring(0, 50) ?? undefined,
          created_by: activity.created_by ?? undefined,
          updated_by: activity.updated_by ?? undefined,
          sync_depth: syncDepth,
        });

        // Check cascade depth limit
        if (syncDepth > 4) {
          logger.warn("Sync cascade depth limit reached for activity", {
            sync_depth: syncDepth,
            activity_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          });

          postHog.captureException(
            new Error("Sync cascade depth limit reached"),
            undefined,
            {
              sync_depth: syncDepth,
              twist_id: String(twistId),
              priority_twist_id: priorityTwistId,
              item_type: "activity",
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

        // Dispatch to Plot tool with tag changes - this is an update
        await twistWrapper.dispatch("Plot", {
          itemType: "activity",
          item: activity,
          isCreate: false, // Updated activities
          syncDepth,
          changes: {
            tagsAdded,
            tagsRemoved,
          },
        });

        // Dispatch separate callbacks for occurrence-level tag changes
        for (const occChange of occurrenceChanges) {
          await twistWrapper.dispatch("Plot", {
            itemType: "activity",
            item: activity,
            isCreate: false,
            syncDepth,
            changes: {
              tagsAdded: occChange.tagsAdded,
              tagsRemoved: occChange.tagsRemoved,
              occurrence: { occurrence: occChange.occurrence },
            },
          });
        }
      } catch (error) {
        logger.error(
          "Error processing activity in twist batch",
          error as Error,
          {
            activity_id: activityId,
            priority_id: activity.priority_id ?? undefined,
          }
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: String(twistId),
          priority_twist_id: priorityTwistId,
          activity_id: activityId,
          priority_id: activity.priority_id,
          queue,
        });
      }
    }

    // Process priority_twist config changes (no sync_depth for config)
    if (priorityTwist) {
      try {
        // Dispatch priority_twist config change to the twist
        await twistWrapper.dispatch("Plot", {
          itemType: "priority_twist",
          item: priorityTwist,
          syncDepth: undefined, // Config changes don't cascade
        });

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
      new_activity_count: newActivities.length,
      updated_activity_count: updatedActivities.length,
      tag_change_count: activityTagChanges.length,
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
