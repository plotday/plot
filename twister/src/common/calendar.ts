import type { NewThreadWithNotes, Serializable } from "../index";

/**
 * Represents a calendar from an external calendar service.
 *
 * Contains metadata about a specific calendar that can be synced
 * with Plot. Different calendar providers may have additional
 * provider-specific properties.
 */
export type Calendar = {
  /** Unique identifier for the calendar within the provider */
  id: string;
  /** Human-readable name of the calendar */
  name: string;
  /** Optional description or additional details about the calendar */
  description: string | null;
  /** Whether this is the user's primary/default calendar */
  primary: boolean;
};

/**
 * Configuration options for calendar synchronization.
 *
 * Controls the time range and other parameters for calendar sync operations.
 * Used to limit sync scope and optimize performance.
 */
export type SyncOptions = {
  /**
   * Earliest date to sync events from (inclusive).
   * - If undefined: defaults to 2 years in the past
   * - If null: syncs all history from the beginning of time
   * - If Date: syncs from the specified date
   */
  timeMin?: Date | null;
  /**
   * Latest date to sync events to (exclusive).
   * - If undefined: no limit (syncs all future events)
   * - If null: no limit (syncs all future events)
   * - If Date: syncs up to but not including the specified date
   *
   * Use cases:
   * - Daily digest: Set to end of today
   * - Week view: Set to end of current week
   * - Performance: Limit initial sync range
   */
  timeMax?: Date | null;
};

/**
 * Base interface for calendar integration tools.
 *
 * Defines the standard operations that all calendar tools must implement
 * to integrate with external calendar services like Google Calendar,
 * Outlook Calendar, etc.
 *
 * **Architecture: Tools Build, Twists Save**
 *
 * Calendar tools follow Plot's core architectural principle:
 * - **Tools**: Fetch external data and transform it into Plot format (NewThread objects)
 * - **Twists**: Receive the data and decide what to do with it (create, update, filter, etc.)
 *
 * This separation allows:
 * - Tools to be reusable across different twists with different behaviors
 * - Twists to have full control over what gets saved and how
 * - Easier testing of tools in isolation
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Tool declares providers and lifecycle callbacks in build()
 * 3. onAuthorized lists available calendars and calls setSyncables()
 * 4. User enables calendars in the modal → onSyncEnabled fires
 * 5. **Tool builds NewThread objects** and passes them to the twist via callback
 * 6. **Twist decides** whether to save using createThread/updateThread
 *
 * **Tool Implementation Rules:**
 * - **DO** build Thread/Note objects from external data
 * - **DO** pass them to the twist via the callback
 * - **DON'T** call plot.createThread/updateThread directly
 * - **DON'T** save anything to Plot database
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source and Note.key for automatic upserts without manual ID tracking.
 * See SYNC_STRATEGIES.md for detailed patterns and when to use alternative approaches.
 *
 * @example
 * ```typescript
 * class MyCalendarTwist extends Twist {
 *   build(build: ToolBuilder) {
 *     return {
 *       googleCalendar: build(GoogleCalendar),
 *       plot: build(Plot, { thread: { access: ThreadAccess.Create } }),
 *     };
 *   }
 *
 *   // Auth and calendar selection handled in the twist edit modal.
 *   // Events are delivered via the startSync callback.
 * }
 * ```
 */
export type CalendarTool = {
  /**
   * Retrieves the list of calendars accessible to the authenticated user.
   *
   * @param calendarId - A calendar ID to use for auth lookup
   * @returns Promise resolving to array of available calendars
   * @throws When no valid authorization is available
   */
  getCalendars(calendarId: string): Promise<Calendar[]>;

  /**
   * Begins synchronizing events from a specific calendar.
   *
   * Sets up real-time sync for the specified calendar, including initial
   * event import and ongoing change notifications. The callback function
   * will be invoked for each synced event.
   *
   * Auth is obtained automatically via integrations.get(provider, calendarId).
   *
   * @param options - Sync configuration options
   * @param options.calendarId - ID of the calendar to sync
   * @param options.timeMin - Earliest date to sync events from (inclusive)
   * @param options.timeMax - Latest date to sync events to (exclusive)
   * @param callback - Function receiving (thread, ...extraArgs) for each synced event
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   * @throws When no valid authorization or calendar doesn't exist
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (thread: NewThreadWithNotes, ...args: TArgs) => any
  >(
    options: {
      calendarId: string;
    } & SyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

  /**
   * Stops synchronizing events from a specific calendar.
   *
   * @param calendarId - ID of the calendar to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(calendarId: string): Promise<void>;
};
