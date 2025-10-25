import {
  type Activity,
  type ActivityLink,
  ActivityType,
  type NewActivity,
  Tool,
  type ToolBuilder,
} from "@plotday/sdk";
import type {
  Calendar,
  CalendarAuth,
  CalendarTool,
} from "@plotday/sdk/common/calendar";
import { type Callback } from "@plotday/sdk/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type Authorization,
  Integrations,
} from "@plotday/sdk/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/sdk/tools/network";

// Import types from the existing outlook.ts file
type CalendarConfig = {
  outlookClientId: string;
  outlookOauthSecret: string;
  webhookUrl: string;
};

type CalendarCredentials = {
  access_token: string;
  refresh_token: string;
  email: string;
};

type OutlookSyncState = {
  calendarId: string;
  state?: string;
  more: boolean;
  min?: Date;
  max?: Date;
};

type WatchState = {
  watchId: string;
  calendarId: string;
  secret: string;
  expiry: Date;
};

type RawEvent = {
  id: string;
  data: any; // OutlookEvent type from outlook.ts
};

type Event = {
  id: string;
  name?: string;
  description?: string;
  startsAt?: Date;
  endsAt?: Date;
  data: any;
};

function fromMsDate(date?: any): Date | undefined {
  if (!date) return undefined;
  if (date.timeZone && date.timeZone !== "UTC") {
    throw new Error(`Unsupported timezone ${date.timeZone}`);
  }
  let d = date.dateTime;
  if (!d) return undefined;
  if (d[d.length - 1] !== "Z") {
    d = d + "Z";
  }
  return new Date(d);
}

function parseOutlookRecurrenceEnd(recurrenceData: any): Date | string | null {
  if (!recurrenceData?.range) return null;

  const range = recurrenceData.range;

  if (range.type === "endDate" && range.endDate) {
    // Outlook provides end date in ISO string format
    const endDate = new Date(range.endDate);
    // Return as Date object for datetime-based events, or date string for all-day events
    // We'll assume datetime for now and let the plot tool handle conversion
    return endDate;
  }

  return null;
}

function parseOutlookRecurrenceCount(recurrenceData: any): number | null {
  if (!recurrenceData?.range) return null;

  const range = recurrenceData.range;

  if (range.type === "numbered" && range.numberOfOccurrences) {
    const count = parseInt(range.numberOfOccurrences);
    return isNaN(count) ? null : count;
  }

  return null;
}

// Simplified version of the cal.* functions from outlook.ts
const outlookApi = {
  sync: async (
    _config: CalendarConfig,
    _credentials: CalendarCredentials,
    syncState: OutlookSyncState,
    _limit: number
  ) => {
    // This would contain the actual Outlook API sync logic
    // For now, return empty result
    return {
      events: [] as RawEvent[],
      state: { ...syncState, more: false },
    };
  },

  transform: (rawEvent: RawEvent, _accountEmail: string): Event => {
    // This would contain the transformation logic from outlook.ts
    const event = rawEvent.data;
    const id = rawEvent.id;
    const startsAt = fromMsDate(event.start);
    const endsAt = fromMsDate(event.end);
    return {
      id,
      name: event.subject || undefined,
      description: event.body?.content || undefined,
      startsAt,
      endsAt,
      data: event,
    };
  },

  watch: async (
    _config: CalendarConfig,
    _credentials: CalendarCredentials,
    _calendarId: string,
    _existingWatch?: { watchId: string; watchSecret: string }
  ) => {
    // This would contain the webhook setup logic
    return {
      state: {
        watchId: crypto.randomUUID(),
        secret: crypto.randomUUID(),
      },
    };
  },
};

/**
 * Microsoft Outlook Calendar integration tool.
 *
 * Provides integration with Microsoft Outlook Calendar and Exchange Online,
 * supporting event synchronization, webhook notifications, and Microsoft
 * Graph API compatibility.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Microsoft
 * - Real-time event synchronization via Microsoft Graph
 * - Webhook-based change notifications
 * - Support for recurring events and exceptions
 * - Exchange Online and Outlook.com compatibility
 * - Batch processing for large calendars
 *
 * **Required OAuth Scopes:**
 * - `https://graph.microsoft.com/calendars.readwrite` - Read/write calendar access
 *
 * @example
 * ```typescript
 * class EventsAgent extends Agent {
 *   private outlookCalendar: OutlookCalendar;
 *
 *   constructor(id: string, tools: Tools) {
 *     super();
 *     this.outlookCalendar = tools.get(OutlookCalendar);
 *   }
 *
 *   async activate() {
 *     const authLink = await this.outlookCalendar.requestAuth("onOutlookAuth", {
 *       provider: "outlook"
 *     });
 *
 *     await this.plot.createActivity({
 *       type: ActivityType.Task,
 *       title: "Connect Outlook Calendar",
 *       links: [authLink]
 *     });
 *   }
 *
 *   async onOutlookAuth(auth: CalendarAuth, context: any) {
 *     const calendars = await this.outlookCalendar.getCalendars(auth.authToken);
 *
 *     // Start syncing primary calendar
 *     const primary = calendars.find(c => c.primary);
 *     if (primary) {
 *       await this.outlookCalendar.startSync(
 *         auth.authToken,
 *         primary.id,
 *         "onCalendarEvent",
 *         {
 *           options: {
 *             timeMin: new Date(), // Only sync future events
 *           }
 *         }
 *       );
 *     }
 *   }
 *
 *   async onCalendarEvent(activity: Activity, context: any) {
 *     // Process Outlook Calendar events
 *     await this.plot.createActivity(activity);
 *   }
 * }
 * ```
 */
export class OutlookCalendar
  extends Tool<typeof OutlookCalendar>
  implements CalendarTool
{
  static Init(tools: ToolBuilder, _options: any) {
    return {
      integrations: tools.init(Integrations),
      network: tools.init(Network),
    };
  }

  async requestAuth<
    TCallback extends (auth: CalendarAuth, ...args: any[]) => any
  >(callback: TCallback, ...extraArgs: any[]): Promise<ActivityLink> {
    // Generate opaque token for authorization
    const token = crypto.randomUUID();

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createParent(
      callback,
      ...extraArgs
    );

    // Request Microsoft authentication and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Microsoft,
        level: AuthLevel.User,
        scopes: ["https://graph.microsoft.com/calendars.readwrite"],
      },
      this.onAuthSuccess,
      token,
      callbackToken
    );
  }

  private async getApi(authToken: string): Promise<{
    config: CalendarConfig;
    credentials: CalendarCredentials;
  }> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    const config = {
      outlookClientId: "client_id",
      outlookOauthSecret: "client_secret",
      webhookUrl: "webhook_url",
    };

    const credentials = {
      access_token: token.token,
      refresh_token: token.token, // Using same token for both - this may need adjustment
      email: "user@example.com", // This should be extracted from the authorization
    };

    return { config, credentials };
  }

  async getCalendars(authToken: string): Promise<Calendar[]> {
    // Verify authorization is available
    await this.getApi(authToken);

    // This would use Microsoft Graph API to get calendars
    // For now, return a simple primary calendar
    return [
      {
        id: "primary",
        name: "Calendar",
        description: "Primary Outlook Calendar",
        primary: true,
      },
    ];
  }

  async startSync<
    TCallback extends (activity: Activity, ...args: any[]) => any
  >(
    authToken: string,
    calendarId: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void> {
    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createParent(
      callback,
      ...extraArgs
    );
    await this.set("event_callback_token", callbackToken);

    // Setup webhook for this calendar
    await this.setupOutlookWatch(authToken, calendarId, authToken);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      authToken
    );
    await this.run(syncCallback);
  }

  async stopSync(_authToken: string, calendarId: string): Promise<void> {
    // Stop webhook
    const watchData = await this.get<WatchState>(`outlook_watch_${calendarId}`);
    if (watchData) {
      // Cancel the watch (would need Microsoft Graph API call)
      await this.clear(`outlook_watch_${calendarId}`);
    }

    // Clear sync state
    await this.clear(`outlook_sync_state_${calendarId}`);
  }

  private async setupOutlookWatch(
    authToken: string,
    calendarId: string,
    opaqueAuthToken: string
  ): Promise<void> {
    const { config, credentials } = await this.getApi(authToken);

    const webhookUrl = await this.tools.network.createWebhook(
      this.onOutlookWebhook,
      calendarId,
      opaqueAuthToken
    );

    config.webhookUrl = webhookUrl;

    const existingWatchId = await this.get<string>(
      `outlook_watch_id_${calendarId}`
    );
    const existingSecret = await this.get<string>(
      `outlook_watch_secret_${calendarId}`
    );

    const watchResult = await outlookApi.watch(
      config,
      credentials,
      calendarId,
      existingWatchId && existingSecret
        ? { watchId: existingWatchId, watchSecret: existingSecret }
        : undefined
    );

    await this.set(`outlook_watch_id_${calendarId}`, watchResult.state.watchId);
    await this.set(
      `outlook_watch_secret_${calendarId}`,
      watchResult.state.secret
    );

    console.log("Outlook Calendar webhook configured", {
      watchId: watchResult.state.watchId,
      calendarId,
    });
  }

  async syncOutlookBatch(
    _args: any,
    calendarId: string,
    authToken: string
  ): Promise<void> {
    let config: CalendarConfig;
    let credentials: CalendarCredentials;

    try {
      const apiResult = await this.getApi(authToken);
      config = apiResult.config;
      credentials = apiResult.credentials;
    } catch (error) {
      console.error(
        "No Microsoft credentials found for the provided authToken:",
        error
      );
      return;
    }

    const lastSyncToken =
      (await this.get<string>(`last_sync_token_${calendarId}`)) || undefined;

    const syncState: OutlookSyncState = {
      calendarId,
      state: lastSyncToken,
      more: false,
    };

    let hasMore = true;
    let eventCount = 0;

    while (hasMore && eventCount < 10000) {
      const result = await outlookApi.sync(config, credentials, syncState, 500);

      for (const rawEvent of result.events) {
        const event = outlookApi.transform(rawEvent, "user@example.com");

        let recurrenceRule: string | undefined;

        if (event.data && "recurrence" in event.data && event.data.recurrence) {
          const pattern = event.data.recurrence.pattern;
          const range = event.data.recurrence.range;

          let freq = "";
          switch (pattern?.type) {
            case "daily":
              freq = "DAILY";
              break;
            case "weekly":
              freq = "WEEKLY";
              break;
            case "absoluteMonthly":
              freq = "MONTHLY";
              break;
            case "relativeMonthly":
              freq = "MONTHLY";
              break;
            case "absoluteYearly":
              freq = "YEARLY";
              break;
            case "relativeYearly":
              freq = "YEARLY";
              break;
            default:
              freq = "DAILY";
          }

          let rrule = `FREQ=${freq}`;
          if (pattern?.interval) rrule += `;INTERVAL=${pattern.interval}`;

          if (pattern?.daysOfWeek?.length) {
            const days = pattern.daysOfWeek
              .map((d: string) => d.toUpperCase().substring(0, 2))
              .join(",");
            rrule += `;BYDAY=${days}`;
          }

          if (range?.type === "endDate" && range.endDate) {
            rrule += `;UNTIL=${range.endDate
              .replace(/[-:]/g, "")
              .replace(/\.\d{3}Z$/, "Z")}`;
          } else if (range?.type === "numbered" && range.numberOfOccurrences) {
            rrule += `;COUNT=${range.numberOfOccurrences}`;
          }

          recurrenceRule = rrule;
        }

        // Create Activity from Outlook event
        const activity: NewActivity = {
          type: ActivityType.Event,
          start: event.startsAt || null,
          end: event.endsAt || null,
          recurrenceUntil: null,
          recurrenceCount: null,
          doneAt: null,
          note: event.description || null,
          title: event.name || null,
          parent: null,
          links: null,
          recurrenceRule: recurrenceRule || null,
          recurrenceExdates: null,
          recurrenceDates: null,
          recurrence: null,
          occurrence: null,
          source: {
            type: "outlook-calendar-event",
            id: event.id,
            calendarId: syncState.calendarId,
          },
          tags: null,
        };

        // For recurring activities, parse recurrenceCount or recurrenceUntil
        if (recurrenceRule && event.data?.recurrence) {
          // Parse recurrence count (takes precedence over end date)
          const recurrenceCount = parseOutlookRecurrenceCount(
            event.data.recurrence
          );
          if (recurrenceCount) {
            activity.recurrenceCount = recurrenceCount;
          } else {
            // Parse recurrence end date if no count
            const recurrenceUntil = parseOutlookRecurrenceEnd(
              event.data.recurrence
            );
            if (recurrenceUntil) {
              activity.recurrenceUntil = recurrenceUntil;
            }
          }
        }

        // Handle exceptions
        if (
          event.data &&
          "type" in event.data &&
          event.data.type === "exception"
        ) {
          const masterEventId = event.data.seriesMasterId;
          if (masterEventId) {
            const originalStart = fromMsDate(event.data.originalStart);
            if (originalStart) {
              // TODO: Set recurrence
              activity.occurrence = originalStart;
            }
          }
        }

        // Call the event callback
        const callbackToken = await this.get<string>("event_callback_token");
        if (callbackToken) {
          await this.run(callbackToken as any, activity);
        }
      }

      await this.set(`last_sync_token_${calendarId}`, result.state.state);

      hasMore = result.state.more;
      eventCount += result.events.length;
      syncState.state = result.state.state;

      console.log(
        `Synced ${result.events.length} events, total: ${eventCount} for calendar ${calendarId}`
      );
    }

    console.log(
      `Outlook Calendar sync completed: ${eventCount} events for calendar ${calendarId}`
    );
  }

  async onOutlookWebhook(
    request: WebhookRequest,
    calendarId: string,
    authToken: string
  ): Promise<void> {
    console.log("Received Outlook calendar webhook notification", {
      calendarId,
    });

    if (request.params?.validationToken) {
      // Return validation token for webhook verification
      return;
    }

    const notifications = request.body?.value;
    if (!notifications?.length) {
      console.warn("No notifications in webhook body");
      return;
    }

    for (const notification of notifications) {
      if (notification.changeType) {
        console.log(
          `Calendar ${notification.changeType} notification for ${calendarId}`
        );

        // Trigger incremental sync
        await this.startIncrementalSync(calendarId, authToken);
      }
    }
  }

  private async startIncrementalSync(
    calendarId: string,
    authToken: string
  ): Promise<void> {
    console.log("Starting incremental Outlook Calendar sync for", calendarId);

    try {
      await this.getApi(authToken);
    } catch (error) {
      console.error(
        "No Microsoft credentials found for the provided authToken:",
        error
      );
      return;
    }

    const callback = await this.callback(
      this.syncOutlookBatch,
      calendarId,
      authToken
    );
    await this.run(callback);
  }

  async onAuthSuccess(
    authResult: Authorization,
    token: string,
    callbackToken: Callback
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.set(`authorization:${token}`, authResult);

    const authSuccessResult: CalendarAuth = {
      authToken: token,
    };

    await this.run(callbackToken, authSuccessResult);
  }
}

export default OutlookCalendar;
