import type { Database } from "@plotday/db";
import {
  type Activity,
  type ActorId,
  type NewActivity,
  type NewActor,
} from "@plotday/twister/plot";

import { rpcUser } from "../../../rpc";
import { handleDbOperationError, processNewActorArray } from "./activity-helpers";
import { calculateDbEndFromRecurrenceUntil, formatInterval } from "./datetime";
import type { Plot } from "./index";

/**
 * @deprecated This function is deprecated. Use the occurrences[] array field on NewActivity instead.
 * Creates an activity exception for a recurring activity.
 * An exception represents a single occurrence that has different values from the parent activity.
 */
export async function createActivityException(
  _plot: Plot,
  _activity: NewActivity
): Promise<Activity> {
  throw new Error(
    "createActivityException is deprecated. Use the occurrences[] array field on NewActivity or ActivityUpdate instead."
  );
}

/**
 * Process occurrences for a recurring activity.
 * Creates activity_exception rows and/or occurrence-specific tags.
 *
 * Implementation strategy:
 * - If only tags are specified → Insert tags with occurrence field (no exception)
 * - If any other field is specified → Create/update activity_exception + tags
 */
export async function processOccurrences(
  plot: Plot,
  activityId: string,
  occurrences: Array<{
    occurrence: Date | string;
    start?: Date | string;
    end?: Date | string | null;
    done?: Date | null;
    title?: string | null;
    preview?: string | null;
    meta?: any | null;
    tags?: Partial<Record<number, NewActor[]>>;
    twistTags?: Partial<Record<number, boolean>>;
    archived?: boolean;
    unread?: boolean;
  }>,
  priorityId: string
): Promise<void> {
  try {
    for (const occ of occurrences) {
    // Format occurrence as required by database
    const hasTimestamp = occ.start instanceof Date || occ.end instanceof Date;
    const occurrenceStr =
      typeof occ.occurrence === "string"
        ? occ.occurrence
        : hasTimestamp
        ? occ.occurrence.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
        : occ.occurrence.toISOString().substring(0, 10); // YYYY-MM-DD

    // Check if this is tags-only (no field overrides)
    const hasFieldOverrides =
      occ.start !== undefined ||
      occ.end !== undefined ||
      occ.done !== undefined ||
      occ.title !== undefined ||
      occ.preview !== undefined ||
      occ.meta !== undefined ||
      occ.archived !== undefined;

    if (!hasFieldOverrides && (occ.tags || occ.twistTags)) {
      // Tags-only path: Insert tags with occurrence field (no exception)
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
              activity_id: activityId,
              occurrence: occurrenceStr,
              tag_id: parseInt(tagId),
              actor_id: actorId,
              updated_by: plot.getUpdatedBy(),
              sync_depth: plot.syncDepth + 1,
            }))
          );

        if (newTags.length > 0) {
          await plot.db
            .insertInto("activity_tag")
            .values(newTags)
            .onConflict((oc) =>
              oc
                .columns(["actor_id", "activity_id", "occurrence", "tag_id"])
                .doUpdateSet((eb) => ({
                  updated_by: eb.ref("excluded.updated_by"),
                  sync_depth: eb.ref("excluded.sync_depth"),
                }))
            )
            .execute();
        }
      }

      if (occ.twistTags) {
        // Use update_activity_tags RPC with occurrence
        const userId = await plot.getUserId();
        await rpcUser(plot.db, "update_activity_tags", {
          user_id: userId,
          p_activity_id: activityId,
          p_actor_id: plot.priorityTwistId,
          p_client_id: plot.getUpdatedBy(),
          p_tag_updates: occ.twistTags,
          p_occurrence: occurrenceStr,
        });
      }
    } else if (hasFieldOverrides || occ.tags || occ.twistTags) {
      // Field overrides path: Create/update activity_exception
      // Calculate database end and duration
      const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
        occ.start ?? null,
        occ.end ?? null,
        null, // recurrenceUntil not applicable to exceptions
        undefined,
        null // recurrenceRule not applicable to exceptions
      );

      const dbException: Database["public"]["Tables"]["activity_exception"]["Insert"] =
        {
          activity_id: activityId,
          occurrence: occurrenceStr,
          title:
            occ.title !== undefined
              ? occ.title && occ.title.trim() !== ""
                ? occ.title
                : null
              : undefined,
          preview: occ.preview !== undefined ? occ.preview : undefined,
          duration: duration ? formatInterval(duration) : undefined,
          done_at: occ.done ? occ.done.toISOString() : undefined,
          meta: occ.meta !== undefined ? occ.meta : undefined,
          archived_at: occ.archived ? new Date().toISOString() : undefined,
          updated_by: plot.getUpdatedBy(),
        };

      // Handle scheduling fields
      if (
        (occ.start !== undefined && occ.start !== null) ||
        (dbEnd !== undefined && dbEnd !== null)
      ) {
        if (occ.start instanceof Date || dbEnd instanceof Date) {
          // Timestamp range
          const startStr =
            occ.start instanceof Date
              ? occ.start.toISOString()
              : occ.start
              ? `${occ.start}T00:00:00Z`
              : null;
          const endStr =
            dbEnd instanceof Date
              ? dbEnd.toISOString()
              : dbEnd
              ? `${dbEnd}T23:59:59Z`
              : null;

          if (startStr && endStr) {
            dbException.at = `[${startStr},${endStr})`;
          } else if (startStr) {
            dbException.at = `[${startStr},)`;
          } else if (endStr) {
            dbException.at = `(,${endStr}]`;
          }
        } else {
          // Date range
          const startStr = occ.start;
          const endStr = dbEnd;

          if (startStr && endStr) {
            dbException.on = `[${startStr},${endStr})`;
          } else if (startStr) {
            dbException.on = `[${startStr},)`;
          } else if (endStr) {
            dbException.on = `(,${endStr}]`;
          }
        }
      }

      // Upsert exception (conflict on activity_id + occurrence)
      await plot.db
        .insertInto("activity_exception")
        .values(dbException as any)
        .onConflict((oc) =>
          oc.columns(["activity_id", "occurrence"]).doUpdateSet((eb) => ({
            title: eb.ref("excluded.title"),
            preview: eb.ref("excluded.preview"),
            duration: eb.ref("excluded.duration"),
            done_at: eb.ref("excluded.done_at"),
            meta: eb.ref("excluded.meta"),
            archived_at: eb.ref("excluded.archived_at"),
            updated_by: eb.ref("excluded.updated_by"),
            at: eb.ref("excluded.at"),
            on: eb.ref("excluded.on"),
          }))
        )
        .returningAll()
        .executeTakeFirstOrThrow();

      // Process tags for this exception
      if (occ.tags) {
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

        const newTags = Object.entries(processedTags)
          .filter(([_, actorIds]) => actorIds && actorIds.length > 0)
          .flatMap(([tagId, actorIds]) =>
            actorIds!.map((actorId) => ({
              activity_id: activityId,
              occurrence: occurrenceStr,
              tag_id: parseInt(tagId),
              actor_id: actorId,
              updated_by: plot.getUpdatedBy(),
              sync_depth: plot.syncDepth + 1,
            }))
          );

        if (newTags.length > 0) {
          await plot.db
            .insertInto("activity_tag")
            .values(newTags)
            .onConflict((oc) =>
              oc
                .columns(["actor_id", "activity_id", "occurrence", "tag_id"])
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
        await rpcUser(plot.db, "update_activity_tags", {
          user_id: userId,
          p_activity_id: activityId,
          p_actor_id: plot.priorityTwistId,
          p_client_id: plot.getUpdatedBy(),
          p_tag_updates: occ.twistTags,
          p_occurrence: occurrenceStr,
        });
      }
    }
  }
  } catch (error) {
    handleDbOperationError(error, "processOccurrences", plot.priorityTwistId, {
      activity_id: activityId,
      occurrence_count: occurrences.length,
    });
  }
}
