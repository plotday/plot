import * as Sentry from "@sentry/cloudflare";

import { type SupabaseClient, createClient } from "@plotday/db";

import { agentFactory, createTools } from "../agent";
import {
  type ActivityLink,
  type ActivitySource,
  ActivityType,
  AuthorType,
} from "@plotday/sdk/plot";
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

function calculateTagsAdded(
  currentTags: any,
  previousTags: any
): Record<number, string[]> {
  if (!currentTags) return {};
  if (!previousTags) return currentTags;

  const added: Record<number, string[]> = {};
  for (const [tagId, actorIds] of Object.entries(
    currentTags as Record<string, string[]>
  )) {
    const prevActorIds = previousTags[tagId] || [];
    const newActorIds = actorIds.filter((id) => !prevActorIds.includes(id));
    if (newActorIds.length > 0) {
      added[Number(tagId)] = newActorIds;
    }
  }
  return added;
}

function calculateTagsRemoved(
  currentTags: any,
  previousTags: any
): Record<number, string[]> {
  if (!previousTags) return {};
  if (!currentTags) return previousTags;

  const removed: Record<number, string[]> = {};
  for (const [tagId, actorIds] of Object.entries(
    previousTags as Record<string, string[]>
  )) {
    const currActorIds = currentTags[tagId] || [];
    const removedActorIds = actorIds.filter((id) => !currActorIds.includes(id));
    if (removedActorIds.length > 0) {
      removed[Number(tagId)] = removedActorIds;
    }
  }
  return removed;
}

function buildActivityFromDbRecord(activityRecord: any): any {
  // Convert string activity type to ActivityType enum
  let activityType: ActivityType;
  switch (activityRecord.type) {
    case "task":
      activityType = ActivityType.Task;
      break;
    case "event":
      activityType = ActivityType.Event;
      break;
    default:
      activityType = ActivityType.Note;
  }

  return {
    id: activityRecord.id,
    type: activityType,
    author: {
      id: activityRecord.author_id,
      name: activityRecord.author_name,
      type:
        activityRecord.author_type === "user"
          ? AuthorType.User
          : activityRecord.author_type === "priority_agent"
          ? AuthorType.Agent
          : AuthorType.Contact,
    },
    priority: {
      id: activityRecord.priority_id,
      title: activityRecord.priority_title,
    },
    start: parseRangeStart(activityRecord.on, activityRecord.at),
    end: parseRangeEnd(activityRecord.on, activityRecord.at),
    recurrenceUntil: null,
    recurrenceCount: null,
    doneAt: activityRecord.done_at ? new Date(activityRecord.done_at) : null,
    note: activityRecord.note,
    title: activityRecord.title,
    parent: null,
    links: activityRecord.links as ActivityLink[] | null,
    recurrenceRule: activityRecord.recurrence_rule,
    recurrenceExdates: activityRecord.recurrence_exdates
      ? activityRecord.recurrence_exdates.map((date: any) => new Date(date))
      : null,
    recurrenceDates: activityRecord.recurrence_dates
      ? activityRecord.recurrence_dates.map((date: any) => new Date(date))
      : null,
    recurrence: null,
    occurrence: null,
    source: activityRecord.source as ActivitySource | null,
    tags: activityRecord.tags || null,
  };
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
            supabase,
            priorityId: String(activity.priority_id),
            priorityAgentId: agent.priority_agent_id,
            storage: env.STORAGE,
            callbacks: env.CALLBACKS,
            logSubscriptions: env.LOG_SUBSCRIPTIONS,
            env,
          }
        );

        // Build the current activity object
        const currentActivity = buildActivityFromDbRecord(activity);

        // Build the changes object if previous exists
        const changes =
          previous && "priority_id" in previous && "author_id" in previous
            ? {
                previous: buildActivityFromDbRecord(previous),
                tagsAdded: calculateTagsAdded(
                  activity.tags,
                  (previous as any).tags
                ),
                tagsRemoved: calculateTagsRemoved(
                  activity.tags,
                  (previous as any).tags
                ),
              }
            : undefined;

        await agentInstance.activity(tools, currentActivity, changes);
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
