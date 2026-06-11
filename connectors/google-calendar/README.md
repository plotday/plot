# Google Calendar Connector for Plot

Sync Google Calendar events into Plot.

## What it does

- Lists your calendars as channels (calendars you own are enabled by default)
- Syncs events — including recurring events and exceptions — onto your Plot agenda
- Syncs attendees with their RSVP status, and event descriptions as notes
- RSVPing in Plot writes your response back to Google Calendar
- Real-time updates via Google Calendar push notifications (watch channels), renewed automatically

## OAuth scopes

- `calendar.events` (required) — read events and write your RSVPs
- `calendar.calendarlist.readonly` (optional) — list all calendars so you can choose which to sync; without it, only your primary calendar is synced
- Google Contacts scopes (optional) — add names to events using your contacts

## License

MIT © Plot Technologies Inc.
