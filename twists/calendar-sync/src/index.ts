import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import {
  type NewActivityWithNotes,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

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

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and calendar selection are now handled in the twist edit modal.
  }

  async handleEvent(
    activity: NewActivityWithNotes,
    _provider: string,
    _calendarId: string
  ): Promise<void> {
    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createActivity(activity);
  }
}
