import { createLogger } from "../../../utils/logger";

export function parseRangeStart(
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

export function parseInterval(interval: unknown): number | undefined {
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

export function formatInterval(durationSeconds: number): string {
  const hours = Math.floor(durationSeconds / 3600);
  const minutes = Math.floor((durationSeconds % 3600) / 60);
  const seconds = durationSeconds % 60;

  return `${hours.toString().padStart(2, "0")}:${minutes
    .toString()
    .padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
}

export function parseRangeEnd(
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

export function calculateRecurrenceUntil(
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

export function calculateRecurrenceUntilFromCount(
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
    const logger = createLogger();
    logger.warn("Failed to calculate recurrence until from count", { error_message: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

export function calculateDbEndFromRecurrenceUntil(
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

export function calculateDurationInSeconds(
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
