import {
  type Thread,
  type ActorId,
  type NewThread,
  type NewActor,
} from "@plotday/twister/plot";

import { rpcUser } from "../../../rpc";
import { handleDbOperationError, processNewActorArray } from "./thread-helpers";
import type { Plot } from "./index";

/**
 * @deprecated This function is deprecated. Use the occurrences[] array field on NewThread instead.
 * Creates a thread exception for a recurring thread.
 * An exception represents a single occurrence that has different values from the parent thread.
 */
export async function createThreadException(
  _plot: Plot,
  _activity: NewThread
): Promise<Thread> {
  throw new Error(
    "createThreadException is deprecated. Use the occurrences[] array field on NewThread or ThreadUpdate instead."
  );
}

/** @deprecated Use createThreadException */
export const createActivityException = createThreadException;

/**
 * Process occurrence-specific tags for a recurring activity.
 * Inserts tags with an occurrence field so they apply to a single occurrence
 * rather than the entire series.
 */
export async function processOccurrences(
  plot: Plot,
  activityId: string,
  occurrences: Array<{
    occurrence: Date | string;
    tags?: Partial<Record<number, NewActor[]>>;
    twistTags?: Partial<Record<number, boolean>>;
  }>,
  priorityId: string
): Promise<void> {
  try {
    for (const occ of occurrences) {
      if (!occ.tags && !occ.twistTags) continue;

      // Format occurrence as required by database
      const occurrenceStr =
        typeof occ.occurrence === "string"
          ? occ.occurrence
          : occ.occurrence.toISOString().substring(0, 10); // YYYY-MM-DD

      if (occ.tags) {
        // Process NewActor[] to ActorId[] for each tag
        const processedTags: Partial<Record<number, ActorId[]>> = {};
        for (const [tagId, newActors] of Object.entries(occ.tags)) {
          if (newActors && newActors.length > 0) {
            const actorIds = await processNewActorArray(
              plot,
              newActors,
              priorityId
            );
            if (actorIds.length > 0) {
              processedTags[parseInt(tagId)] = actorIds;
            }
          }
        }

        // Insert tags with occurrence
        const newTags = Object.entries(processedTags)
          .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
          .flatMap(([tagId, actorIds]) =>
            actorIds!.map((actorId) => ({
              thread_id: activityId,
              occurrence: occurrenceStr,
              tag_id: parseInt(tagId),
              actor_id: actorId,
              updated_by: plot.getUpdatedBy(),
              sync_depth: plot.syncDepth + 1,
            }))
          );

        if (newTags.length > 0) {
          await plot.db
            .insertInto("thread_tag")
            .values(newTags)
            .onConflict((oc) =>
              oc
                .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
                .doUpdateSet((eb) => ({
                  updated_by: eb.ref("excluded.updated_by"),
                  sync_depth: eb.ref("excluded.sync_depth"),
                }))
            )
            .execute();
        }
      }

      if (occ.twistTags) {
        const userId = await plot.getUserId();
        await rpcUser(plot.db, "update_thread_tags", {
          user_id: userId,
          p_thread_id: activityId,
          p_actor_id: plot.priorityTwistId,
          p_client_id: plot.getUpdatedBy(),
          p_tag_updates: occ.twistTags,
          p_occurrence: occurrenceStr,
        });
      }
    }
  } catch (error) {
    handleDbOperationError(error, "processOccurrences", plot.priorityTwistId, {
      thread_id: activityId,
      occurrence_count: occurrences.length,
    });
  }
}
