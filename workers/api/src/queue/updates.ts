import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import { twistFactory } from "../twist";
import { type Bindings, type UpdateMessage } from "../env";
import { type ActivityItem, type NoteItem } from "../types";
import { createLogger } from "../utils/logger";
import { extractUpdateQueueContext, addTwistContext, mergeContext } from "../utils/log-context";
import { truncateUuidForUpdatedBy } from "../utils/uuid";

export async function processUpdates(
  batch: MessageBatch<UpdateMessage>,
  env: Bindings,
  ctx: ExecutionContext,
  postHog: PostHog
): Promise<void> {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

  for (const message of batch.messages) {
    await processUpdate(message.body, env, ctx, supabase, batch.queue, postHog);
  }
}

async function processUpdate(
  updateData: UpdateMessage,
  env: Bindings,
  ctx: ExecutionContext,
  supabase: SupabaseClient,
  queue: string,
  postHog: PostHog
): Promise<void> {
  const { type, item, previous, twists, users } = updateData;

  // Create logger with queue context
  const baseContext = extractUpdateQueueContext(updateData, queue);
  const logger = createLogger(baseContext);

  // Process activities
  if (type === "activity") {
    for (const twist of twists) {
      try {
        // Type guard to ensure we have an activity item
        if (!("priority_id" in item) || !("author_id" in item)) {
          logger.warn("Item type does not have required activity fields", {
            item_type: type,
            twist_id: String(twist.id),
          });
          continue;
        }

        // Type assertion after guard
        const activityItem = item as ActivityItem;
        let previousActivityItem = previous as ActivityItem | undefined;

        // Skip processing if activity is draft
        if (activityItem.draft) {
          logger.debug("Skipping twist processing for draft activity", {
            twist_id: String(twist.id),
            activity_id: activityItem.id,
          });
          continue;
        }

        // If transitioning from draft to non-draft, treat as creation
        if (previousActivityItem?.draft === true && activityItem.draft === false) {
          logger.info("Activity transitioned from draft to non-draft", {
            activity_id: activityItem.id,
            operation: "draft_to_published",
          });
          previousActivityItem = undefined;
        }

        // Skip processing if this twist triggered the update
        const itemUpdatedBy = activityItem.updated_by;
        if (itemUpdatedBy !== undefined) {
          try {
            const twistUpdatedBy = truncateUuidForUpdatedBy(
              twist.priority_twist_id
            );
            if (itemUpdatedBy === twistUpdatedBy) {
              logger.debug("Skipping self-triggered update", {
                twist_id: String(twist.id),
                priority_twist_id: twist.priority_twist_id,
                updated_by: itemUpdatedBy,
              });
              continue;
            }
          } catch (error) {
            logger.warn("Failed to process UUID truncation, continuing with processing", error as Error, {
              twist_id: String(twist.id),
            });
            // Continue processing if UUID truncation fails - better to process than skip incorrectly
          }
        }

        // Get twist and tools dynamically
        const factory = twistFactory({
          env,
          ctx,
          supabase,
        });
        const twistWrapper = await factory({
          version: twist.version,
          priorityId: String(activityItem.priority_id),
          priorityTwistId: twist.priority_twist_id,
        });

        // Dispatch to Plot tool - it will handle all filtering and processing logic
        await twistWrapper.dispatch("Plot", {
          itemType: "activity",
          item: activityItem,
          previous: previousActivityItem,
        });
      } catch (error) {
        const context = addTwistContext(
          twist.id,
          twist.priority_twist_id,
          "priority_id" in item ? String(item.priority_id) : undefined,
          twist.environment
        );
        logger.error("Error processing activity for twist", error as Error, {
          ...context,
          version: twist.version,
          event: updateData.event,
        });
        postHog.captureException(error as Error, undefined, {
          ...context,
          version: twist.version,
          type: type,
          event: updateData.event,
          queue,
        });
      }
    }
  }

  // Process notes
  if (type === "note") {
    for (const twist of twists) {
      try {
        // Type guard to ensure we have a note item
        if (!("activity_id" in item) || !("author_id" in item)) {
          logger.warn("Item type does not have required note fields", {
            item_type: type,
            twist_id: String(twist.id),
          });
          continue;
        }

        // Type assertion after guard
        const noteItem = item as NoteItem;
        let previousNoteItem = previous as NoteItem | undefined;

        // Skip processing if note is draft
        if (noteItem.draft) {
          logger.debug("Skipping twist processing for draft note", {
            twist_id: String(twist.id),
            note_id: noteItem.id,
          });
          continue;
        }

        // If transitioning from draft to non-draft, treat as creation
        if (previousNoteItem?.draft === true && noteItem.draft === false) {
          logger.info("Note transitioned from draft to non-draft", {
            note_id: noteItem.id,
            operation: "draft_to_published",
          });
          previousNoteItem = undefined;
        }

        logger.info("Processing note update for twist", {
          twist_id: String(twist.id),
          priority_twist_id: twist.priority_twist_id,
          note_id: noteItem.id,
          activity_id: noteItem.activity_id,
        });

        // Skip processing if this twist triggered the update
        const itemUpdatedBy = noteItem.updated_by;
        if (itemUpdatedBy !== undefined) {
          try {
            const twistUpdatedBy = truncateUuidForUpdatedBy(
              twist.priority_twist_id
            );
            if (itemUpdatedBy === twistUpdatedBy) {
              logger.debug("Skipping self-triggered update", {
                twist_id: String(twist.id),
                priority_twist_id: twist.priority_twist_id,
                updated_by: itemUpdatedBy,
              });
              continue;
            }
          } catch (error) {
            logger.warn("Failed to process UUID truncation, continuing with processing", error as Error, {
              twist_id: String(twist.id),
            });
            // Continue processing if UUID truncation fails - better to process than skip incorrectly
          }
        }

        // Get twist and tools dynamically
        const factory = twistFactory({
          env,
          ctx,
          supabase,
        });
        const twistWrapper = await factory({
          version: twist.version,
          priorityId: String(noteItem.priority_id),
          priorityTwistId: twist.priority_twist_id,
        });

        // Dispatch to Plot tool - it will handle all filtering and processing logic
        await twistWrapper.dispatch("Plot", {
          itemType: "note",
          item: noteItem,
          previous: previousNoteItem,
        });
      } catch (error) {
        const context = addTwistContext(
          twist.id,
          twist.priority_twist_id,
          undefined,
          twist.environment
        );
        logger.error("Error processing note for twist", error as Error, {
          ...context,
          activity_id: "activity_id" in item ? String(item.activity_id) : undefined,
          version: twist.version,
          event: updateData.event,
        });
        postHog.captureException(error as Error, undefined, {
          ...context,
          activity_id: "activity_id" in item ? String(item.activity_id) : undefined,
          version: twist.version,
          type: type,
          event: updateData.event,
          queue,
        });
      }
    }
  }

  // Process users for broadcast notifications
  if (users && users.length > 0) {
    // Extract table name from the updateData (should be present in payload)
    const updatedBy =
      "updated_by" in item ? item.updated_by?.toString() : undefined;

    for (const user of users) {
      try {
        // Get the Broadcast DurableObject for this user
        const broadcastId = env.BROADCAST.idFromName(user.user_id);
        const broadcast = env.BROADCAST.get(broadcastId);

        // Send sync message to user via Broadcast DO
        await broadcast.send(
          {
            type: "sync",
            table: type,
          },
          updatedBy
        );

        // For priority_twist updates, also sync actor view since priority_twist is part of actor
        if (type === "priority_twist") {
          await broadcast.send(
            {
              type: "sync",
              table: "actor",
            },
            updatedBy
          );
        }

        logger.info("Sent broadcast to user", {
          user_id: user.user_id,
          table: type,
        });
      } catch (error) {
        logger.error("Error broadcasting to user", error as Error, {
          user_id: user.user_id,
          table: type,
          updated_by: updatedBy,
        });
        postHog.captureException(error as Error, undefined, {
          user_id: user.user_id,
          type: type,
          updated_by: updatedBy,
          queue: queue,
        });
      }
    }
  }
}
