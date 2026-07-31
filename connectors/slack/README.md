# Slack Connector for Plot

Follow Slack channels and DMs, reply in threads, and start new conversations.

## What it does

- OAuth 2.0 authentication with Slack — a user-token connection only, no bot
  user installed in the workspace
- Direct messages and group DMs, each as one ongoing Plot thread
- Channel threads that mention you (directly, via a user group, or through
  `@here`/`@channel`) or that you've starred — never whole channels
- Starred (saved) Slack items sync as Plot to-dos
- Real-time sync via the Slack Events API
- Reactions round-trip in both directions
- Replying in Plot posts back to Slack, including file attachments

## OAuth scopes

Required: `channels:history`, `channels:read`, `groups:history`,
`groups:read`, `users:read`, `users:read.email`, `chat:write`, `files:write`,
`stars:read`, `stars:write`, `reactions:read`, `reactions:write`.

Optional (connect-time toggles): custom emoji in reactions (`emoji:read`),
@-mentions of a Slack user group you belong to (`usergroups:read`), and
direct/group DMs (`im:history`, `im:write`, `im:read`, `mpim:history`,
`mpim:write`, `mpim:read`).

## Read state

Read state is kept in step with Slack in both directions, within the limits of
what Slack's API exposes.

**Slack → Plot.** Slack tracks two separate read cursors: one for a channel's
timeline, and one for each thread. A conversation or channel message you have
already read in Slack is marked read in Plot, and a thread you have opened in
Slack is marked read once its own cursor moves. A channel message is settled by
a once-daily reconciliation pass; a thread settles as soon as it sees another
reply, because the thread's cursor arrives with the messages.

Because the two cursors are independent, catching up on a channel does **not**
mark its threads read — that matches Slack, where a thread you never opened
stays unread in your Threads view. A thread you read in Slack and that then
goes permanently quiet keeps its Plot unread until you open it in Plot.

Marking something unread in Slack is not propagated to Plot.

**Plot → Slack.** Reading a direct message in Plot marks that conversation read
in Slack. Channel threads do not write back: Slack's API offers no per-thread
mark, and the only available call moves the entire channel's cursor, which
would clear unread on every other message in it.

## License

MIT
