import * as Sentry from "@sentry/cloudflare";

import { type SupabaseClient, createClient } from "@plotday/db";
import {
  type ActivityLink,
  type ActivitySource,
  ActivityType,
  AuthorType,
} from "@plotday/sdk";

import { agentFactory, createTools } from "../agent";
import { type Bindings, type UpdateMessage } from "../env";
import { truncateUuidForUpdatedBy } from "../utils/uuid";

function parseRangeStart(
  rangeOn: unknown,
  rangeAt: unknown
): Date | string | null {
  // Priority: if there's a timestamp range (rangeAt), use it
  if (rangeAt) {
    const rangeStr = rangeAt.toString();
    const match = rangeStr.match(/^\[([^,\]]+)/);
    if (match) {
      return new Date(match[1]);
    }
  }

  // Otherwise, try date range (rangeOn)
  if (rangeOn) {
    const rangeStr = rangeOn.toString();
    const match = rangeStr.match(/^\[([^,\]]+)/);
    if (match) {
      return match[1]; // Return as date string in YYYY-MM-DD format
    }
  }

  return null;
}

function parseRangeEnd(
  rangeOn: unknown,
  rangeAt: unknown
): Date | string | null {
  // Priority: if there's a timestamp range (rangeAt), use it
  if (rangeAt) {
    const rangeStr = rangeAt.toString();
    const match = rangeStr.match(/,([^)\]]+)[)\]]/);
    if (match) {
      return new Date(match[1]);
    }
    // Check for unbounded end (ends with comma and closing bracket/paren)
    if (rangeStr.match(/,[)\]]$/)) {
      return null;
    }
  }

  // Otherwise, try date range (rangeOn)
  if (rangeOn) {
    const rangeStr = rangeOn.toString();
    const match = rangeStr.match(/,([^)\]]+)[)\]]/);
    if (match) {
      return match[1]; // Return as date string in YYYY-MM-DD format
    }
    // Check for unbounded end (ends with comma and closing bracket/paren)
    if (rangeStr.match(/,[)\]]$/)) {
      return null;
    }
  }

  return null;
}

export async function processUpdates(
  batch: MessageBatch<UpdateMessage>,
  env: Bindings
): Promise<void> {
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY);

  for (const message of batch.messages) {
    await processUpdate(message.body, env, supabase);
  }
}

async function processUpdate(
  updateData: UpdateMessage,
  env: Bindings,
  supabase: SupabaseClient
): Promise<void> {
  const { type, item, agents, users } = updateData;

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

        // Now TypeScript knows this is an activity item
        const activity = item as any; // We know this is an activity based on type check

        // Get tools dynamically from the agent
        const { agent: agentInstance, dependencies } = await agentFactory(env)(
          agent.id,
          agent.environment,
          agent.version
        );

        const tools = createTools(
          {
            path: [agent.id, agent.environment],
            dependencies,
          },
          {
            ai: env.AI,
            supabase,
            priorityId: String(activity.priority_id),
            priorityAgentId: agent.priority_agent_id,
            storage: env.STORAGE,
            callbacks: env.CALLBACKS,
            logSubscriptions: env.LOG_SUBSCRIPTIONS,
            env,
            agents: agentFactory(env),
          }
        );

        // Convert string activity type to ActivityType enum
        let activityType: ActivityType;
        switch (activity.type) {
          case "task":
            activityType = ActivityType.Task;
            break;
          case "event":
            activityType = ActivityType.Event;
            break;
          default:
            activityType = ActivityType.Note;
        }

        await agentInstance.activity(tools, {
          id: activity.id,
          type: activityType,
          author: {
            id: activity.author_id,
            name: activity.author_name,
            type:
              activity.author_type === "user"
                ? AuthorType.User
                : activity.author_type === "priority_agent"
                ? AuthorType.Agent
                : AuthorType.Contact, // Map author_type from database to AuthorType enum
          },
          priority: {
            id: activity.priority_id,
            title: activity.priority_title,
          },
          start: parseRangeStart(activity.on, activity.at),
          end: parseRangeEnd(activity.on, activity.at),
          recurrenceUntil: null,
          recurrenceCount: null,
          doneAt: activity.done_at ? new Date(activity.done_at) : null,
          note: activity.note,
          title: activity.title,
          parent: null,
          links: activity.links as ActivityLink[] | null,
          recurrenceRule: activity.recurrence_rule,
          recurrenceExdates: activity.recurrence_exdates
            ? activity.recurrence_exdates.map((date: any) => new Date(date))
            : null,
          recurrenceDates: activity.recurrence_dates
            ? activity.recurrence_dates.map((date: any) => new Date(date))
            : null,
          recurrence: null,
          occurrence: null,
          source: activity.source as ActivitySource | null,
        });
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
