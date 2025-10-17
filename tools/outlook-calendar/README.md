# Outlook Calendar Tool

A Plot tool for syncing with Microsoft Outlook Calendar (Microsoft 365).

## Installation

```bash
npm install @plotday/tool-outlook-calendar @plotday/sdk
```

## Usage

```typescript
import { Agent, Tools, createAgent } from "@plotday/sdk";
import { OutlookCalendar } from "@plotday/tool-outlook-calendar";
import { Auth, AuthLevel, AuthProvider } from "@plotday/sdk/tools/auth";

export default createAgent(
  class extends Agent {
    private outlookCalendar: OutlookCalendar;
    private auth: Auth;

    constructor(tools: Tools) {
      super();
      this.outlookCalendar = tools.get(OutlookCalendar);
      this.auth = tools.get(Auth);
    }

    async activate(priority: { id: string }) {
      // Request Outlook Calendar access
      const authLink = await this.auth.request(
        {
          provider: AuthProvider.Microsoft,
          level: AuthLevel.User,
          scopes: ["Calendars.Read"],
        },
        {
          functionName: "onAuthComplete",
          context: { priorityId: priority.id },
        }
      );

      // User will authenticate via authLink
    }

    async onAuthComplete(authorization: any, context: any) {
      const authToken = await this.auth.get(authorization);

      // Get available calendars
      const calendars = await this.outlookCalendar.getCalendars(authToken);

      // Start syncing a calendar
      await this.outlookCalendar.startSync(
        authToken,
        calendars[0].id,
        "onCalendarEvent"
      );
    }

    async onCalendarEvent(event: any) {
      // Handle calendar events
      console.log("New calendar event:", event.subject);
    }
  }
);
```

## API

### `getCalendars(authToken: string)`

Retrieves the list of calendars available to the authenticated user.

### `startSync(authToken: string, calendarId: string, callbackName: string, options?: object)`

Starts syncing events from an Outlook Calendar.

### `stopSync(authToken: string, calendarId: string)`

Stops syncing events from an Outlook Calendar.

## License

MIT © Plot Technologies Inc.
