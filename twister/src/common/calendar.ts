import type { ActivityLink, NewActivityWithNotes, Serializable } from "../index";

/**
 * Represents successful calendar authorization.
 *
 * Returned by calendar tools when authorization completes successfully.
 * The auth token is an opaque identifier that can be used for subsequent
 * calendar operations.
 */
export type CalendarAuth = {
  /** Opaque token for calendar operations */
  authToken: string;
};

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
  /** Earliest date to sync events from (inclusive) */
  timeMin?: Date;
  /** Latest date to sync events to (exclusive) */
  timeMax?: Date;
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
 * - **Tools**: Fetch external data and transform it into Plot format (NewActivity objects)
 * - **Twists**: Receive the data and decide what to do with it (create, update, filter, etc.)
 *
 * This separation allows:
 * - Tools to be reusable across different twists with different behaviors
 * - Twists to have full control over what gets saved and how
 * - Easier testing of tools in isolation
 *
 * **Implementation Pattern:**
 * 1. Request an ActivityLink for authorization
 * 2. Create an Activity with the ActivityLink to prompt user (via twist)
 * 3. Receive a CalendarAuth in the specified callback
 * 4. Fetch list of available calendars
 * 5. Start sync for selected calendars
 * 6. **Tool builds NewActivity objects** and passes them to the twist via callback
 * 7. **Twist decides** whether to save using createActivity/updateActivity
 *
 * **Tool Implementation Rules:**
 * - **DO** build Activity/Note objects from external data
 * - **DO** pass them to the twist via the callback
 * - **DON'T** call plot.createActivity/updateActivity directly
 * - **DON'T** save anything to Plot database
 *
 * **Recommended Data Sync Strategy:**
 * Use Activity.source and Note.key for automatic upserts without manual ID tracking.
 * See SYNC_STRATEGIES.md for detailed patterns and when to use alternative approaches.
 *
 * @example
 * ```typescript
 * // Typical calendar integration flow using source/key upserts
 * class MyCalendarTwist extends Twist {
 *   private googleCalendar: GoogleCalendar;
 *
 *   async activate() {
 *     // Step 1: Request authorization
 *     const authLink = await this.googleCalendar.requestAuth("onAuthComplete");
 *     await this.plot.createActivity({
 *       type: ActivityType.Action,
 *       title: "Connect Google Calendar",
 *       links: [authLink],
 *     });
 *   }
 *
 *   async onAuthComplete(auth: CalendarAuth) {
 *     // Step 2: Get available calendars
 *     const calendars = await this.googleCalendar.getCalendars(auth.authToken);
 *
 *     // Step 3: Start sync for primary calendar
 *     const primaryCalendar = calendars.find(c => c.primary);
 *     if (primaryCalendar) {
 *       await this.googleCalendar.startSync(
 *         {
 *           authToken: auth.authToken,
 *           calendarId: primaryCalendar.id
 *         },
 *         this.onCalendarEvent,  // Callback receives data from tool
 *         { initialSync: true }
 *       );
 *     }
 *   }
 *
 *   async onCalendarEvent(
 *     activity: NewActivityWithNotes,
 *     syncMeta: { initialSync: boolean }
 *   ) {
 *     // Step 4: Twist decides what to do with the data
 *     // Tool built the NewActivity, twist saves it
 *     await this.plot.createActivity(activity);
 *   }
 * }
 * ```
 */
export type CalendarTool = {
  /**
   * Initiates the authorization flow for the calendar service.
   *
   * @param callback - Function receiving (auth, ...extraArgs) when auth completes
   * @param extraArgs - Additional arguments to pass to the callback (type-checked)
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth<
    TArgs extends Serializable[],
    TCallback extends (auth: CalendarAuth, ...args: TArgs) => any
  >(
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<ActivityLink>;

  /**
   * Retrieves the list of calendars accessible to the authenticated user.
   *
   * Returns metadata for all calendars the user has access to, including
   * their primary calendar and any shared calendars. This list can be
   * presented to users for calendar selection.
   *
   * @param authToken - Authorization token from successful auth flow
   * @returns Promise resolving to array of available calendars
   * @throws When the auth token is invalid or expired
   */
  getCalendars(authToken: string): Promise<Calendar[]>;

  /**
   * Begins synchronizing events from a specific calendar.
   *
   * Sets up real-time sync for the specified calendar, including initial
   * event import and ongoing change notifications. The callback function
   * will be invoked for each synced event.
   *
   * **Recommended Implementation** (Strategy 2 - Upsert via Source/Key):
   * - Set Activity.source to the event's canonical URL (e.g., event.htmlLink)
   * - Use Note.key for event details (description, attendees, etc.) to enable upserts
   * - No manual ID tracking needed - Plot handles deduplication automatically
   * - Send NewActivityWithNotes for all events (creates new or updates existing)
   * - Set activity.unread = false for initial sync, true for incremental updates
   *
   * **Alternative** (Strategy 3 - Advanced cases):
   * - Use Uuid.Generate() and store ID mappings when creating multiple activities per event
   * - See SYNC_STRATEGIES.md for when this is appropriate
   *
   * @param options - Sync configuration options
   * @param options.authToken - Authorization token for calendar access
   * @param options.calendarId - ID of the calendar to sync
   * @param options.timeMin - Earliest date to sync events from (inclusive)
   * @param options.timeMax - Latest date to sync events to (exclusive)
   * @param callback - Function receiving (activity, ...extraArgs) for each synced event
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise that resolves when sync setup is complete
   * @throws When auth token is invalid or calendar doesn't exist
   */
  startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      authToken: string;
      calendarId: string;
    } & SyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void>;

  /**
   * Stops synchronizing events from a specific calendar.
   *
   * Disables real-time sync and cleans up any webhooks or polling
   * mechanisms for the specified calendar. No further events will
   * be synced after this call.
   *
   * @param authToken - Authorization token for calendar access
   * @param calendarId - ID of the calendar to stop syncing
   * @returns Promise that resolves when sync is stopped
   */
  stopSync(authToken: string, calendarId: string): Promise<void>;
};
