import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  Agent,
  type Priority,
  Tools,
} from "@plotday/sdk";
import type {
  Calendar,
  CalendarAuth,
  CalendarTool,
  SyncOptions,
} from "@plotday/sdk/common/calendar";
import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import { Plot } from "@plotday/sdk/tools/plot";

type CalendarProvider = "google" | "outlook";

type StoredCalendarAuth = {
  provider: CalendarProvider;
  authToken: string;
};

type CalendarSelectionContext = {
  provider: CalendarProvider;
  calendarId: string;
  calendarName: string;
  authToken: string;
};

export default class extends Agent {
  private googleCalendar: GoogleCalendar;
  private outlookCalendar: OutlookCalendar;
  private plot: Plot;

  constructor(protected tools: Tools) {
    super(tools);
    this.googleCalendar = tools.get(GoogleCalendar);
    this.outlookCalendar = tools.get(OutlookCalendar);
    this.plot = tools.get(Plot);
  }

  private getProviderTool(provider: CalendarProvider): CalendarTool {
    switch (provider) {
      case "google":
        return this.googleCalendar;
      case "outlook":
        return this.outlookCalendar;
      default:
        throw new Error(`Unknown calendar provider: ${provider}`);
    }
  }

  private async getStoredAuths(): Promise<StoredCalendarAuth[]> {
    const stored = await this.get<StoredCalendarAuth[]>("calendar_auths");
    return stored || [];
  }

  private async addStoredAuth(
    provider: CalendarProvider,
    authToken: string,
  ): Promise<void> {
    const auths = await this.getStoredAuths();
    const existingIndex = auths.findIndex((auth) => auth.provider === provider);

    if (existingIndex >= 0) {
      auths[existingIndex].authToken = authToken;
    } else {
      auths.push({ provider, authToken });
    }

    await this.set("calendar_auths", auths);
  }

  private async getAuthToken(
    provider: CalendarProvider,
  ): Promise<string | null> {
    const auths = await this.getStoredAuths();
    const auth = auths.find((auth) => auth.provider === provider);
    return auth?.authToken || null;
  }

  private async getParentActivity(): Promise<Pick<Activity, "id"> | undefined> {
    const id = await this.get<string>("connect_calendar_activity_id");
    return id ? { id } : undefined;
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Create callbacks for auth completion
    const googleCallback = await this.callback("onAuthComplete", {
      provider: "google",
    });
    const outlookCallback = await this.callback("onAuthComplete", {
      provider: "outlook",
    });

    // Get auth links from both calendar tools
    const googleAuthLink =
      await this.googleCalendar.requestAuth(googleCallback);
    const outlookAuthLink =
      await this.outlookCalendar.requestAuth(outlookCallback);

    // Create activity with both auth links
    const connectActivity = await this.plot.createActivity({
      type: ActivityType.Task,
      title: "Connect your calendar",
      start: new Date(),
      end: null,
      links: [googleAuthLink, outlookAuthLink],
    });

    // Store the original activity ID for use as parent
    await this.set("connect_calendar_activity_id", connectActivity.id);
  }

  async getCalendars(provider: CalendarProvider): Promise<Calendar[]> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Calendar not authenticated`);
    }

    const tool = this.getProviderTool(provider);
    return await tool.getCalendars(authToken);
  }

  async startSync(
    provider: CalendarProvider,
    calendarId: string,
    options?: SyncOptions,
  ): Promise<void> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Calendar not authenticated`);
    }

    const tool = this.getProviderTool(provider);

    // Create callback for event handling
    const eventCallback = await this.callback("handleEvent", {
      options,
      context: { provider, calendarId },
    });

    await tool.startSync(authToken, calendarId, eventCallback);
  }

  async stopSync(
    provider: CalendarProvider,
    calendarId: string,
  ): Promise<void> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Calendar not authenticated`);
    }

    const tool = this.getProviderTool(provider);
    await tool.stopSync(authToken, calendarId);
  }

  async getAllCalendars(): Promise<
    { provider: CalendarProvider; calendars: Calendar[] }[]
  > {
    const results = [];
    const auths = await this.getStoredAuths();

    for (const auth of auths) {
      try {
        const calendars = await this.getCalendars(auth.provider);
        results.push({ provider: auth.provider, calendars });
      } catch (error) {
        console.warn(`Failed to get ${auth.provider} calendars:`, error);
      }
    }

    return results;
  }

  async handleEvent(activity: Activity, _context?: any): Promise<void> {
    await this.plot.createActivity(activity);
  }

  async onAuthComplete(authResult: CalendarAuth, context?: any): Promise<void> {
    const provider = context?.provider as CalendarProvider;
    if (!provider) {
      console.error("No provider specified in auth context");
      return;
    }

    // Store the auth token for later use
    await this.addStoredAuth(provider, authResult.authToken);
    console.log(`${provider} Calendar authentication completed`);

    try {
      // Fetch available calendars for this provider
      const tool = this.getProviderTool(provider);
      const calendars = await tool.getCalendars(authResult.authToken);

      if (calendars.length === 0) {
        await this.plot.createActivity({
          type: ActivityType.Note,
          note: `I couldn't find any calendars for that account.`,
          parent: await this.getParentActivity(),
        });
        return;
      }

      // Create calendar selection activity
      await this.createCalendarSelectionActivity(
        provider,
        calendars,
        authResult.authToken,
      );
    } catch (error) {
      console.error(`Failed to fetch calendars for ${provider}:`, error);
    }
  }

  private async createCalendarSelectionActivity(
    provider: CalendarProvider,
    calendars: Calendar[],
    authToken: string,
  ): Promise<void> {
    const links: ActivityLink[] = [];

    // Create callback links for each calendar
    for (const calendar of calendars) {
      const token = await this.callback("onCalendarSelected", {
        provider,
        calendarId: calendar.id,
        calendarName: calendar.name,
        authToken,
      } as CalendarSelectionContext);

      if (calendar.primary) {
        links.unshift({
          title: `📅 ${calendar.name} (Primary)`,
          type: ActivityLinkType.callback,
          token: token,
        });
      } else {
        links.push({
          title: `📅 ${calendar.name}`,
          type: ActivityLinkType.callback,
          token: token,
        });
      }
    }

    // Create the calendar selection activity
    await this.plot.createActivity({
      type: ActivityType.Task,
      title: `Which calendars would you like to connect?`,
      start: new Date(),
      links,
      parent: await this.getParentActivity(),
    });
  }

  async onCalendarSelected(
    _link: ActivityLink,
    context: CalendarSelectionContext,
  ): Promise<void> {
    console.log("Calendar selectedwith context:", context);
    if (!context) {
      console.error("No context found in calendar selection callback");
      return;
    }

    try {
      // Start sync for the selected calendar
      const tool = this.getProviderTool(context.provider);

      // Create callback for event handling
      const eventCallback = await this.callback("handleEvent", {
        provider: context.provider,
        calendarId: context.calendarId,
      });

      await tool.startSync(
        context.authToken,
        context.calendarId,
        eventCallback,
      );

      console.log(
        `Started syncing ${context.provider} calendar: ${context.calendarName}`,
      );

      await this.plot.createActivity({
        type: ActivityType.Note,
        note: `Reading your ${context.calendarName} calendar`,
        parent: await this.getParentActivity(),
      });
    } catch (error) {
      console.error(
        `Failed to start sync for calendar ${context.calendarName}:`,
        error,
      );
    }
  }
}
