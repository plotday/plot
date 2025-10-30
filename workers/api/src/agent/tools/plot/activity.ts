import {
  type Activity,
  type ActivityMeta,
  ActivityType,
  type ActivityUpdate,
  type NewActivity,
} from "@plotday/agent/plot";
import { type Database, safeQuery } from "@plotday/db";

import { fromDbActivity } from "./converters";
import { calculateDbEndFromRecurrenceUntil, formatInterval } from "./datetime";
import type { Plot } from "./index";

export async function createActivity(
  plot: Plot,
  activity: NewActivity
): Promise<Activity> {
  // Handle activity exceptions differently
  if (activity.recurrence && activity.occurrence) {
    return createActivityException(plot, activity);
  }

  // Handle path generation based on parentId
  let parent;
  if (activity.parent) {
    // Look up parent activity to get its path and priority
    const parentResult = await plot.supabase
      .from("activity")
      .select("path, priority_id")
      .eq("id", activity.parent.id)
      .single();

    if (parentResult.error) {
      throw new Error(`Parent activity not found`);
    }

    parent = parentResult.data;
  } else {
    parent = null;
  }

  // Validate priority access
  const targetPriorityId =
    parent?.priority_id ?? activity.priority?.id ?? plot.priorityId;
  await plot.validatePriorityAccess(targetPriorityId);

  // Validate activity create access permissions
  await plot.validateActivityCreateAccess(activity);

  // Map ActivityType enum to database activity_type
  let dbActivityType: "note" | "task" | "event" = "note";
  if (activity.type !== undefined) {
    switch (activity.type) {
      case ActivityType.Note:
        dbActivityType = "note";
        break;
      case ActivityType.Task:
        dbActivityType = "task";
        break;
      case ActivityType.Event:
        dbActivityType = "event";
        break;
    }
  }

  // Calculate database end and duration from SDK format
  const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
    activity.start ?? null,
    activity.end ?? null,
    activity.recurrenceUntil ?? null,
    activity.recurrenceCount ?? undefined,
    activity.recurrenceRule ?? null
  );

  let path = undefined;
  if (parent) {
    const pathResult = await plot.supabase.rpc("generate_path", {
      parent: parent?.path,
    });
    if (pathResult.error) {
      throw new Error(`Path generation failed: ${pathResult.error.message}`);
    }
    path = pathResult.data;
  }

  // Convert NewActivity to database format
  const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
    author_id: plot.priorityAgentId,
    created_by: plot.priorityAgentId,
    priority_id: targetPriorityId,
    type: dbActivityType,
    title: activity.title ?? null,
    note: activity.note ?? null,
    duration: duration ? formatInterval(duration) : null,
    done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
    links: activity.links ?? null,
    recurrence_rule: activity.recurrenceRule ?? null,
    recurrence_exdates:
      activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null,
    recurrence_dates:
      activity.recurrenceDates?.map((d) => d.toISOString()) ?? null,
    meta: activity.meta ?? null,
    mentions: activity.mentions ?? null,
    updated_by: plot.getUpdatedBy(),
    path,
  };

  // Handle scheduling fields using calculated dbEnd
  if (
    (activity.start !== undefined && activity.start !== null) ||
    (dbEnd !== undefined && dbEnd !== null)
  ) {
    if (activity.start instanceof Date || dbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        dbEnd instanceof Date
          ? dbEnd.toISOString()
          : dbEnd
          ? `${dbEnd}T23:59:59Z`
          : null;

      if (startStr && endStr) {
        dbActivity.at = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbActivity.at = `[${startStr},)`;
      } else if (endStr) {
        // Start from beginning of time, end at specified time
        dbActivity.at = `(,${endStr}]`;
      }
    } else {
      // Date range
      const startStr = activity.start;
      const endStr = dbEnd;

      if (startStr && endStr) {
        dbActivity.on = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbActivity.on = `[${startStr},)`;
      } else if (endStr) {
        // Start from beginning of time, end at specified date
        dbActivity.on = `(,${endStr}]`;
      }
    }
  }

  const dbResult = safeQuery(
    await plot.supabase.from("activity").insert(dbActivity).select().single()
  );

  // Add tags if provided
  if (activity.tags) {
    const tagUpdates: Record<string, boolean> = {};
    for (const tagId of Object.keys(activity.tags)) {
      tagUpdates[tagId] = true; // true means adding the tag
    }

    await plot.supabase.rpc("update_activity_tags", {
      p_activity_id: dbResult.id,
      p_user_id: plot.priorityAgentId, // Use agent as the actor
      p_client_id: plot.getUpdatedBy(),
      p_tag_updates: tagUpdates,
    });
  }

  // Fetch the created activity with author information
  const { data: activityWithAuthor, error: fetchError } = await plot.supabase
    .from("activity")
    .select(
      `
        *,
        author:actor!author_id(
          id,
          name,
          type
        )
      `
    )
    .eq("id", dbResult.id)
    .single();

  if (fetchError) {
    throw new Error(`Failed to fetch created activity: ${fetchError.message}`);
  }

  // Fetch tags for the activity
  const { data: tagsData } = await plot.supabase
    .from("activity_tags")
    .select("tags")
    .eq("activity_id", dbResult.id)
    .single();

  return fromDbActivity({
    ...activityWithAuthor,
    tags: tagsData?.tags || null,
  } as any as Database["public"]["Tables"]["activity"]["Row"] & {
    author: {
      id: string;
      name: string;
      type: string;
    };
  });
}

export async function updateActivity(
  plot: Plot,
  activity: ActivityUpdate
): Promise<void> {
  // Validate activity update access permissions
  await plot.validateActivityUpdateAccess(activity.id);

  // Fetch activity priority to validate access
  const { data: existingActivity, error: fetchError } = await plot.supabase
    .from("activity")
    .select("priority_id")
    .eq("id", activity.id)
    .single();

  if (fetchError) {
    throw new Error(
      `Activity not found or access denied: ${fetchError.message}`
    );
  }

  // Validate priority access
  await plot.validatePriorityAccess(existingActivity.priority_id);

  // Build update object
  const dbUpdate: Database["public"]["Tables"]["activity"]["Update"] = {
    updated_by: plot.getUpdatedBy(),
  };

  // Handle type mapping if provided
  if (activity.type !== undefined) {
    switch (activity.type) {
      case ActivityType.Note:
        dbUpdate.type = "note";
        break;
      case ActivityType.Task:
        dbUpdate.type = "task";
        break;
      case ActivityType.Event:
        dbUpdate.type = "event";
        break;
    }
  }

  // Handle basic fields
  if (activity.title !== undefined) {
    dbUpdate.title = activity.title;
  }
  if (activity.note !== undefined) {
    dbUpdate.note = activity.note;
  }
  if (activity.doneAt !== undefined) {
    dbUpdate.done_at = activity.doneAt ? activity.doneAt.toISOString() : null;
  }
  if (activity.meta !== undefined) {
    dbUpdate.meta = activity.meta;
  }
  if (activity.links !== undefined) {
    dbUpdate.links = activity.links;
  }
  if (activity.mentions !== undefined) {
    dbUpdate.mentions = activity.mentions;
  }

  // Handle recurrence fields
  if (activity.recurrenceRule !== undefined) {
    dbUpdate.recurrence_rule = activity.recurrenceRule;
  }
  if (activity.recurrenceExdates !== undefined) {
    dbUpdate.recurrence_exdates =
      activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null;
  }
  if (activity.recurrenceDates !== undefined) {
    dbUpdate.recurrence_dates =
      activity.recurrenceDates?.map((d) => d.toISOString()) ?? null;
  }

  // Handle occurrence for recurring event exceptions
  if (activity.occurrence !== undefined) {
    const hasTimestamp =
      activity.start instanceof Date || activity.end instanceof Date;
    const occurrenceStr = activity.occurrence
      ? hasTimestamp
        ? activity.occurrence.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
        : activity.occurrence.toISOString().substring(0, 10) // YYYY-MM-DD
      : null;
    (dbUpdate as any).occurrence = occurrenceStr;
  }

  // Handle scheduling fields - need to calculate dbEnd and duration
  const hasSchedulingUpdate =
    activity.start !== undefined ||
    activity.end !== undefined ||
    activity.recurrenceUntil !== undefined ||
    activity.recurrenceCount !== undefined;

  if (hasSchedulingUpdate) {
    // Calculate database end and duration from SDK format
    const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

    // Set duration
    if (duration !== null) {
      dbUpdate.duration = formatInterval(duration);
    }

    // Handle scheduling range fields
    if (activity.start instanceof Date || dbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        dbEnd instanceof Date
          ? dbEnd.toISOString()
          : dbEnd
          ? `${dbEnd}T23:59:59Z`
          : null;

      if (startStr && endStr) {
        dbUpdate.at = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbUpdate.at = `[${startStr},)`;
      } else if (endStr) {
        dbUpdate.at = `(,${endStr}]`;
      }
      // Clear the date range if we're using timestamp range
      dbUpdate.on = null;
    } else if (
      activity.start !== undefined ||
      dbEnd !== undefined ||
      dbEnd !== null
    ) {
      // Date range
      const startStr = activity.start;
      const endStr = dbEnd;

      if (startStr && endStr) {
        dbUpdate.on = `[${startStr},${endStr})`;
      } else if (startStr) {
        dbUpdate.on = `[${startStr},)`;
      } else if (endStr) {
        dbUpdate.on = `(,${endStr}]`;
      }
      // Clear the timestamp range if we're using date range
      dbUpdate.at = null;
    }
  }

  // Handle parent path updates
  if (activity.parent !== undefined) {
    if (activity.parent) {
      // Look up parent activity to get its path and priority
      const parentResult = await plot.supabase
        .from("activity")
        .select("path, priority_id")
        .eq("id", activity.parent.id)
        .single();

      if (parentResult.error) {
        throw new Error(
          `Parent activity not found: ${parentResult.error.message}`
        );
      }

      // Validate that parent activity is within allowed hierarchy
      await plot.validatePriorityAccess(parentResult.data.priority_id);

      // Generate child path using database function
      const pathResult = await plot.supabase.rpc("generate_path", {
        parent: parentResult.data.path,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbUpdate.path = pathResult.data;
    } else {
      // Setting parent to null - generate new root path
      const pathResult = await plot.supabase.rpc("generate_path", {
        parent: null,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbUpdate.path = pathResult.data;
    }
  }

  // Execute the update
  const { error: updateError } = await plot.supabase
    .from("activity")
    .update(dbUpdate)
    .eq("id", activity.id);

  if (updateError) {
    throw new Error(`Activity update failed: ${updateError.message}`);
  }

  // Handle tags separately using RPC
  if (activity.tags) {
    await plot.supabase.rpc("update_activity_tags", {
      p_activity_id: activity.id,
      p_user_id: plot.priorityAgentId,
      p_client_id: plot.getUpdatedBy(),
      p_tag_updates: activity.tags,
    });
  }
}

export async function getThread(
  plot: Plot,
  activity: Activity
): Promise<Activity[]> {
  try {
    // Validate access to the priority
    await plot.validatePriorityAccess(activity.priority.id);

    // The activity_thread RPC function now includes actor data directly
    const { data, error } = await plot.supabase
      .rpc("activity_thread", {
        p_activity_id: activity.id,
      })
      .select(
        `
          *,
          author:actor!author_id(
            id,
            name,
            type
          )
        `
      );
    if (error) {
      console.error(error);
      throw error;
    }

    // Fetch tags for all activities in the thread
    const activityIds = data.map((row: any) => row.id);
    const { data: tagsData } = await plot.supabase
      .from("activity_tags")
      .select("activity_id, tags")
      .in("activity_id", activityIds);

    // Create a map of activity_id to tags
    const tagsMap = new Map<string, any>();
    if (tagsData) {
      for (const tagRecord of tagsData) {
        if (tagRecord.activity_id) {
          tagsMap.set(tagRecord.activity_id, tagRecord.tags);
        }
      }
    }

    return data.map((row) =>
      fromDbActivity({
        ...row,
        tags: tagsMap.get(row.id) || null,
      } as any as Database["public"]["Tables"]["activity"]["Row"] & {
        author: {
          id: string;
          name: string;
          type: string;
        };
      })
    );
  } catch (err) {
    console.error("Failed to get activities:", err);
    throw err;
  }
}

export async function getActivityByMeta(
  plot: Plot,
  meta: ActivityMeta
): Promise<Activity | null> {
  try {
    // Query activities with matching meta fields using the user_activity view
    // This view automatically filters to activities the user has access to
    // We use a JSON containment operator to check if the provided meta is contained in the stored meta
    const { data, error } = await plot.supabase
      .from("user_activity")
      .select(
        `
          *,
          author:actor(
            id,
            name,
            type
          )
        `
      )
      .contains("meta", meta)
      .limit(1)
      .single();

    if (error) {
      if (error.code === "PGRST116") {
        // No rows found
        return null;
      }
      throw error;
    }

    // Fetch tags for the activity
    const { data: tagsData } = data.id
      ? await plot.supabase
          .from("activity_tags")
          .select("tags")
          .eq("activity_id", data.id)
          .single()
      : { data: null };

    return fromDbActivity({
      ...data,
      tags: tagsData?.tags || null,
    } as any as Database["public"]["Tables"]["activity"]["Row"] & {
      author: {
        id: string;
        name: string;
        type: string;
      };
    });
  } catch (err) {
    console.error("Failed to get activity by meta:", err);
    throw err;
  }
}

export async function createActivities(
  plot: Plot,
  activities: NewActivity[]
): Promise<Activity[]> {
  if (activities.length === 0) {
    return [];
  }

  // Convert all activities to database format
  const dbActivities: Database["public"]["Tables"]["activity"]["Insert"][] = [];

  for (const activity of activities) {
    // Skip activity exceptions for batch operations
    if (activity.recurrence && activity.occurrence) {
      throw new Error(
        "Activity exceptions are not supported in batch creation"
      );
    }

    await plot.validateActivityCreateAccess(activity);

    // Validate priority access
    const targetPriorityId = activity.priority?.id || plot.priorityId;
    await plot.validatePriorityAccess(targetPriorityId);

    // Map ActivityType enum to database activity_type
    let dbActivityType: "note" | "task" | "event" = "note";
    if (activity.type !== undefined) {
      switch (activity.type) {
        case ActivityType.Note:
          dbActivityType = "note";
          break;
        case ActivityType.Task:
          dbActivityType = "task";
          break;
        case ActivityType.Event:
          dbActivityType = "event";
          break;
      }
    }

    // Calculate database end and duration from SDK format
    const { dbEnd, duration } = calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

    // Convert NewActivity to database format
    const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
      author_id: plot.priorityAgentId,
      created_by: plot.priorityAgentId,
      priority_id: targetPriorityId,
      type: dbActivityType,
      title: activity.title ?? null,
      note: activity.note ?? null,
      duration: duration ? formatInterval(duration) : null,
      done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
      links: activity.links ?? null,
      recurrence_rule: activity.recurrenceRule ?? null,
      recurrence_exdates:
        activity.recurrenceExdates?.map((d) => d.toISOString()) ?? null,
      recurrence_dates:
        activity.recurrenceDates?.map((d) => d.toISOString()) ?? null,
      meta: activity.meta ?? null,
      mentions: activity.mentions ?? null,
      updated_by: plot.getUpdatedBy(),
    };

    // Handle scheduling fields using calculated dbEnd
    if (
      (activity.start !== undefined && activity.start !== null) ||
      (dbEnd !== undefined && dbEnd !== null)
    ) {
      if (activity.start instanceof Date || dbEnd instanceof Date) {
        // Timestamp range
        const startStr =
          activity.start instanceof Date
            ? activity.start.toISOString()
            : activity.start
            ? `${activity.start}T00:00:00Z`
            : null;
        const endStr =
          dbEnd instanceof Date
            ? dbEnd.toISOString()
            : dbEnd
            ? `${dbEnd}T23:59:59Z`
            : null;

        if (startStr && endStr) {
          dbActivity.at = `[${startStr},${endStr})`;
        } else if (startStr) {
          dbActivity.at = `[${startStr},)`;
        } else if (endStr) {
          dbActivity.at = `(,${endStr}]`;
        }
      } else {
        // Date range
        const startStr = activity.start;
        const endStr = dbEnd;

        if (startStr && endStr) {
          dbActivity.on = `[${startStr},${endStr})`;
        } else if (startStr) {
          dbActivity.on = `[${startStr},)`;
        } else if (endStr) {
          dbActivity.on = `(,${endStr}]`;
        }
      }
    }

    // Handle path generation based on parentId
    if (activity.parent) {
      // Look up parent activity to get its path and priority
      const parentResult = await plot.supabase
        .from("activity")
        .select("path, priority_id")
        .eq("id", activity.parent.id)
        .single();

      if (parentResult.error) {
        throw new Error(
          `Parent activity not found: ${parentResult.error.message}`
        );
      }

      // Validate that parent activity is within allowed hierarchy
      await plot.validatePriorityAccess(parentResult.data.priority_id);
      // Generate child path using database function
      const pathResult = await plot.supabase.rpc("generate_path", {
        parent: parentResult.data.path,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbActivity.path = pathResult.data;
    }

    dbActivities.push(dbActivity);
  }

  // Batch insert all activities
  const dbResult = safeQuery(
    await plot.supabase.from("activity").insert(dbActivities).select()
  );

  // Add tags for activities that have them
  for (let i = 0; i < activities.length; i++) {
    const activity = activities[i];
    const dbActivity = dbResult[i];

    if (activity.tags) {
      const tagUpdates: Record<string, boolean> = {};
      for (const tagId of Object.keys(activity.tags)) {
        tagUpdates[tagId] = true; // true means adding the tag
      }

      await plot.supabase.rpc("update_activity_tags", {
        p_activity_id: dbActivity.id,
        p_user_id: plot.priorityAgentId, // Use agent as the actor
        p_client_id: plot.getUpdatedBy(),
        p_tag_updates: tagUpdates,
      });
    }
  }

  // Fetch all created activities with author information
  const activityIds = dbResult.map((a: any) => a.id);
  const { data: activitiesWithAuthor, error: fetchError } = await plot.supabase
    .from("activity")
    .select(
      `
        *,
        author:actor!author_id(
          id,
          name,
          type
        )
      `
    )
    .in("id", activityIds);

  if (fetchError) {
    throw new Error(
      `Failed to fetch created activities: ${fetchError.message}`
    );
  }

  // Fetch tags for all activities
  const { data: tagsData } = await plot.supabase
    .from("activity_tags")
    .select("activity_id, tags")
    .in("activity_id", activityIds);

  // Create a map of activity_id to tags
  const tagsMap = new Map<string, any>();
  if (tagsData) {
    for (const tagRecord of tagsData) {
      if (tagRecord.activity_id) {
        tagsMap.set(tagRecord.activity_id, tagRecord.tags);
      }
    }
  }

  return activitiesWithAuthor.map((activityWithAuthor) =>
    fromDbActivity({
      ...activityWithAuthor,
      tags: tagsMap.get(activityWithAuthor.id) || null,
    } as any as Database["public"]["Tables"]["activity"]["Row"] & {
      author: {
        id: string;
        name: string;
        type: string;
      };
    })
  );
}

async function createActivityException(
  plot: Plot,
  activity: NewActivity
): Promise<Activity> {
  if (!activity.recurrence || !activity.occurrence) {
    throw new Error(
      "Activity exception requires both recurrence and occurrence"
    );
  }

  // Validate activity update access permissions (exceptions are updates to recurring activities)
  await plot.validateActivityUpdateAccess(activity.recurrence.id);

  // Validate access to the recurrence activity
  await plot.validatePriorityAccess(activity.recurrence.priority.id);

  // Format occurrence as required by database
  const hasTimestamp =
    activity.start instanceof Date || activity.end instanceof Date;
  const occurrenceStr = hasTimestamp
    ? activity.occurrence!.toISOString().substring(0, 16) // YYYY-MM-DDTHH:MM
    : activity.occurrence!.toISOString().substring(0, 10); // YYYY-MM-DD

  // Calculate database end and duration from SDK format for exceptions
  const { dbEnd: exceptionDbEnd, duration: exceptionDuration } =
    calculateDbEndFromRecurrenceUntil(
      activity.start ?? null,
      activity.end ?? null,
      activity.recurrenceUntil ?? null,
      activity.recurrenceCount ?? undefined,
      activity.recurrenceRule ?? null
    );

  const dbException: Database["public"]["Tables"]["activity_exception"]["Insert"] =
    {
      activity_id: activity.recurrence.id,
      occurrence: occurrenceStr,
      title: activity.title ?? null,
      note: activity.note ?? null,
      duration: exceptionDuration ? formatInterval(exceptionDuration) : null,
      done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
      meta: activity.meta ?? null,
      updated_by: plot.getUpdatedBy(),
    };

  // Handle scheduling fields for exception using calculated dbEnd
  if (
    (activity.start !== undefined && activity.start !== null) ||
    (exceptionDbEnd !== undefined && exceptionDbEnd !== null)
  ) {
    if (activity.start instanceof Date || exceptionDbEnd instanceof Date) {
      // Timestamp range
      const startStr =
        activity.start instanceof Date
          ? activity.start.toISOString()
          : activity.start
          ? `${activity.start}T00:00:00Z`
          : null;
      const endStr =
        exceptionDbEnd instanceof Date
          ? exceptionDbEnd.toISOString()
          : exceptionDbEnd
          ? `${exceptionDbEnd}T23:59:59Z`
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
      const startStr = activity.start;
      const endStr = exceptionDbEnd;

      if (startStr && endStr) {
        dbException.on = `[${startStr},${endStr}]`;
      } else if (startStr) {
        dbException.on = `[${startStr},)`;
      } else if (endStr) {
        dbException.on = `(,${endStr}]`;
      }
    }
  }

  const result = await plot.supabase
    .from("activity_exception")
    .insert(dbException)
    .select()
    .single();

  if (result.error) {
    throw new Error(
      `Activity exception creation failed: ${result.error.message}`
    );
  }

  // Return as Activity with exception fields
  return {
    id: result.data.id,
    type: activity.type || ActivityType.Note,
    author: activity.recurrence!.author,
    start: activity.start ?? null,
    end: activity.end ?? null,
    recurrenceUntil: activity.recurrenceUntil ?? null,
    recurrenceCount: activity.recurrenceCount ?? null,
    doneAt: activity.doneAt ?? null,
    note: activity.note ?? null,
    title: activity.title ?? null,
    parent: null,
    links: activity.links ?? null,
    priority: activity.recurrence!.priority,
    recurrenceRule: null,
    recurrenceExdates: null,
    recurrenceDates: null,
    recurrence: activity.recurrence ?? null,
    occurrence: activity.occurrence ?? null,
    meta: activity.meta ?? null,
    tags: activity.tags ?? null,
    mentions: activity.mentions ?? null,
  };
}
