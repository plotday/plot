import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  type ActivityUpdate,
  type ActorId,
  type NewActivityWithNotes,
  type Priority,
  type Tag,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type {
  Calendar,
  CalendarAuth,
  CalendarTool,
  SyncOptions,
} from "@plotday/twister/common/calendar";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";
import { quickHash } from "@plotday/twister/utils/hash";

type CalendarProvider = "google" | "outlook";

type StoredCalendarAuth = {
  provider: CalendarProvider;
  authToken: string;
};

export default class CalendarSyncTwist extends Twist<CalendarSyncTwist> {
  build(build: ToolBuilder) {
    return {
      googleCalendar: build(GoogleCalendar),
      outlookCalendar: build(OutlookCalendar),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
      }),
    };
  }

  private getProviderTool(provider: CalendarProvider): CalendarTool {
    switch (provider) {
      case "google":
        return this.tools.googleCalendar;
      case "outlook":
        return this.tools.outlookCalendar;
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
    authToken: string
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
    provider: CalendarProvider
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
    // Get auth links from both calendar tools
    const googleAuthLink = await this.tools.googleCalendar.requestAuth(
      this.onAuthComplete,
      "google"
    );
    const outlookAuthLink = await this.tools.outlookCalendar.requestAuth(
      this.onAuthComplete,
      "outlook"
    );

    // Create onboarding activity
    const connectActivity = await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect your calendar",
      start: new Date(),
      end: null,
      notes: [
        {
          note: "Connect a calendar account to get started. You can connect as many as you like.",
          links: [googleAuthLink, outlookAuthLink],
        },
      ],
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
    _options?: SyncOptions
  ): Promise<void> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Calendar not authenticated`);
    }

    const tool = this.getProviderTool(provider);

    // Start sync with event handling callback
    await tool.startSync(
      authToken,
      calendarId,
      this.handleEvent,
      provider,
      calendarId
    );
  }

  async stopSync(
    provider: CalendarProvider,
    calendarId: string
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

  async handleEvent(
    activity: NewActivityWithNotes,
    _provider: CalendarProvider,
    _calendarId: string
  ): Promise<void> {
    // Check if activity already exists based on meta.source
    if (activity.meta?.source) {
      const existing = await this.tools.plot.getActivityBySource(
        activity.meta.source
      );
      if (existing) {
        // Activity already exists - update it if needed
        await this.updateExistingEvent(existing, activity);
        return;
      }
      activity.meta = {
        ...activity.meta,
        // Add a hash so we can add a new note if it changes
        descriptionHash: quickHash(activity.notes[0]?.note ?? ""),
      };
    }

    await this.tools.plot.createActivity(activity);
  }

  private async updateExistingEvent(
    existing: Activity,
    incoming: NewActivityWithNotes
  ): Promise<void> {
    const updates: ActivityUpdate = { id: existing.id };
    let updatedDescription: string | undefined;
    let hasChanges = false;

    // Check for type changes (e.g., event was cancelled and became a Note)
    if (incoming.type !== undefined && incoming.type !== existing.type) {
      updates.type = incoming.type;
      hasChanges = true;
    }

    // Check for title changes
    if (incoming.title !== undefined && incoming.title !== existing.title) {
      updates.title = incoming.title;
      hasChanges = true;
    }

    // Check for time changes (rescheduling or cancellation setting times to null)
    if (incoming.start !== undefined) {
      const incomingStart =
        incoming.start === null
          ? null
          : typeof incoming.start === "string"
          ? incoming.start
          : incoming.start?.toISOString();
      const existingStart =
        existing.start === null
          ? null
          : typeof existing.start === "string"
          ? existing.start
          : existing.start?.toISOString();

      if (incomingStart !== existingStart) {
        updates.start = incoming.start;
        hasChanges = true;
      }
    }

    if (incoming.end !== undefined) {
      const incomingEnd =
        incoming.end === null
          ? null
          : typeof incoming.end === "string"
          ? incoming.end
          : incoming.end?.toISOString();
      const existingEnd =
        existing.end === null
          ? null
          : typeof existing.end === "string"
          ? existing.end
          : existing.end?.toISOString();

      if (incomingEnd !== existingEnd) {
        updates.end = incoming.end;
        hasChanges = true;
      }
    }

    // Check for recurrence rule changes
    if (
      incoming.recurrenceRule !== undefined &&
      incoming.recurrenceRule !== existing.recurrenceRule
    ) {
      updates.recurrenceRule = incoming.recurrenceRule;
      hasChanges = true;
    }

    // Check for recurrence until changes
    if (
      incoming.recurrenceUntil !== undefined &&
      incoming.recurrenceUntil !== existing.recurrenceUntil
    ) {
      updates.recurrenceUntil = incoming.recurrenceUntil;
      hasChanges = true;
    }

    // Check for recurrence count changes
    if (
      incoming.recurrenceCount !== undefined &&
      incoming.recurrenceCount !== existing.recurrenceCount
    ) {
      updates.recurrenceCount = incoming.recurrenceCount;
      hasChanges = true;
    }

    // Check for tag changes (RSVP status)
    if (incoming.tags) {
      const tagsChanged = this.haveTagsChanged(existing.tags, incoming.tags);
      if (tagsChanged) {
        updates.tags = incoming.tags;
        hasChanges = true;
      }
    }

    // Check for metadata changes
    if (incoming.meta) {
      const metaChanged =
        JSON.stringify(existing.meta) !== JSON.stringify(incoming.meta);
      if (metaChanged) {
        updates.meta = incoming.meta;
        hasChanges = true;
      }
    }

    // Check for description changes
    if (
      existing.meta &&
      existing.meta.descriptionHash !== quickHash(incoming.notes[0]?.note ?? "")
    ) {
      updatedDescription = incoming.notes[0]?.note ?? undefined;
      updates.meta = {
        ...(incoming.meta ?? existing.meta),
        descriptionHash: quickHash(incoming.notes[0]?.note ?? ""),
      };
      hasChanges = true;
    }

    // Apply updates if there are any changes
    if (hasChanges) {
      console.log(
        `Updating activity ${existing.id} with changes:`,
        Object.keys(updates).filter((k) => k !== "id")
      );
      await this.tools.plot.updateActivity(updates);
    } else {
      console.log(`No changes detected for activity ${existing.id}`);
    }

    if (updatedDescription) {
      // Add a new note with the updated description
      await this.tools.plot.createNote({
        activity: { id: existing.id },
        note: `*Calendar description updated*: ${updatedDescription}`,
      });
    }
  }

  private haveTagsChanged(
    existingTags: Partial<Record<Tag, ActorId[]>> | null,
    incomingTags: Partial<Record<Tag, ActorId[]>>
  ): boolean {
    // Convert both to JSON for simple comparison
    // This works for most cases, though a more sophisticated comparison
    // could check individual tag additions/removals
    const existingJson = JSON.stringify(existingTags || {});
    const incomingJson = JSON.stringify(incomingTags);
    return existingJson !== incomingJson;
  }

  async onAuthComplete(
    authResult: CalendarAuth,
    provider: CalendarProvider
  ): Promise<void> {
    if (!provider) {
      console.error("No provider specified in auth context");
      return;
    }

    // Store the auth token for later use
    await this.addStoredAuth(provider, authResult.authToken);

    try {
      // Fetch available calendars for this provider
      const tool = this.getProviderTool(provider);
      const calendars = await tool.getCalendars(authResult.authToken);

      if (calendars.length === 0) {
        const activity = await this.getParentActivity();
        if (activity) {
          await this.tools.plot.createNote({
            activity,
            note: `I couldn't find any calendars for that account.`,
          });
        } else {
          console.warn("No parent activity found for no calendars note");
        }
        return;
      }

      // Create calendar selection activity
      await this.createCalendarSelectionActivity(
        provider,
        calendars,
        authResult.authToken
      );
    } catch (error) {
      console.error(`Failed to fetch calendars for ${provider}:`, error);
    }
  }

  private async createCalendarSelectionActivity(
    provider: CalendarProvider,
    calendars: Calendar[],
    authToken: string
  ): Promise<void> {
    const links: ActivityLink[] = [];

    // Create callback links for each calendar
    for (const calendar of calendars) {
      const token = await this.callback(
        this.onCalendarSelected,
        provider,
        calendar.id,
        calendar.name,
        authToken
      );

      if (calendar.primary) {
        links.unshift({
          title: `📅 ${calendar.name} (Primary)`,
          type: ActivityLinkType.callback,
          callback: token,
        });
      } else {
        links.push({
          title: `📅 ${calendar.name}`,
          type: ActivityLinkType.callback,
          callback: token,
        });
      }
    }

    // Create the calendar selection activity
    const providerName = provider === "google" ? "Google" : "Outlook";
    await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: `Which calendars would you like to connect?`,
      start: new Date(),
      notes: [
        {
          note: `Which ${providerName} calendars you'd like to sync?`,
          links,
        },
      ],
    });
  }

  async onCalendarSelected(
    _link: ActivityLink,
    provider: CalendarProvider,
    calendarId: string,
    calendarName: string,
    authToken: string
  ): Promise<void> {
    console.log("Calendar selected with context:", {
      provider,
      calendarId,
      calendarName,
    });

    try {
      // Start sync for the selected calendar
      const tool = this.getProviderTool(provider);

      // Start sync with event handling callback
      await tool.startSync(
        authToken,
        calendarId,
        this.handleEvent,
        provider,
        calendarId
      );

      console.log(`Started syncing ${provider} calendar: ${calendarName}`);
      const activity = await this.getParentActivity();
      if (!activity) {
        console.warn("No parent activity found for calendar sync note");
        return;
      }
      await this.tools.plot.createNote({
        activity,
        note: `Reading your ${calendarName} calendar.`,
      });
    } catch (error) {
      console.error(
        `Failed to start sync for calendar ${calendarName}:`,
        error
      );
    }
  }
}
