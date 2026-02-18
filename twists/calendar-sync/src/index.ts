import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import {
  type ActivityFilter,
  type NewActivityWithNotes,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

export default class CalendarSyncTwist extends Twist<CalendarSyncTwist> {
  build(build: ToolBuilder) {
    return {
      googleCalendar: build(GoogleCalendar, {
        onItem: this.handleEvent,
        onSyncableDisabled: this.handleSyncableDisabled,
      }),
      outlookCalendar: build(OutlookCalendar, {
        onItem: this.handleEvent,
        onSyncableDisabled: this.handleSyncableDisabled,
      }),
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

  async handleSyncableDisabled(filter: ActivityFilter): Promise<void> {
    await this.tools.plot.updateActivity({ match: filter, archived: true });
  }

  async handleEvent(activity: NewActivityWithNotes): Promise<void> {
    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createActivity(activity);
  }
}
