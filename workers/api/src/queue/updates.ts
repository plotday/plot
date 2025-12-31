import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import { twistFactory } from "../twist";
import { type Bindings, type UpdateMessage } from "../env";
import { type ActivityItem, type NoteItem } from "../types";
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

  // Process activities
  if (type === "activity") {
    for (const twist of twists) {
      try {
        // Type guard to ensure we have an activity item
        if (!("priority_id" in item) || !("author_id" in item)) {
          console.warn(
            `Item type ${type} does not have required activity fields`
          );
          continue;
        }

        // Type assertion after guard
        const activityItem = item as ActivityItem;
        let previousActivityItem = previous as ActivityItem | undefined;

        // Skip processing if activity is draft
        if (activityItem.draft) {
          console.log(
            `Skipping twist processing for ${twist.id} - activity ${activityItem.id} is draft`
          );
          continue;
        }

        // If transitioning from draft to non-draft, treat as creation
        if (previousActivityItem?.draft === true && activityItem.draft === false) {
          console.log(
            `Activity ${activityItem.id} transitioned from draft to non-draft - treating as creation`
          );
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
              console.log(
                `Skipping twist processing for ${twist.id} (${twist.priority_twist_id}) - self-triggered update (updated_by: ${itemUpdatedBy})`
              );
              continue;
            }
          } catch (error) {
            console.warn(
              `Failed to process UUID truncation for twist ${twist.id}: ${
                error instanceof Error ? error.message : error
              }. Continuing with processing.`
            );
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
        console.error(
          `Error processing activity for twist ${twist.id}: ${
            error instanceof Error ? `${error.message}\n${error.stack}` : error
          }`
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: twist.id,
          priority_twist_id: twist.priority_twist_id,
          priority_id: "priority_id" in item ? String(item.priority_id) : undefined,
          environment: twist.environment,
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
          console.warn(`Item type ${type} does not have required note fields`);
          continue;
        }

        // Type assertion after guard
        const noteItem = item as NoteItem;
        let previousNoteItem = previous as NoteItem | undefined;

        // Skip processing if note is draft
        if (noteItem.draft) {
          console.log(
            `Skipping twist processing for ${twist.id} - note ${noteItem.id} is draft`
          );
          continue;
        }

        // If transitioning from draft to non-draft, treat as creation
        if (previousNoteItem?.draft === true && noteItem.draft === false) {
          console.log(
            `Note ${noteItem.id} transitioned from draft to non-draft - treating as creation`
          );
          previousNoteItem = undefined;
        }

        console.log(
          `Processing note update for twist ${twist.id} (${twist.priority_twist_id}), note ${noteItem.id}, activity ${noteItem.activity_id}`
        );

        // Skip processing if this twist triggered the update
        const itemUpdatedBy = noteItem.updated_by;
        if (itemUpdatedBy !== undefined) {
          try {
            const twistUpdatedBy = truncateUuidForUpdatedBy(
              twist.priority_twist_id
            );
            if (itemUpdatedBy === twistUpdatedBy) {
              console.log(
                `Skipping twist processing for ${twist.id} (${twist.priority_twist_id}) - self-triggered update (updated_by: ${itemUpdatedBy})`
              );
              continue;
            }
          } catch (error) {
            console.warn(
              `Failed to process UUID truncation for twist ${twist.id}: ${
                error instanceof Error ? error.message : error
              }. Continuing with processing.`
            );
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
        console.error(
          `Error processing note for twist ${twist.id}: ${
            error instanceof Error ? `${error.message}\n${error.stack}` : error
          }`
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: twist.id,
          priority_twist_id: twist.priority_twist_id,
          activity_id: "activity_id" in item ? String(item.activity_id) : undefined,
          environment: twist.environment,
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

        console.log(`Sent broadcast to user ${user.user_id} for table ${type}`);
      } catch (error) {
        console.error(
          `Error broadcasting to user ${user.user_id}: ${
            error instanceof Error ? `${error.message}\n${error.stack}` : error
          }`
        );
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
