# Plot Notifications

How Plot decides what to notify you about, when, and how to present it.

## Urgency Levels

Every thread has an urgency level that determines if and when a notification is sent:

| Urgency           | Meaning                         | Default delivery delay |
| ----------------- | ------------------------------- | ---------------------- |
| `interrupt`       | Requires immediate attention    | Immediate              |
| `inform-requests` | Someone is waiting on you       | 30 minutes             |
| `inform-updates`  | General updates worth reviewing | 1 hour                 |
| `passive`         | Shown unread in-app only        | Never                  |

Urgency is set by the twist or source that created the thread.

## Delivery Pipeline

1. **Server schedules** a `sync_wake` push after the urgency delay. If a higher-urgency thread
   arrives before the alarm fires, it is rescheduled sooner.
2. **Device receives** the silent push and evaluates whether to notify now or later.
3. **Device calls `GET /notification-content`** to get up-to-date notification content (the server
   has the freshest read/unread state and handles AI summarization).
4. **Device shows** a local notification (or schedules one for later).
5. **User taps** the notification; the app syncs and displays the relevant priority.

## When the Server Skips Sending

The server does not send a push if:

- The user has an **active WebSocket connection** (app is in foreground) — data is delivered via
  real-time sync instead
- A push was already sent within the last **5 minutes** (rate limit; bypassed for `interrupt`
  urgency)

## Custom Delivery Timing

Users can configure a `see_within` setting per priority, overriding the default urgency delays. The
server uses the shortest delay across all matching unread threads. `interrupt` always delivers
immediately regardless of `see_within`.

## Device-Side Scheduling

When a `sync_wake` push arrives, the device determines the actual notification time:

| Condition                 | Behavior                                       |
| ------------------------- | ---------------------------------------------- |
| No quiet hours in effect  | Notify immediately                             |
| In quiet hours            | Schedule notification for when quiet hours end |
| DnD active (Android)      | Wait until DnD ends _(future)_                 |
| Focus/meeting in progress | Wait until focus ends _(future)_               |

The device fetches notification content from the API at receive time. If delivery is delayed (e.g.
quiet hours), the content is computed at receive time and scheduled.

### Default quiet hours

9 PM – 7 AM every day (configurable per user).

## Multi-Device Suppression

If another device was active within the last 5 minutes, the device suppresses its notification and
waits. Once the suppression window expires, it re-evaluates.

This prevents duplicate notifications when switching between devices.

## Batching by Priority

Notifications are grouped by **first-level priority** (direct children of the root). All unread
threads under a first-level priority tree appear as a single notification.

Each batch's notification taps to the **lowest common ancestor (LCA)** priority that contains all
unread threads. For example, if threads are in "Work › Projects › Alpha" and "Work › Projects ›
Beta", the notification navigates to "Work › Projects".

## Notification Content

**Title**: The first-level priority name.

**Body**: AI-generated summary (Cloudflare `llama-3.1-8b-instruct`) of the top 1–2 updates. Falls
back to plain text when AI is unavailable or usage limit exceeded:

- 1 thread: the thread title
- Multiple threads: "[top title] and N more updates"

Content is always fetched from the server at notification time, ensuring it reflects the latest
read/unread state.

## Notification Retraction (foreground only)

When threads are read on another device and the app is in the foreground, the local notification for
that priority is cancelled. Retraction is based on an in-memory map of shown notifications keyed by
`targetPriorityId`. Background notifications are not retracted until the app next enters the
foreground.

## Android Channels

| Urgency           | Channel  | Importance | Alert             |
| ----------------- | -------- | ---------- | ----------------- |
| `interrupt`       | Urgent   | High       | Sound + vibration |
| `inform-requests` | Requests | Default    | Sound + vibration |
| `inform-updates`  | Updates  | Low        | Silent            |

## iOS

Standard alerts with badge and sound. All urgency levels currently use the same presentation
options. `UIBackgroundModes` includes `remote-notification` to allow the OS to wake the app for
silent `sync_wake` pushes.

## Opening from a Notification

Tapping a notification navigates to the `target_priority_id`. Because the local database may not yet
contain the threads referenced in the notification, the app triggers an immediate sync and shows a
loading state before displaying the content.
