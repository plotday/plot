import { type Database, type SupabaseClient, safeQuery } from "@plotday/db";
import {
  type Activity,
  type ActivityLink,
  type ActivitySource,
  ActivityType,
  AuthorType,
  type Priority,
} from "@plotday/sdk";
import type {
  Plot as IPlot,
  NewActivity,
  NewPriority,
} from "@plotday/sdk/tools/plot";

import { truncateUuidForUpdatedBy } from "../../utils/uuid";
import { Tool } from "./tool";

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

function parseInterval(interval: unknown): number | undefined {
  if (!interval || typeof interval !== "string") return undefined;

  // Parse PostgreSQL interval format like "01:30:00" or "3 days" or "2 hours 30 minutes"
  const intervalStr = interval.toString();

  // Try to parse simple time format (HH:MM:SS)
  const timeMatch = intervalStr.match(/^(\d{1,2}):(\d{1,2}):(\d{1,2})$/);
  if (timeMatch) {
    const [, hours, minutes, seconds] = timeMatch;
    return parseInt(hours) * 3600 + parseInt(minutes) * 60 + parseInt(seconds);
  }

  // Parse interval components like "1 day 2 hours 30 minutes"
  let totalSeconds = 0;

  // Days
  const dayMatch = intervalStr.match(/(\d+)\s*days?/);
  if (dayMatch) totalSeconds += parseInt(dayMatch[1]) * 24 * 60 * 60;

  // Hours
  const hourMatch = intervalStr.match(/(\d+)\s*hours?/);
  if (hourMatch) totalSeconds += parseInt(hourMatch[1]) * 60 * 60;

  // Minutes
  const minuteMatch = intervalStr.match(/(\d+)\s*minutes?/);
  if (minuteMatch) totalSeconds += parseInt(minuteMatch[1]) * 60;

  // Seconds
  const secondMatch = intervalStr.match(/(\d+)\s*seconds?/);
  if (secondMatch) totalSeconds += parseInt(secondMatch[1]);

  return totalSeconds > 0 ? totalSeconds : undefined;
}

function formatInterval(durationSeconds: number): string {
  const hours = Math.floor(durationSeconds / 3600);
  const minutes = Math.floor((durationSeconds % 3600) / 60);
  const seconds = durationSeconds % 60;

  return `${hours.toString().padStart(2, "0")}:${minutes
    .toString()
    .padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
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

function calculateRecurrenceUntil(
  start: Date | string | null,
  end: Date | string | null,
  duration: unknown,
  recurrenceRule?: string | null
): Date | string | null {
  // For non-recurring activities, recurrenceUntil should be null
  if (!recurrenceRule) {
    return null;
  }

  // If we have an end date for recurring activities, that represents the end of the final occurrence
  // We need to calculate when the final occurrence starts (recurrenceUntil)
  if (end && duration) {
    const durationSeconds = parseInterval(duration);
    if (durationSeconds !== undefined) {
      if (typeof end === "string") {
        // For date-based events, subtract duration in days
        const endDate = new Date(end);
        const durationDays = Math.floor(durationSeconds / (24 * 60 * 60));
        const recurrenceUntilDate = new Date(
          endDate.getTime() - durationDays * 24 * 60 * 60 * 1000
        );
        return recurrenceUntilDate.toISOString().split("T")[0]; // Return as YYYY-MM-DD
      } else if (end instanceof Date) {
        // For datetime-based events, subtract duration in seconds
        const recurrenceUntilDate = new Date(
          end.getTime() - durationSeconds * 1000
        );
        return recurrenceUntilDate;
      }
    }
  }

  // Fallback: use the end as recurrenceUntil if we can't calculate properly
  return end;
}

function calculateRecurrenceUntilFromCount(
  start: Date | string | null,
  recurrenceRule: string | null,
  recurrenceCount: number
): Date | string | null {
  if (!start || !recurrenceRule || recurrenceCount <= 0) {
    return null;
  }

  // This is a simplified calculation - in a production system, you'd want to use
  // a proper RRULE parser library to calculate the nth occurrence
  try {
    // Parse basic frequency from RRULE
    const freqMatch = recurrenceRule.match(/FREQ=([^;]+)/);
    const intervalMatch = recurrenceRule.match(/INTERVAL=([^;]+)/);

    if (!freqMatch) return null;

    const freq = freqMatch[1];
    const interval = intervalMatch ? parseInt(intervalMatch[1]) : 1;

    // Calculate approximate end based on frequency and count
    const startDate = typeof start === "string" ? new Date(start) : start;
    let incrementMs = 0;

    switch (freq) {
      case "DAILY":
        incrementMs = interval * 24 * 60 * 60 * 1000;
        break;
      case "WEEKLY":
        incrementMs = interval * 7 * 24 * 60 * 60 * 1000;
        break;
      case "MONTHLY":
        // Approximate - 30 days per month
        incrementMs = interval * 30 * 24 * 60 * 60 * 1000;
        break;
      case "YEARLY":
        // Approximate - 365 days per year
        incrementMs = interval * 365 * 24 * 60 * 60 * 1000;
        break;
      default:
        return null;
    }

    // Calculate the date of the last occurrence (count - 1 increments from start)
    const finalOccurrenceDate = new Date(
      startDate.getTime() + (recurrenceCount - 1) * incrementMs
    );

    return typeof start === "string"
      ? finalOccurrenceDate.toISOString().split("T")[0]
      : finalOccurrenceDate;
  } catch (error) {
    console.warn("Failed to calculate recurrence until from count:", error);
    return null;
  }
}

function calculateDbEndFromRecurrenceUntil(
  start: Date | string | null,
  end: Date | string | null,
  recurrenceUntil: Date | string | null,
  recurrenceCount?: number,
  recurrenceRule?: string | null
): { dbEnd: Date | string | null; duration: number | null } {
  // For non-recurring activities, use the provided end and calculate duration
  if (!recurrenceUntil && !recurrenceCount && !recurrenceRule) {
    if (start && end) {
      const duration = calculateDurationInSeconds(start, end);
      return { dbEnd: end, duration: duration || null };
    }
    return { dbEnd: end, duration: null };
  }

  // For infinite recurring activities (has recurrence rule but no until/count),
  // return null for dbEnd to create open-ended range
  if (recurrenceRule && !recurrenceUntil && !recurrenceCount) {
    const duration = calculateDurationInSeconds(start, end);
    return { dbEnd: null, duration: duration || null };
  }

  // If recurrenceCount is provided, calculate recurrenceUntil from it
  let finalRecurrenceUntil = recurrenceUntil;
  if (recurrenceCount && recurrenceRule) {
    const calculatedUntil = calculateRecurrenceUntilFromCount(
      start,
      recurrenceRule,
      recurrenceCount
    );
    if (calculatedUntil) {
      finalRecurrenceUntil = calculatedUntil;
    }
  }

  // For recurring activities, calculate the end of the final occurrence
  // and the duration of each occurrence
  if (start && end && finalRecurrenceUntil) {
    const duration = calculateDurationInSeconds(start, end);
    if (duration !== null) {
      if (
        typeof finalRecurrenceUntil === "string" &&
        typeof start === "string"
      ) {
        // Date-based: add duration to finalRecurrenceUntil to get final end
        const recurrenceUntilDate = new Date(finalRecurrenceUntil);
        const durationDays = Math.floor(duration / (24 * 60 * 60));
        const finalEndDate = new Date(
          recurrenceUntilDate.getTime() + durationDays * 24 * 60 * 60 * 1000
        );
        return {
          dbEnd: finalEndDate.toISOString().split("T")[0],
          duration,
        };
      } else if (
        finalRecurrenceUntil instanceof Date &&
        start instanceof Date
      ) {
        // DateTime-based: add duration to finalRecurrenceUntil to get final end
        const finalEndDate = new Date(
          finalRecurrenceUntil.getTime() + duration * 1000
        );
        return {
          dbEnd: finalEndDate,
          duration,
        };
      }
    }
  }

  // For ongoing recurrence (recurrenceUntil without specific end), leave dbEnd null for open range
  if (start && finalRecurrenceUntil && !recurrenceCount && !end) {
    const duration = calculateDurationInSeconds(start, end);
    return { dbEnd: null, duration: duration || null };
  }

  // Fallback
  return { dbEnd: end, duration: null };
}

function calculateDurationInSeconds(
  start: Date | string | null | undefined,
  end: Date | string | null | undefined
): number | null {
  if (!start || !end) return null;

  let startTime: Date;
  let endTime: Date;

  // Handle date strings (all-day events)
  if (typeof start === "string" && typeof end === "string") {
    startTime = new Date(start + "T00:00:00");
    endTime = new Date(end + "T00:00:00");
  } else if (start instanceof Date && end instanceof Date) {
    startTime = start;
    endTime = end;
  } else {
    return null;
  }

  const durationMs = endTime.getTime() - startTime.getTime();
  return Math.floor(durationMs / 1000); // Convert to seconds
}

function fromDbActivity(
  dbActivity: Database["public"]["Tables"]["activity"]["Row"] & {
    author: {
      id: string;
      name: string;
      type: string;
    };
  }
): Activity {
  // Map database activity_type to ActivityType enum
  let activityType: number;
  switch (dbActivity.type) {
    case "task":
      activityType = ActivityType.Task;
      break;
    case "event":
      activityType = ActivityType.Event;
      break;
    default:
    case "note":
      activityType = ActivityType.Note;
      break;
  }

  // Map actor type to AuthorType enum
  let authorType: number = AuthorType.User; // Default to User
  if (dbActivity.author.type) {
    switch (dbActivity.author.type) {
      case "user":
        authorType = AuthorType.User;
        break;
      case "contact":
        authorType = AuthorType.Contact;
        break;
      case "priority_agent":
        authorType = AuthorType.Agent;
        break;
    }
  }

  const start = parseRangeStart(dbActivity.on, dbActivity.at);
  const dbEnd = parseRangeEnd(dbActivity.on, dbActivity.at);

  // Calculate recurrenceUntil from database end and duration
  const recurrenceUntil = calculateRecurrenceUntil(
    start,
    dbEnd,
    dbActivity.duration,
    dbActivity.recurrence_rule
  );

  // For SDK, end is always the end of the first occurrence
  // If this is recurring, we need to calculate the first occurrence end from start and duration
  let sdkEnd = dbEnd;
  if (dbActivity.recurrence_rule && start && dbActivity.duration) {
    const durationSeconds = parseInterval(dbActivity.duration);
    if (durationSeconds !== undefined) {
      if (typeof start === "string") {
        // Date-based: add duration in days
        const startDate = new Date(start);
        const durationDays = Math.floor(durationSeconds / (24 * 60 * 60));
        const endDate = new Date(
          startDate.getTime() + durationDays * 24 * 60 * 60 * 1000
        );
        sdkEnd = endDate.toISOString().split("T")[0];
      } else if (start instanceof Date) {
        // DateTime-based: add duration in seconds
        sdkEnd = new Date(start.getTime() + durationSeconds * 1000);
      }
    }
  }

  return {
    id: dbActivity.id,
    type: activityType,
    author: {
      id: dbActivity.author.id || dbActivity.author_id,
      name: dbActivity.author.name || "Unknown",
      type: authorType,
    },
    start,
    end: sdkEnd,
    recurrenceUntil,
    recurrenceCount: null, // Not stored separately in database
    doneAt: dbActivity.done_at ? new Date(dbActivity.done_at) : null,
    note: dbActivity.note || null,
    title: dbActivity.title || null,
    parent: null,
    links: dbActivity.links as Array<ActivityLink> | null,
    priority: {
      id: dbActivity.priority_id,
      title: dbActivity.title ?? "Untitled",
    },
    recurrenceRule: dbActivity.recurrence_rule || null,
    recurrenceExdates:
      dbActivity.recurrence_exdates?.map((d) => new Date(d)) || null,
    recurrenceDates:
      dbActivity.recurrence_dates?.map((d) => new Date(d)) || null,
    recurrence: null,
    occurrence: null,
    source: dbActivity.source as { type: string; [key: string]: any } | null,
  };
}

function fromDbPriority(
  dbPriority: Database["public"]["Tables"]["priority"]["Row"]
): Priority {
  return {
    id: dbPriority.id,
    title: dbPriority.title,
  };
}

export class Plot extends Tool implements IPlot {
  private supabase: SupabaseClient;
  private priorityId: string;
  private priorityAgentId: string;

  constructor({
    supabase,
    priorityId,
    priorityAgentId,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
  }) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.priorityAgentId = priorityAgentId;
  }

  /**
   * Gets the updated_by value for this agent to prevent processing loops.
   * Returns the truncated UUID if valid, otherwise returns undefined.
   */
  private getUpdatedBy(): number {
    try {
      return truncateUuidForUpdatedBy(this.priorityAgentId);
    } catch (error) {
      console.warn(
        `Failed to generate updated_by for agent ${this.priorityAgentId}: ${
          error instanceof Error ? error.message : error
        }`
      );
      return 0;
    }
  }

  /**
   * Validates that the given priority ID is within the allowed hierarchy
   * (either the configured priorityId or one of its children)
   */
  private async validatePriorityAccess(priorityId: string): Promise<void> {
    if (priorityId === this.priorityId) {
      return; // Direct access to root priority is allowed
    }

    // Check if the priority is a child of the configured priority
    const { data, error } = await this.supabase
      .from("priority_child")
      .select("child_id")
      .eq("priority_id", this.priorityId)
      .eq("child_id", priorityId)
      .single();

    if (error || !data) {
      throw new Error(
        `Access denied: Priority ${priorityId} is not within ${this.priorityId}`
      );
    }
  }

  async createActivity(activity: NewActivity): Promise<Activity> {
    // Handle activity exceptions differently
    if (activity.recurrence && activity.occurrence) {
      return this.createActivityException(activity);
    }

    // Validate priority access
    const targetPriorityId = activity.priority?.id || this.priorityId;
    await this.validatePriorityAccess(targetPriorityId);

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
      author_id: this.priorityAgentId,
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
      source: activity.source ?? null,
      updated_by: this.getUpdatedBy(),
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

    // Handle path generation based on parentId
    if (activity.parent) {
      // Look up parent activity to get its path and priority
      const parentResult = await this.supabase
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
      await this.validatePriorityAccess(parentResult.data.priority_id);
      // Generate child path using database function
      const pathResult = await this.supabase.rpc("generate_path", {
        parent: parentResult.data.path,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbActivity.path = pathResult.data;
    }

    const dbResult = safeQuery(
      await this.supabase.from("activity").insert(dbActivity).select().single()
    );

    // Fetch the created activity with author information
    const { data: activityWithAuthor, error: fetchError } = await this.supabase
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
      throw new Error(
        `Failed to fetch created activity: ${fetchError.message}`
      );
    }

    return fromDbActivity(
      activityWithAuthor as any as Database["public"]["Tables"]["activity"]["Row"] & {
        author: {
          id: string;
          name: string;
          type: string;
        };
      }
    );
  }

  async getThread(activity: Activity): Promise<Activity[]> {
    try {
      // Validate access to the priority
      await this.validatePriorityAccess(activity.priority.id);

      // The activity_thread RPC function now includes actor data directly
      const { data, error } = await this.supabase
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
      return data.map((row) =>
        fromDbActivity(
          row as any as Database["public"]["Tables"]["activity"]["Row"] & {
            author: {
              id: string;
              name: string;
              type: string;
            };
          }
        )
      );
    } catch (err) {
      console.error("Failed to get activities:", err);
      throw err;
    }
  }

  async getActivityBySource(source: ActivitySource): Promise<Activity | null> {
    try {
      // Query activities with matching source fields using the user_activity view
      // This view automatically filters to activities the user has access to
      // We use a JSON containment operator to check if the provided source is contained in the stored source
      const { data, error } = await this.supabase
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
        .contains("source", source)
        .limit(1)
        .single();

      if (error) {
        if (error.code === "PGRST116") {
          // No rows found
          return null;
        }
        throw error;
      }

      return fromDbActivity(
        data as any as Database["public"]["Tables"]["activity"]["Row"] & {
          author: {
            id: string;
            name: string;
            type: string;
          };
        }
      );
    } catch (err) {
      console.error("Failed to get activity by source:", err);
      throw err;
    }
  }

  async createPriority(priority: NewPriority): Promise<Priority> {
    if (!priority.parentId) {
      priority.parentId = this.priorityId;
    }

    // Validate access to the parent priority
    await this.validatePriorityAccess(priority.parentId);

    const parentResult = await this.supabase
      .from("priority")
      .select("path, created_by")
      .eq("id", priority.parentId)
      .single();

    if (parentResult.error) {
      throw new Error(
        `Parent priority not found: ${parentResult.error.message}`
      );
    }

    // Generate child path using database function
    const pathResult = await this.supabase.rpc("generate_path", {
      parent: parentResult.data.path,
    });

    if (pathResult.error) {
      throw new Error(`Path generation failed: ${pathResult.error.message}`);
    }

    const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
      created_by: parentResult.data.created_by,
      title: priority.title,
      path: pathResult.data,
      updated_by: this.getUpdatedBy(),
    };

    const result = await this.supabase
      .from("priority")
      .insert(dbPriority)
      .select()
      .single();

    if (result.error) {
      throw new Error(`Priority creation failed: ${result.error.message}`);
    }

    return fromDbPriority(result.data);
  }

  private normalizeName(name: string | undefined | null): string | undefined {
    if (!name) return undefined;
    name = name.replace(/<?[^ ]+@[^ ]+>?/, "").trim();
    name = name.replace(/^([^, ]+),\s*(.+)/, "$2 $1");
    return name;
  }

  async addContacts(
    contacts: Array<{ email: string; name?: string; avatar?: string }>
  ): Promise<void> {
    if (contacts.length === 0) return;

    const normalizedContacts = contacts.map((contact) => ({
      email: contact.email.toLowerCase(),
      name: this.normalizeName(contact.name),
      avatar: contact.avatar,
    }));

    const contactsToUpsert = normalizedContacts.map((contact) => ({
      email: contact.email,
      name: contact.name || null,
      avatar_url: contact.avatar || null,
    }));

    const result = await this.supabase
      .from("contact")
      .upsert(contactsToUpsert, { onConflict: "user_id,email" });

    if (result.error) {
      throw new Error(`Failed to upsert contacts: ${result.error.message}`);
    }

    console.log(`Successfully upserted ${contacts.length} contacts`);
  }

  async createActivities(activities: NewActivity[]): Promise<Activity[]> {
    if (activities.length === 0) {
      return [];
    }

    // Convert all activities to database format
    const dbActivities: Database["public"]["Tables"]["activity"]["Insert"][] =
      [];

    for (const activity of activities) {
      // Skip activity exceptions for batch operations
      if (activity.recurrence && activity.occurrence) {
        throw new Error(
          "Activity exceptions are not supported in batch creation"
        );
      }

      // Validate priority access
      const targetPriorityId = activity.priority?.id || this.priorityId;
      await this.validatePriorityAccess(targetPriorityId);

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
        author_id: this.priorityAgentId,
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
        source: activity.source ?? null,
        updated_by: this.getUpdatedBy(),
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
        const parentResult = await this.supabase
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
        await this.validatePriorityAccess(parentResult.data.priority_id);
        // Generate child path using database function
        const pathResult = await this.supabase.rpc("generate_path", {
          parent: parentResult.data.path,
        });

        if (pathResult.error) {
          throw new Error(
            `Path generation failed: ${pathResult.error.message}`
          );
        }

        dbActivity.path = pathResult.data;
      }

      dbActivities.push(dbActivity);
    }

    // Batch insert all activities
    const dbResult = safeQuery(
      await this.supabase.from("activity").insert(dbActivities).select()
    );

    // Fetch all created activities with author information
    const activityIds = dbResult.map((a: any) => a.id);
    const { data: activitiesWithAuthor, error: fetchError } =
      await this.supabase
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

    return activitiesWithAuthor.map((activityWithAuthor) =>
      fromDbActivity(
        activityWithAuthor as any as Database["public"]["Tables"]["activity"]["Row"] & {
          author: {
            id: string;
            name: string;
            type: string;
          };
        }
      )
    );
  }

  private async createActivityException(
    activity: NewActivity
  ): Promise<Activity> {
    if (!activity.recurrence || !activity.occurrence) {
      throw new Error(
        "Activity exception requires both recurrence and occurrence"
      );
    }

    // Validate access to the recurrence activity
    await this.validatePriorityAccess(activity.recurrence.priority.id);

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
        source: activity.source ?? null,
        updated_by: this.getUpdatedBy(),
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

    const result = await this.supabase
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
      source: activity.source ?? null,
    };
  }
}
