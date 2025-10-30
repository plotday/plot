import * as Sentry from "@sentry/cloudflare";

import { type SupabaseClient, createClient } from "@plotday/db";

import { agentFactory } from "../agent";
import { type Bindings, type UpdateMessage } from "../env";
import { truncateUuidForUpdatedBy } from "../utils/uuid";

export async function processUpdates(
  batch: MessageBatch<UpdateMessage>,
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

  for (const message of batch.messages) {
    await processUpdate(message.body, env, ctx, supabase);
  }
}

async function processUpdate(
  updateData: UpdateMessage,
  env: Bindings,
  ctx: ExecutionContext,
  supabase: SupabaseClient
): Promise<void> {
  const { type, item, previous, agents, users } = updateData;

  // Only activities have agents to process
  if (type === "activity") {
    for (const agent of agents) {
      Sentry.withScope((scope) => {
        scope.setExtra("agent-id", agent.id);
        Sentry.captureMessage(agent.id, "error");
      });

      try {
        // Type guard to ensure we have an activity item
        if (!("priority_id" in item) || !("author_id" in item)) {
          console.warn(
            `Item type ${type} does not have required activity fields`
          );
          continue;
        }

        // Skip processing if this agent triggered the update
        const itemUpdatedBy =
          "updated_by" in item ? item.updated_by : undefined;
        if (itemUpdatedBy !== undefined) {
          try {
            const agentUpdatedBy = truncateUuidForUpdatedBy(
              agent.priority_agent_id
            );
            if (itemUpdatedBy === agentUpdatedBy) {
              console.log(
                `Skipping agent processing for ${agent.id} (${agent.priority_agent_id}) - self-triggered update (updated_by: ${itemUpdatedBy})`
              );
              continue;
            }
          } catch (error) {
            console.warn(
              `Failed to process UUID truncation for agent ${agent.id}: ${
                error instanceof Error ? error.message : error
              }. Continuing with processing.`
            );
            // Continue processing if UUID truncation fails - better to process than skip incorrectly
          }
        }

        // Get agent and tools dynamically
        const factory = agentFactory({
          env,
          ctx,
          supabase,
        });
        const agentWrapper = await factory({
          id: agent.id,
          environment: agent.environment,
          version: agent.version,
          priorityId: String(item.priority_id),
          priorityAgentId: agent.priority_agent_id,
        });

        // Dispatch to Plot tool - it will handle all filtering and processing logic
        await agentWrapper.dispatch("Plot", item, previous);
      } catch (error) {
        console.error(
          `Error processing activity for agent ${agent.id}: ${
            error instanceof Error ? `${error.message}\n${error.stack}` : error
          }`
        );
        // TODO Capture error in Sentry
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
        // TODO Capture error in Sentry
      }
    }
  }
}
