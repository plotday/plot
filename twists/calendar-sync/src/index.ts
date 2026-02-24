import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import {
  type ThreadFilter,
  type NewThreadWithNotes,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";

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
        thread: {
          access: ThreadAccess.Create,
        },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and calendar selection are now handled in the twist edit modal.
  }

  async handleSyncableDisabled(filter: ThreadFilter): Promise<void> {
    await this.tools.plot.updateThread({ match: filter, archived: true });
  }

  async handleEvent(thread: NewThreadWithNotes): Promise<void> {
    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createThread(thread);
  }
}
