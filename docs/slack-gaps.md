# Slack Client Gaps

Plot today is a read-mostly mirror of Slack: it pulls messages/threads via the Events API +
`conversations.history`, lets you reply with plain text, and maps a curated set of reactions to Plot
tags. It is not a full client.

This is a stack-ranked backlog of remaining gaps to close. Gaps already being addressed by other
work (DM token fragility, write-path for reactions, file attachment rendering) are intentionally
omitted.

Ranked roughly by user-visible pain ÷ implementation cost.

## Tier 1 — Breaks the "this is my Slack" illusion

### 1. Message edits & deletions never sync

`public/connectors/slack/src/slack.ts` ignores `message_changed` and `message_deleted` subtypes, so
users see Slack content that no longer matches reality.

**Sketch:** Subscribe to those subtypes in `SLACK_EVENT_SCOPES`, dispatch them in `onSlackWebhook`,
and update/archive the corresponding note by `key = ts`. Notes already use `ts` as their key, so the
wiring is small; the harder bit is reconciling sync-baseline hashes so we don't fight outbound
edits.

### 2. Rich messages (Block Kit, attachments) render as plaintext

Bot messages, polls, and app posts from GitHub/PagerDuty/Linear/etc. look like gibberish or arrive
empty. `formatSlackText` in `slack-api.ts` only handles inline mrkdwn.

**Sketch:** Add a Block Kit → Plot rich-content converter covering sections, fields, context, image,
divider, and button labels. Interactive elements can render as static labels for now; full
interactivity is in Tier 3.

## Tier 2 — Major missing client features

### 3. No search

No calls to `search.messages` or `search.files`. Big gap for a "Slack client" framing.

**Sketch:** Slack search requires `search:read`, which is not in `Slack.SCOPES`. Add the scope,
expose a `Plot.search` plumbing hook or a connector-level search RPC, and render results as
transient thread previews.

### 4. No mark-as-read / unread sync back to Slack

Plot tracks unread locally; the Slack workspace keeps showing badges, so users have to "reset" Slack
manually.

**Sketch:** On note-read in Plot, call `conversations.mark` with the channel and `ts`. Throttle to
one call per channel per N seconds. Real design call: mark on view vs. mark on archive.

### 5. Presence, custom status, and DnD missing

The directory has no live signal — the user picker can't show "in a meeting" or "away".

**Sketch:** `users.getPresence` is per-user and rate-limited; cleaner is subscribing to
`presence_change` + `user_change` events (already declared in `SLACK_EVENT_SCOPES` but unhandled)
and caching on the contact row. DnD via `dnd.info`. Medium-sized, mostly plumbing.

### 6. Webhook coverage incomplete

`reaction_added/removed`, `channel_created/rename/archive`, `user_change`, `team_join`,
`app_mention`, and `file_*` are declared in `SLACK_EVENT_SCOPES` but never dispatched in
`onSlackWebhook`.

**Sketch:** Each is a small `handleX` in `slack.ts` paralleling `handleStarEvent`.
`reaction_added/removed` is the highest-value one (real-time tag updates on threads); `channel_*`
and `user_change` are housekeeping.

### 7. Bulk backfill capped at 15 min + stars

Historical context is essentially absent. New connections show almost nothing until traffic happens.

**Sketch:** Constrained by Slack's 1-rpm non-Marketplace rate limit, so this is partly a _business_
fix (apply to the Slack Marketplace) and partly a _scheduling_ fix (drip-backfill via `runTask` with
persisted cursors per channel). The scheduling work is mechanical but real.

### 8. No file uploads from Plot → Slack

Compose is text-only.

**Sketch:** Use the v2 upload flow (`files.getUploadURLExternal` + `files.completeUploadExternal`).
Need a Plot-side attachment picker hook into compose, plus the `files:write` scope.

## Tier 3 — Power-user / platform features

### 9. Block Kit interactivity (buttons, selects, modals, app home)

Once #2 renders blocks, the next step is making them clickable.

**Sketch:** Significant work. Need a `block_actions` / `view_submission` interactivity endpoint,
signed-request handling, and modal lifecycle. Realistically a multi-week project; defer unless a
specific high-value bot (e.g. PagerDuty ack, Linear assign) justifies it.

### 10. Slash commands & shortcuts

Zero support.

**Sketch:** `/hook/slack` dispatcher would add a slash-command route (separate signed POST shape).
Useful mostly if Plot itself becomes a Slack app users invoke from inside Slack — a different
direction than "Plot as a Slack client."

### 11. Channel management (join/leave, create, archive, browse public)

Plot can only see channels the user is already in.

**Sketch:** `conversations.join/leave/create/archive` plus a public channel browser UI. Mostly UI
work; API is straightforward. Requires the `channels:write` scope.

### 12. Pinned/starred messages beyond "later"

Pins are not synced; stars are only used for the saved-for-later inbox via `backfillStars`.

**Sketch:** Subscribe to `pin_added`/`pin_removed`; surface as a Plot tag or thread-level flag.

### 13. Huddles / calls / clips / canvases

None.

**Sketch:** Slack's call APIs are limited even for third parties — likely out of scope for a
"client" framing. Canvases (`canvases.*`) would be the most realistic add and align with Plot's
notes model.

### 14. Custom emoji rendering

Standard emoji names only.

**Sketch:** `emoji.list` per workspace (cache long), then substitute `:name:` tokens with hosted
image URLs in rendered notes.

### 15. Multi-workspace UX gaps

Per-user multi-workspace works at the auth layer, but there's no workspace switcher, no
per-workspace prefs, and no Enterprise Grid handling.

**Sketch:** UI work in Plot's connection picker plus Grid token differences. Only matters once
Enterprise customers ask.

### 16. Admin / enterprise (SCIM, audit logs, DLP, EKM)

None.

**Sketch:** Not a client-feature gap; only relevant if Plot pursues enterprise sales as an
authorized Slack vendor.
