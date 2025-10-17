# Google Calendar Tool

A Plot tool for syncing with Google Calendar.

## Installation

```bash
npm install @plotday/tool-google-calendar @plotday/sdk
```

## Usage

```typescript
import { Agent, Tools, createAgent } from "@plotday/sdk";
import { GoogleCalendar } from "@plotday/tool-google-calendar";
import { Auth, AuthLevel, AuthProvider } from "@plotday/sdk/tools/auth";

export default createAgent(
  class extends Agent {
    private googleCalendar: GoogleCalendar;
    private auth: Auth;

    constructor(tools: Tools) {
      super();
      this.googleCalendar = tools.get(GoogleCalendar);
      this.auth = tools.get(Auth);
    }

    async activate(priority: { id: string }) {
      // Request Google Calendar access
      const authLink = await this.auth.request(
        {
          provider: AuthProvider.Google,
          level: AuthLevel.User,
          scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
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
      const calendars = await this.googleCalendar.getCalendars(authToken);

      // Start syncing a calendar
      await this.googleCalendar.startSync(
        authToken,
        calendars[0].id,
        "onCalendarEvent"
      );
    }

    async onCalendarEvent(event: any) {
      // Handle calendar events
      console.log("New calendar event:", event.summary);
    }
  }
);
```

## API

### `getCalendars(authToken: string)`

Retrieves the list of calendars available to the authenticated user.

### `startSync(authToken: string, calendarId: string, callbackName: string, options?: object)`

Starts syncing events from a Google Calendar.

### `stopSync(authToken: string, calendarId: string)`

Stops syncing events from a Google Calendar.

## License

MIT © Plot Technologies Inc.
