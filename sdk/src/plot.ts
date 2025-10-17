import { type Tag } from "./tag";

export { Tag } from "./tag";

/**
 * Represents a priority context within Plot.
 *
 * Priorities are organizational units that group related activities and agents.
 * They serve as the primary context for agent activation and activity management.
 */
export type Priority = {
  /** Unique identifier for the priority */
  id: string;
  /** Human-readable title for the priority */
  title: string;
};

/**
 * Type for creating new priorities.
 *
 * Excludes the auto-generated ID field and adds an optional parentId
 * for creating hierarchical priority structures.
 */
export type NewPriority = Omit<Priority, "id"> & {
  /** Optional ID of the parent priority for creating hierarchies */
  parentId?: string;
};

/**
 * Enumeration of supported activity types in Plot.
 *
 * Each activity type has different behaviors and rendering characteristics
 * within the Plot application.
 */
export enum ActivityType {
  /** A note or piece of information without actionable requirements */
  Note,
  /** An actionable item that can be completed */
  Task,
  /** A scheduled occurrence with start and optional end time */
  Event,
}

/**
 * Enumeration of author types that can create activities.
 *
 * The author type affects how activities are displayed and processed
 * within the Plot system.
 */
export enum AuthorType {
  /** Activities created by human users */
  User,
  /** Activities created by external contacts */
  Contact,
  /** Activities created by automated agents */
  Agent,
}

/**
 * Enumeration of supported activity link types.
 *
 * Different link types have different behaviors when clicked by users
 * and may require different rendering approaches.
 */
export enum ActivityLinkType {
  /** External web links that open in browser */
  external = "external",
  /** Authentication flows for connecting services */
  auth = "auth",
  /** Links that are not visible to users but can be used to track associations */
  hidden = "hidden",
  /** Callback links that trigger agent methods when clicked */
  callback = "callback",
}

/**
 * Represents a clickable link attached to an activity.
 *
 * Activity links are rendered as buttons that enable user interaction with activities.
 * Different link types have specific behaviors and required fields for proper functionality.
 *
 * @example
 * ```typescript
 * // External link - opens URL in browser
 * const externalLink: ActivityLink = {
 *   type: ActivityLinkType.external,
 *   title: "Open in Google Calendar",
 *   url: "https://calendar.google.com/event/123",
 * };
 *
 * // Auth link - initiates OAuth flow
 * const authLink: ActivityLink = {
 *   type: ActivityLinkType.auth,
 *   title: "Continue with Google",
 *   provider: AuthProvider.Google,
 *   level: AuthLevel.User,
 *   scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
 *   callback: "callback-token-for-auth-completion"
 * };
 *
 * // Callback link - triggers agent method
 * const callbackLink: ActivityLink = {
 *   type: ActivityLinkType.callback,
 *   title: "📅 Primary Calendar",
 *   token: "callback-token-here"
 * };
 *
 * // Hidden link - invisible but functional
 * const hiddenLink: ActivityLink = {
 *   type: ActivityLinkType.hidden,
 *   metadata: { purpose: "tracking" }
 * };
 * ```
 */
export type ActivityLink =
  | {
      /** External web link that opens in browser */
      type: ActivityLinkType.external;
      /** Display text for the link button */
      title: string;
      /** URL to open when clicked */
      url: string;
    }
  | {
      /** Authentication link that initiates an OAuth flow */
      type: ActivityLinkType.auth;
      /** Display text for the auth button */
      title: string;
      /** OAuth provider (e.g., "google", "microsoft") */
      provider: string;
      /** Authorization level ("user" or "priority") */
      level: string;
      /** Array of OAuth scopes to request */
      scopes: string[];
      /** Callback token for auth completion notification */
      callback: string;
    }
  | {
      /** Hidden link not visible to users but may trigger actions */
      type: ActivityLinkType.hidden;
      /** Arbitrary properties for hidden functionality */
      [key: string]: any;
    }
  | {
      /** Callback link that triggers agent method when clicked */
      type: ActivityLinkType.callback;
      /** Display text for the callback button */
      title: string;
      /** Token identifying the callback to execute */
      token: string;
    };

/**
 * Represents the source of an activity from an external system.
 *
 * Activity sources enable tracking where activities originated from,
 * which is useful for synchronization, deduplication, and linking
 * back to external systems.
 *
 * @example
 * ```typescript
 * const googleCalendarSource: ActivitySource = {
 *   type: "google-calendar-event",
 *   id: "event-123",
 *   calendarId: "primary",
 *   htmlLink: "https://calendar.google.com/event/123"
 * };
 * ```
 */
export type ActivitySource = {
  /** The type identifier for the source system */
  type: string;
  /** Additional source-specific properties */
  [key: string]: any;
};

/**
 * Represents a complete activity within the Plot system.
 *
 * Activities are the core entities in Plot, representing anything from simple notes
 * to complex recurring events. They support rich metadata including scheduling,
 * recurrence patterns, links, and external source tracking.
 *
 * @example
 * ```typescript
 * // Simple task
 * const task: Activity = {
 *   id: "task-123",
 *   type: ActivityType.Task,
 *   title: "Review pull request",
 *   author: { id: "user-1", name: "John Doe", type: AuthorType.User },
 *   start: new Date(),
 *   end: null,
 *   priority: { id: "work", title: "Work" },
 *   // ... other fields
 * };
 *
 * // Recurring event
 * const meeting: Activity = {
 *   id: "meeting-456",
 *   type: ActivityType.Event,
 *   title: "Weekly standup",
 *   recurrenceRule: "FREQ=WEEKLY;BYDAY=MO",
 *   recurrenceCount: 12,
 *   // ... other fields
 * };
 * ```
 */
export type Activity = {
  /** Unique identifier for the activity */
  id: string;
  /** The type of activity (Note, Task, or Event) */
  type: ActivityType;
  /** Information about who created the activity */
  author: {
    /** Unique identifier for the author */
    id: string;
    /** Display name for the author */
    name: string | null;
    /** Type of author (User, Contact, or Agent) */
    type: AuthorType;
  };
  /**
   * Start time of a scheduled activity.
   * For recurring events, this represents the start of the first occurrence.
   * Can be a Date object for timed events or a date string in "YYYY-MM-DD" format for all-day events.
   * Null for activities without scheduled start times.
   */
  start: Date | string | null;
  /**
   * End time of a scheduled activity.
   * For recurring events, this represents the end of the first occurrence.
   * Can be a Date object for timed events or a date string in "YYYY-MM-DD" format for all-day events.
   * Null for tasks or activities without defined end times.
   */
  end: Date | string | null;
  /**
   * For recurring activities, the last occurrence date (inclusive).
   * Can be a Date object, date string in "YYYY-MM-DD" format, or null if recurring indefinitely.
   * When both recurrenceCount and recurrenceUntil are provided, recurrenceCount takes precedence.
   */
  recurrenceUntil: Date | string | null;
  /**
   * For recurring activities, the number of occurrences to generate.
   * Takes precedence over recurrenceUntil if both are provided.
   * Null for non-recurring activities or indefinite recurrence.
   */
  recurrenceCount: number | null;
  /** Timestamp when the activity was marked as complete. Null if not completed. */
  doneAt: Date | null;
  /** Optional detailed description or notes for the activity */
  note: string | null;
  /** The display title/summary of the activity */
  title: string | null;
  /** Reference to a parent activity for creating hierarchical relationships */
  parent: Activity | null;
  /** Array of interactive links attached to the activity */
  links: Array<ActivityLink> | null;
  /** The priority context this activity belongs to */
  priority: Priority;
  /** Recurrence rule in RFC 5545 RRULE format (e.g., "FREQ=WEEKLY;BYDAY=MO,WE,FR") */
  recurrenceRule: string | null;
  /** Array of dates to exclude from the recurrence pattern */
  recurrenceExdates: Date[] | null;
  /** Array of additional occurrence dates to include in the recurrence pattern */
  recurrenceDates: Date[] | null;
  /**
   * For recurring event exceptions, points to the root recurring activity.
   * Used when an individual occurrence of a recurring event is modified.
   */
  recurrence: Activity | null;
  /**
   * For recurring event exceptions, the original occurrence date being overridden.
   * Used to identify which occurrence of a recurring event this exception replaces.
   */
  occurrence: Date | null;
  /** Reference to the external system that created this activity */
  source: ActivitySource | null;
  /** Tags attached to this activity. Maps tag ID to array of actor IDs who added that tag. */
  tags: Partial<Record<Tag, string[]>> | null;
};

/**
 * Type for creating new activities.
 *
 * Requires only the activity type, with all other fields optional.
 * The ID and author will be automatically assigned by the Plot system
 * based on the current execution context.
 *
 * @example
 * ```typescript
 * const newTask: NewActivity = {
 *   type: ActivityType.Task,
 *   title: "Review pull request",
 *   start: new Date(),
 *   links: [{
 *     title: "View PR",
 *     type: ActivityLinkType.external,
 *     url: "https://github.com/org/repo/pull/123"
 *   }]
 * };
 * ```
 */
export type NewActivity = Pick<Activity, "type"> &
  Partial<
    Omit<Activity, "id" | "author" | "type" | "parent"> & {
      parent?: Pick<Activity, "id"> | null;
    }
  >;

export type ActivityUpdate = Pick<Activity, "id"> &
  Partial<
    Pick<
      Activity,
      | "type"
      | "start"
      | "end"
      | "doneAt"
      | "note"
      | "title"
      | "source"
      | "links"
      | "recurrenceRule"
      | "recurrenceDates"
      | "recurrenceExdates"
      | "recurrenceUntil"
      | "recurrenceCount"
      | "occurrence"
    >
  > & {
    parent?: Pick<Activity, "id"> | null;
  } & {
    // Add or remove tags by ID (others are unchanged)
    tags?: Partial<Record<Tag, boolean>>;
  };

/**
 * Represents contact information for a person.
 *
 * Contacts are used throughout Plot for representing people associated
 * with activities, such as event attendees or task assignees.
 *
 * @example
 * ```typescript
 * const contact: Contact = {
 *   email: "john.doe@example.com",
 *   name: "John Doe",
 *   avatar: "https://avatar.example.com/john.jpg"
 * };
 * ```
 */
export type Contact = {
  /** Email address of the contact (required) */
  email: string;
  /** Optional display name for the contact */
  name?: string;
  /** Optional avatar image URL for the contact */
  avatar?: string;
};
