import {
  type ActivityLink,
  type NewActivity,
  Tool,
  type Tools,
} from "../../sdk";
import {
  type Auth,
  AuthLevel,
  AuthProvider,
  type Authorization,
} from "../auth";
import type { Calendar, CalendarAuth, SyncOptions } from "../calendar";
import type { Callback, CallbackTool } from "../callback";
import type { Run } from "../run";
import type { Store } from "../store";
import type { Webhook, WebhookRequest } from "../webhook";
import {
  GoogleApi,
  type GoogleEvent,
  type SyncState,
  syncGoogleCalendar,
  transformGoogleEvent,
} from "./google-api";
import type { GoogleCalendar } from "./types";

type AuthSuccessContext = {
  authToken: string;
  callbackToken: Callback;
};

export default class extends Tool implements GoogleCalendar {
  private auth: Auth;
  private store: Store;
  private webhook: Webhook;
  private run: Run;
  private callback: CallbackTool;

  constructor(protected tools: Tools) {
    super();
    this.auth = tools.get("auth");
    this.store = tools.get("store");
    this.webhook = tools.get("webhook");
    this.run = tools.get("run");
    this.callback = tools.get("callback");
  }

  async requestAuth(callback: Callback): Promise<ActivityLink> {
    const calendarScopes = [
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      "https://www.googleapis.com/auth/calendar.events",
    ];

    // Generate opaque token for this authorization
    const authToken = crypto.randomUUID();

    // Use the provided callback token
    const callbackToken = callback;

    // Create callback for auth completion
    const authCallback = await this.callback.create("onAuthSuccess", {
      authToken,
      callbackToken,
    } satisfies AuthSuccessContext);

    // Request auth and return the activity link
    return await this.auth.request(
      {
        provider: AuthProvider.Google,
        level: AuthLevel.User,
        scopes: calendarScopes,
      },
      authCallback
    );
  }

  private async getApi(authToken: string): Promise<GoogleApi> {
    const authorization = await this.store.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.auth.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  async getCalendars(authToken: string): Promise<Calendar[]> {
    const api = await this.getApi(authToken);
    const data = (await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList"
    )) as {
      items: Array<{
        id: string;
        summary: string;
        description?: string;
        primary?: boolean;
      }>;
    };

    return data.items.map((item) => ({
      id: item.id,
      name: item.summary,
      description: item.description || null,
      primary: item.primary || false,
    }));
  }

  async startSync(
    authToken: string,
    calendarId: string,
    callback: Callback,
    options?: SyncOptions
  ): Promise<void> {
    // Store the callback token
    await this.store.set("event_callback_token", callback);

    // Setup webhook for this calendar
    await this.setupCalendarWatch(authToken, calendarId, authToken);

    // Start initial sync
    const now = new Date();
    const min = options?.timeMin || new Date(now.getFullYear() - 2, 0, 1);
    const max = options?.timeMax || new Date(now.getFullYear() + 1, 11, 31);

    const initialState: SyncState = {
      calendarId,
      min,
      max,
      sequence: 1,
    };

    await this.store.set(`sync_state_${calendarId}`, initialState);

    // Start sync batch using run tool for long-running operation
    await this.run.now("syncBatch", {
      calendarId,
      batchNumber: 1,
      mode: "full",
      authToken,
    });
  }

  async stopSync(authToken: string, calendarId: string): Promise<void> {
    // Stop webhook
    const watchData = await this.store.get<any>(`calendar_watch_${calendarId}`);
    if (watchData) {
      // Cancel the watch (would need Google API call)
      await this.store.clear(`calendar_watch_${calendarId}`);
    }

    // Clear sync state
    await this.store.clear(`sync_state_${calendarId}`);
  }

  private async setupCalendarWatch(
    authToken: string,
    calendarId: string,
    opaqueAuthToken: string
  ): Promise<void> {
    const webhookUrl = await this.webhook.create("onCalendarWebhook", {
      calendarId,
      authToken: opaqueAuthToken,
    });

    // Check if webhook URL is localhost
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      console.log("Skipping webhook setup for localhost URL");
      return;
    }

    const api = await this.getApi(authToken);

    // Setup watch for calendar
    const watchId = crypto.randomUUID();
    const secret = crypto.randomUUID();

    const watchData = (await api.call(
      "POST",
      `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/watch`,
      undefined,
      {
        id: watchId,
        type: "web_hook",
        address: webhookUrl,
        token: new URLSearchParams({ secret }).toString(),
      }
    )) as { expiration: string };

    await this.store.set(`calendar_watch_${calendarId}`, {
      watchId,
      secret,
      calendarId,
      expiry: new Date(parseInt(watchData.expiration)),
    });

    console.log("Calendar watch setup complete", { watchId, calendarId });
  }

  async syncBatch({
    calendarId,
    batchNumber,
    mode,
    authToken,
  }: {
    calendarId: string;
    batchNumber: number;
    mode: "full" | "incremental";
    authToken: string;
  }): Promise<void> {
    console.log(
      `Starting Google Calendar sync batch ${batchNumber} (${mode}) for calendar ${calendarId}`
    );

    try {
      const state = await this.store.get<SyncState>(`sync_state_${calendarId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      // Convert date strings back to Date objects after deserialization
      if (state.min && typeof state.min === "string") {
        state.min = new Date(state.min);
      }
      if (state.max && typeof state.max === "string") {
        state.max = new Date(state.max);
      }

      const api = await this.getApi(authToken);
      const result = await syncGoogleCalendar(api, calendarId, state);

      if (result.events.length > 0) {
        await this.processCalendarEvents(result.events, calendarId);
        console.log(
          `Synced ${result.events.length} events in batch ${batchNumber} for calendar ${calendarId}`
        );
      }

      await this.store.set(`sync_state_${calendarId}`, result.state);

      if (result.state.more) {
        await this.run.now("syncBatch", {
          calendarId,
          batchNumber: batchNumber + 1,
          mode,
          authToken,
        });
      } else {
        console.log(
          `Google Calendar ${mode} sync completed after ${batchNumber} batches for calendar ${calendarId}`
        );
        if (mode === "full") {
          await this.store.clear(`sync_state_${calendarId}`);
        }
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for calendar ${calendarId}:`,
        error
      );

      throw error;
    }
  }

  private async processCalendarEvents(
    events: GoogleEvent[],
    calendarId: string
  ): Promise<void> {
    for (const event of events) {
      try {
        if (event.status === "cancelled") {
          // TODO: Handle event cancellation
          continue;
        }

        // Check if this is a recurring event instance (exception)
        if (event.recurringEventId && event.originalStartTime) {
          await this.processEventException(event, calendarId);
        } else {
          // Regular or master recurring event
          const activityData = transformGoogleEvent(event, calendarId);

          // Convert to full Activity and call callback
          const callbackToken = await this.store.get<Callback>(
            "event_callback_token"
          );
          if (callbackToken && activityData.type) {
            const activity: NewActivity = {
              type: activityData.type,
              start: activityData.start || null,
              end: activityData.end || null,
              recurrenceUntil: activityData.recurrenceUntil || null,
              recurrenceCount: activityData.recurrenceCount || null,
              doneAt: null,
              note: activityData.note || null,
              title: activityData.title || null,
              parent: null,
              links: null,
              recurrenceRule: activityData.recurrenceRule || null,
              recurrenceExdates: activityData.recurrenceExdates || null,
              recurrenceDates: activityData.recurrenceDates || null,
              recurrence: null,
              occurrence: null,
              source: activityData.source || null,
            };

            await this.callback.call(callbackToken, activity);
          }
        }
      } catch (error) {
        console.error(`Failed to process event ${event.id}:`, error);
        // Continue processing other events
      }
    }
  }

  private async processEventException(
    event: GoogleEvent,
    calendarId: string
  ): Promise<void> {
    // Similar to processCalendarEvents but for exceptions
    // This would find the master recurring activity and create an exception
    const originalStartTime =
      event.originalStartTime?.dateTime || event.originalStartTime?.date;
    if (!originalStartTime) {
      console.warn(`No original start time for exception: ${event.id}`);
      return;
    }

    const activityData = transformGoogleEvent(event, calendarId);

    const callbackToken = await this.store.get<Callback>(
      "event_callback_token"
    );
    if (callbackToken && activityData.type) {
      const activity: NewActivity = {
        type: activityData.type,
        start: activityData.start || null,
        end: activityData.end || null,
        recurrenceUntil: activityData.recurrenceUntil || null,
        recurrenceCount: activityData.recurrenceCount || null,
        doneAt: null,
        note: activityData.note || null,
        title: activityData.title || null,
        parent: null,
        links: null,
        recurrenceRule: null,
        recurrenceExdates: null,
        recurrenceDates: null,
        recurrence: null, // Would need to find master activity
        occurrence: new Date(originalStartTime),
        source: activityData.source || null,
      };

      await this.callback.call(callbackToken, activity);
    }
  }

  async onCalendarWebhook(
    request: WebhookRequest,
    context: any
  ): Promise<void> {
    console.log("Received calendar webhook notification", {
      headers: request.headers,
      params: request.params,
      calendarId: context.calendarId,
    });

    // Validate webhook authenticity
    const channelId = request.headers["X-Goog-Channel-ID"];
    const channelToken = request.headers["X-Goog-Channel-Token"];

    if (!channelId || !channelToken) {
      throw new Error("Invalid webhook headers");
    }

    const watchData = await this.store.get<any>(
      `calendar_watch_${context.calendarId}`
    );

    if (!watchData || watchData.watchId !== channelId) {
      console.warn("Unknown or expired webhook notification");
      return;
    }

    const params = new URLSearchParams(channelToken);
    const secret = params.get("secret");

    if (!watchData || watchData.secret !== secret) {
      console.warn("Invalid webhook secret");
      return;
    }

    // Trigger incremental sync
    await this.startIncrementalSync(context.calendarId, context.authToken);
  }

  private async startIncrementalSync(
    calendarId: string,
    authToken: string
  ): Promise<void> {
    const watchData = await this.store.get<any>(`calendar_watch_${calendarId}`);
    if (!watchData) {
      console.error("No calendar watch data found");
      return;
    }

    const incrementalState: SyncState = {
      calendarId: watchData.calendarId,
      state:
        (await this.store.get<string>(`last_sync_token_${calendarId}`)) ||
        undefined,
    };

    await this.store.set(`sync_state_${calendarId}`, incrementalState);
    await this.run.now("syncBatch", {
      calendarId,
      batchNumber: 1,
      mode: "incremental",
      authToken,
    });
  }

  async onAuthSuccess(
    authResult: Authorization,
    context: AuthSuccessContext
  ): Promise<void> {
    // Store the actual auth token using opaque token as key
    await this.store.set(`authorization:${context.authToken}`, authResult);

    const authSuccessResult: CalendarAuth = {
      authToken: context.authToken,
    };
    await this.callback.call(context.callbackToken, authSuccessResult);

    // Clean up the callback token
    await this.store.clear(`auth_callback_token:${context.authToken}`);
  }
}
