# Outlook Calendar Connector for Plot

> **Library note:** This package is consumed by [`@plotday/connector-outlook`](../outlook), the deployed "Outlook" connection — it is not deployed as a standalone connector. See `../AGENTS.md` for details.

Sync Microsoft Outlook (Microsoft 365) calendar events into Plot.

## What it does

- Lists your Outlook calendars as channels
- Syncs events — including recurring series and exceptions — onto your Plot agenda
- Syncs attendees with their RSVP status, and event descriptions as notes
- RSVPing in Plot accepts, tentatively accepts, or declines the event in Outlook
- Real-time updates via Microsoft Graph change notifications, renewed automatically

## OAuth scopes

- `https://graph.microsoft.com/calendars.readwrite` — read events and write your RSVPs

## License

MIT © Plot Technologies Inc.
