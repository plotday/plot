import type { ActivityLink, Callback } from "../index";

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
export interface Calendar {
  /** Unique identifier for the calendar within the provider */
  id: string;
  /** Human-readable name of the calendar */
  name: string;
  /** Optional description or additional details about the calendar */
  description: string | null;
  /** Whether this is the user's primary/default calendar */
  primary: boolean;
}

/**
 * Configuration options for calendar synchronization.
 *
 * Controls the time range and other parameters for calendar sync operations.
 * Used to limit sync scope and optimize performance.
 */
export interface SyncOptions {
  /** Earliest date to sync events from (inclusive) */
  timeMin?: Date;
  /** Latest date to sync events to (exclusive) */
  timeMax?: Date;
}

/**
 * Base interface for calendar integration tools.
 *
 * Defines the standard operations that all calendar tools must implement
 * to integrate with external calendar services like Google Calendar,
 * Outlook Calendar, etc.
 *
 * **Implementation Pattern:**
 * 1. Request an ActivityLink for authorization
 * 2. Create an Activity with the ActivityLink to prompt user
 * 3. Receive a CalendarAuth in the specified callback
 * 4. Fetch list of available calendars
 * 5. Start sync for selected calendars
 * 6. Process incoming events via callbacks
 *
 * @example
 * ```typescript
 * // Typical calendar integration flow
 * class MyCalendarAgent extends Agent {
 *   private googleCalendar: GoogleCalendar;
 *
 *   async activate() {
 *     // Step 1: Request authorization
 *     const authLink = await this.googleCalendar.requestAuth("onAuthComplete");
 *     await this.plot.createActivity({
 *       type: ActivityType.Task,
 *       title: "Connect Google Calendar",
 *       links: [authLink],
 *       start: new Date(),
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
 *         auth.authToken,
 *         primaryCalendar.id,
 *         "onCalendarEvent"
 *       );
 *     }
 *   }
 *
 *   async onCalendarEvent(activity: Activity) {
 *     // Step 4: Process synced events
 *     await this.plot.createActivity(activity);
 *   }
 * }
 * ```
 */
export interface CalendarTool {
  /**
   * Initiates the authorization flow for the calendar service.
   *
   * @param callback - Function to call when auth completes. The ActivityLink is passed to the callback.
   * @returns Promise resolving to an ActivityLink to initiate the auth flow
   */
  requestAuth(callback: Callback): Promise<ActivityLink>;

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
   * @param authToken - Authorization token for calendar access
   * @param calendarId - ID of the calendar to sync
   * @param callback - Function to call for each synced event
   * @param options - Optional sync configuration
   * @returns Promise that resolves when sync setup is complete
   * @throws When auth token is invalid or calendar doesn't exist
   */
  startSync(
    authToken: string,
    calendarId: string,
    callback: Callback,
    options?: SyncOptions
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
}
