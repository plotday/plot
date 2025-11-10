import type { PostHog } from "posthog-node";

import { type SupabaseClient, createClient } from "@plotday/db";

import { twistFactory } from "../twist";
import { type Bindings, type UpdateMessage } from "../env";
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

  // Only activities have twists to process
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

        // Skip processing if this twist triggered the update
        const itemUpdatedBy =
          "updated_by" in item ? item.updated_by : undefined;
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
          id: twist.id,
          environment: twist.environment,
          version: twist.version,
          priorityId: String(item.priority_id),
          priorityTwistId: twist.priority_twist_id,
        });

        // Dispatch to Plot tool - it will handle all filtering and processing logic
        await twistWrapper.dispatch("Plot", item, previous);
      } catch (error) {
        console.error(
          `Error processing activity for twist ${twist.id}: ${
            error instanceof Error ? `${error.message}\n${error.stack}` : error
          }`
        );
        postHog.captureException(error as Error, undefined, {
          twist_id: twist.id,
          priority_twist_id: twist.priority_twist_id,
          priority_id: String(item.priority_id),
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
        broadcast.send(
          {
            type: "sync",
            table: type,
          },
          updatedBy
        );

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
