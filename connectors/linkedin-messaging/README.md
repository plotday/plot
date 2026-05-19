# @plotday/connector-linkedin-messaging

LinkedIn direct messages and inbound connection requests, surfaced in your
Plot inbox.

## How it works

LinkedIn does not expose a public OAuth scope for personal messaging. This
connector — like Beeper, Unipile, and Kondo — reuses your authenticated
LinkedIn session: when you "Connect LinkedIn" in Plot, the desktop or
mobile app opens an in-app webview pointed at `linkedin.com/login`. Once
you log in, Plot captures the `li_at` session cookie (and your browser's
User-Agent) and stores them encrypted at rest. All subsequent API calls go
through Plot's privileged server-side LinkedIn tool, which keeps the
Voyager wire format, request signing, and rate limiting hidden from this
open-source connector.

## What's synced

- **1:1 direct messages.** Each conversation becomes a Plot thread; each
  message becomes a note.
- **Group conversations.** Same model — the thread's participants
  populate from the conversation.
- **Inbound connection requests with notes.** Surfaces as a separate
  link type so you can reply or accept directly from Plot.

Replies you send from Plot are written back to LinkedIn; marking a
conversation read in Plot marks it read on LinkedIn.

## Sync cadence

LinkedIn does not offer webhooks for personal messaging, so this connector
polls with an adaptive cadence:

- **5 minutes** when you (or LinkedIn) were active in the last hour.
- **15 minutes** when activity is within the last six hours.
- **30 minutes** when the inbox is idle.

The cadence resets to "fresh" each time you send a reply through Plot.

## Privacy / safety

Your `li_at` cookie grants full access to your LinkedIn account. Plot
treats it like any other access token:

- Encrypted at rest, never logged.
- Never passed into this open-source connector — only Plot's server can
  read it.
- One-tap disconnect in Plot also stops all sync immediately.

LinkedIn may invalidate your session at any time; Plot will prompt you to
reconnect when that happens.

## License

MIT
