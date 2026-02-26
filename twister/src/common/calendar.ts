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
 * Base interface for calendar integration sources.
 *
 * Defines the standard operations that all calendar sources must implement
 * to integrate with external calendar services like Google Calendar,
 * Outlook Calendar, etc.
 *
 * Sources save threads directly via `integrations.saveThread()` rather than
 * passing data through callbacks to a separate twist.
 *
 * **Implementation Pattern:**
 * 1. Authorization is handled via the twist edit modal (Integrations provider config)
 * 2. Source declares providers and lifecycle callbacks in build()
 * 3. getChannels returns available calendars
 * 4. User enables calendars in the modal -> onChannelEnabled fires
 * 5. Source fetches events and saves them directly via integrations.saveThread()
 *
 * **Recommended Data Sync Strategy:**
 * Use Thread.source and Note.key for automatic upserts without manual ID tracking.
 * See SYNC_STRATEGIES.md for detailed patterns and when to use alternative approaches.
 *
 * @example
 * ```typescript
 * class MyCalendarSource extends Source<MyCalendarSource> {
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations, {
 *         providers: [{
 *           provider: AuthProvider.Google,
 *           scopes: MyCalendarSource.SCOPES,
 *           getChannels: this.getChannels,
 *           onChannelEnabled: this.onChannelEnabled,
 *           onChannelDisabled: this.onChannelDisabled,
 *         }]
 *       }),
 *     };
 *   }
 * }
 * ```
 */
export type CalendarSource = {
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
   * event import and ongoing change notifications. Events are saved
   * directly via integrations.saveThread().
   *
   * Auth is obtained automatically via integrations.get(provider, calendarId).
   *
   * @param options - Sync configuration options
   * @param options.calendarId - ID of the calendar to sync
   * @param options.timeMin - Earliest date to sync events from (inclusive)
   * @param options.timeMax - Latest date to sync events to (exclusive)
   * @returns Promise that resolves when sync setup is complete
   * @throws When no valid authorization or calendar doesn't exist
   */
  startSync(
    options: {
      calendarId: string;
    } & SyncOptions,
  ): Promise<void>;

  /**
   * Stops synchronizing events from a specific calendar.
   *
   * @param calendarId - ID of the calendar to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(calendarId: string): Promise<void>;
};
