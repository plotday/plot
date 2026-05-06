# Google OAuth Scope Request

Preparation for requesting additional Google OAuth scopes. We currently have Calendar and Contacts approved (sensitive-tier). Adding Drive, Gmail, Tasks, and Chat triggers a CASA security assessment due to restricted Gmail and Drive scopes.

We request a single Gmail scope — `gmail.modify` — because it is a superset that covers read, label modification/archive, and send. Requesting `gmail.readonly` and `gmail.send` alongside it would be strictly redundant and would add noise to the consent screen and CASA justification without granting any capability.

## Scope Inventory

### Currently Approved

| Scope | Connector | Classification | Purpose |
|-------|-----------|---------------|---------|
| `calendar.calendarlist.readonly` | Google Calendar | Non-sensitive | Read list of user's calendars |
| `calendar.events` | Google Calendar | Sensitive | Read/write calendar events, RSVP |
| `contacts.readonly` | Google Contacts | Sensitive | Read contacts for @-mentions and assignees |
| `contacts.other.readonly` | Google Contacts | Sensitive | Read "Other Contacts" directory |

### New Scopes to Request

| Scope | Connector | Classification | Purpose |
|-------|-----------|---------------|---------|
| `tasks` | Google Tasks | **Sensitive** | Read/write task lists and tasks |
| `gmail.modify` | Gmail | **Restricted** | Read messages, modify labels/archive, send replies (superset scope — avoids requesting `gmail.readonly` and `gmail.send` separately) |
| `drive` | Google Drive | **Restricted** | Read/write files, folders, comments |
| `chat.spaces.readonly` | Google Chat | **Sensitive** | List and read Chat spaces |
| `chat.messages` | Google Chat | **Sensitive** | Read, create, update, delete messages and reactions |
| `chat.memberships.readonly` | Google Chat | **Sensitive** | Read space membership info |
| `chat.users.readstate` | Google Chat | **Sensitive** | Read and sync read/unread state for spaces |

### Backend Service Scopes (Not User-Facing)

| Scope | Service | Purpose |
|-------|---------|---------|
| `firebase.messaging` | FCM | Push notifications (service account) |
| `pubsub` | Cloud Pub/Sub | Gmail and Chat webhook delivery (service account) |

### Scopes to NOT Request

| Scope | Why Not |
|-------|---------|
| `mail.google.com/` | Legacy full-access scope. `gmail.modify` covers everything needed without also granting permanent delete. |
| `gmail.readonly` | Redundant — `gmail.modify` is a superset that includes read access. |
| `gmail.send` | Redundant — `gmail.modify` is a superset that includes send access. |
| `gmail.compose` | Redundant — `gmail.modify` covers draft/send operations. Only needed for IMAP/SMTP which we don't use. |
| `chat.admin.*` | Admin-level scopes for managing all org spaces. Restricted and not needed — we use per-user auth. |
| `chat.messages.create` | Narrower write-only scope. We need `chat.messages` (full CRUD) for two-way sync. |

## Classification Impact

| Tier | Current | After Expansion |
|------|---------|-----------------|
| **Non-sensitive** | 1 scope | 1 scope (no change) |
| **Sensitive** | 3 scopes | 8 scopes (+tasks, +4 chat scopes) |
| **Restricted** | 0 scopes | 2 scopes (+gmail.modify, +drive) |

Adding **any** restricted scope triggers:
1. **CASA Tier 2 Security Assessment** — third-party lab-based audit ($4,500-$15,000)
2. **Annual re-assessment** requirement
3. **Limited Use Policy** compliance (already in privacy policy)
4. Longer review timeline (6-12 weeks vs 1-4 weeks for sensitive-only)

All 4 Chat scopes are sensitive, not restricted — no extra CASA burden. However, Google Chat API with user authentication is **only available to Google Workspace accounts**.

### Can We Avoid Restricted Scopes?

| Narrower Alternative | Would It Work? | Why/Why Not |
|---------------------|---------------|-------------|
| `drive.file` (sensitive) instead of `drive` | **No** | Only grants access to files user opens via picker. Drive connector needs folder-based sync. |
| `drive.metadata.readonly` (sensitive) | **No** | Metadata only, no file content. Drive connector syncs comments and creates replies. |
| `drive.readonly` (restricted) | **Partially** | Would lose bidirectional comment sync. Still restricted anyway. |
| Skip `gmail.modify` | **No** | Gmail connector's core purpose is reading and organizing email threads. |

**Restricted scopes are unavoidable.** Since CASA is required for any restricted scope, adding multiple doesn't increase cost. Request all together.

## Certification Audit

### Issue 1: Unused broad scopes in code (FIXED)

`GMAIL_SCOPES` in `workers/api/src/twist/tools/network.ts` previously included `mail.google.com/`, `gmail.compose`, `gmail.readonly`, and `gmail.send`. Narrowed to the single scope actually used by the Gmail connector: `gmail.modify`.

### Issue 2: `drive` scope justification

Google will ask why `drive.file` won't suffice. Justification: the Drive connector needs folder enumeration (`drive.file` only covers files opened via picker), change watching across folders, and bidirectional comment sync.

### Issue 3: Privacy policy

Already compliant (`apps/site/app/routes/privacy.tsx`). Explicitly states adherence to Google API Services User Data Policy including Limited Use requirements.

### Issue 4: Data storage and retention

CASA assessors will want documentation of: encryption at rest (GCP Cloud SQL PostgreSQL AES-256, Google-managed keys), TLS for all API communication, Clerk JWT verification, token refresh mechanism, data deletion on connector disconnect, and account deletion flow.

### Issue 5: Token storage security

OAuth tokens stored via Integrations tool with encryption. Document the full token lifecycle for CASA.

### Issue 6: Rate limiting

Auth endpoints: 20 req/min (`AUTH_RATE_LIMITER`). Document all rate limits for CASA.

### Issue 7: Webhook security

Gmail and Chat: Pub/Sub (Google-managed). Calendar/Drive: watch channels with UUID secrets. Document verification methods for each provider.

### Issue 8: Google Chat Workspace-only limitation

Chat API requires Google Workspace accounts. The Chat connector UI must indicate this. Use incremental auth to request Chat scopes only when the user enables the Chat connector.

### Issue 9: Google Chat app registration

Workspace Events API for Chat push notifications requires registering a Chat app in the Cloud Console. Configure with Plot's branding — purely for event subscription, not a chat bot.

## Verification Answers

### What does your app do?

Plot is a productivity app that helps teams organize tasks, messages, and documents from all their apps into a single prioritized workspace. Users connect their Google services (Calendar, Gmail, Drive, Tasks, Chat, Contacts) so they can see and act on everything in one place — without switching between tabs.

### Why does your app need each requested scope?

**`calendar.calendarlist.readonly`** — Read the user's list of calendars so they can choose which calendars to sync to Plot. We display calendar names in a selection UI.

**`calendar.events`** — Read and write calendar events. Plot displays upcoming events inline with tasks and messages. Users can RSVP to events directly from Plot, which requires write access.

**`contacts.readonly`** — Read the user's Google Contacts to enable @-mentioning collaborators and matching email authors to real names/avatars across all synced services.

**`contacts.other.readonly`** — Read "Other Contacts" (people the user has emailed but not explicitly added to Contacts) to improve author matching for email and document collaborators.

**`tasks`** — Read and write Google Tasks. Plot syncs task lists into the user's priorities, allowing them to view, complete, and create Google Tasks alongside tasks from other services (Linear, Jira, Asana, etc.).

**`gmail.modify`** — Read email messages and threads, modify labels and archive status, and send replies. Plot syncs emails from user-selected labels, displays them alongside related tasks and documents, writes label/archive changes back to Gmail when users organize threads in Plot, and lets users reply to threads without switching to Gmail. We request `gmail.modify` rather than `gmail.readonly` + `gmail.send` because `gmail.modify` is the narrowest scope that covers label modification (which neither of the other two provides) and is already a superset of both — requesting all three would be redundant. Note: `gmail.modify` does not grant permanent delete, which Plot does not need.

**`drive`** — Read files, folders, and comments. List shared drives and folder contents. Create and reply to comments. Plot syncs documents from user-selected Drive folders, displays document metadata and comments, and enables users to comment on documents without leaving Plot. Folder enumeration and change watching require broad Drive access — the `drive.file` scope is insufficient as it only covers files explicitly opened through our picker.

**`chat.spaces.readonly`** — List the user's Google Chat spaces so they can select which spaces to sync to Plot. We display space names in a channel selection UI.

**`chat.messages`** — Read, create, update, and delete messages in Chat spaces. Plot syncs messages from user-selected spaces, displaying them alongside related tasks and documents. Users can reply to Chat threads directly from Plot (two-way sync). Full CRUD access is needed — the narrower `chat.messages.create` scope doesn't support reading existing messages.

**`chat.memberships.readonly`** — Read space membership information to match Chat participants to contacts and display member names/avatars in synced threads.

**`chat.users.readstate`** — Read and update the user's read state for Chat spaces. Plot syncs read/unread status bidirectionally — when a user reads a Chat thread in Plot, we mark it as read in Google Chat (and vice versa), preventing duplicate unread indicators across both apps.

### How is the data accessed via these scopes used?

1. **Sync**: When a user enables a Google service in Plot, we perform an initial sync of the selected resources (calendars, labels, folders, task lists). After that, we use webhooks/push notifications for real-time incremental updates.

2. **Display**: Synced data is displayed to the user within their Plot workspace — emails appear as message threads, calendar events as scheduled items, Drive documents as linked references with comment threads, Chat messages as conversation threads, and tasks as actionable items.

3. **Write-back**: When users take actions in Plot (RSVP to an event, reply to an email, comment on a document, reply to a Chat thread, complete a task), we write those changes back to the originating Google service.

4. **Contact matching**: Contact data is used to match email addresses to names and avatars across synced services, improving the user experience when viewing threads from multiple sources.

### Do you store user data? If so, where and how is it secured?

Yes, we store synced data to provide offline access and cross-device sync.

- **Location**: PostgreSQL database hosted on Google Cloud SQL in `northamerica-northeast2` (Toronto, Canada). Automated backups are stored in the same region.
- **Encryption at rest**: AES-256 via Google-managed encryption keys (default GCP encryption). Backups inherit the same encryption posture.
- **Encryption in transit**: API endpoints are HTTPS-only (TLS 1.2/1.3 terminated at Cloudflare). Worker → database connections go through the Cloud SQL Auth Proxy, which provides mutually-authenticated TLS using short-lived ephemeral certificates and IAM-based authorization.
- **Access controls**: Database access is restricted to our API workers (Cloudflare Workers) via the Cloud SQL Auth Proxy. No direct database access is provided to end users. Application authentication is handled via Clerk with JWT verification using local PEM keys.
- **OAuth tokens**: Stored in per-connection Cloudflare Durable Object storage (AES-256 at rest). Highest-sensitivity application secrets (user-supplied AI provider keys, secure twist options) are additionally protected with column-level AES-256-GCM encryption (`workers/api/src/utils/encryption.ts`). Refresh tokens are used to maintain access; tokens are scoped per-user and per-service.
- **Data isolation**: Each user's data is logically isolated. Private threads are only visible to their creator and explicitly mentioned users.

### How do you handle data deletion requests?

- **Disconnecting a service**: When a user disconnects a Google connector, all synced data from that connector is archived (soft-deleted) and OAuth tokens are revoked.
- **Account deletion**: When a user deletes their Plot account, all associated data (synced content, OAuth tokens, contacts) is permanently deleted from our database.
- **Selective deletion**: Users can archive or delete individual synced items within Plot.
- **Automated cleanup**: We have privacy reporting mechanisms that run on a regular interval to handle data hygiene.

### Who has access to user data within your organization?

Access to production data is restricted to core engineering team members who require it for incident response and debugging. Access is authenticated and logged. We do not read Google user data except (a) with explicit user consent, (b) as necessary for security purposes, or (c) to comply with applicable law — as stated in our privacy policy.

### What third parties receive user data?

Google data synced to Plot is not shared with third parties except:
- **Infrastructure providers**: Google Cloud (Cloud SQL database hosting in Toronto), Cloudflare (API hosting, edge computing, Durable Objects, R2 object storage), Clerk (authentication). These providers process data on our behalf under data processing agreements.
- **AI providers** (only when user explicitly invokes AI features): Anthropic (Claude). AI features are opt-in and do not automatically process Google data.

We do not sell user data. We do not use Google data for advertising.

### Do you comply with the Limited Use policy?

Yes. Our privacy policy (https://plot.day/privacy) explicitly states compliance with the Google API Services User Data Policy including Limited Use requirements. Specifically:
- Data is used only to provide and improve Plot's functionality
- Data is not used for advertising
- Data is not read by humans except with consent, for security, or for legal compliance
- Data is not transferred to third parties except for service provision, legal compliance, or asset sale with data protection obligations

## Steps to Exercise Each Scope

These steps are written for the Google OAuth review team. They assume the reviewer has already added the relevant connection to a Plot priority (covered separately) and that an initial sync has completed so synced items are visible in the priority's thread list.

Throughout, "thread" means a single item in Plot — a synced calendar event, email, Drive document, task, or Chat conversation appears as a thread inside the priority where the connection was enabled.

### Google Calendar — `calendar.calendarlist.readonly`, `calendar.events`

**Choose which calendars sync** (`calendar.calendarlist.readonly`)

1. Open the Google Calendar connection in the priority's connections settings.
2. The list of the user's calendars loads — this is the read of the calendar list.
3. Toggle one or more calendars on or off. Enabled calendars sync their events into the priority.

**RSVP to a calendar event** (`calendar.events`, write)

1. In the priority, open a synced calendar event that has other attendees (it appears as a thread with a date/time and attendee list).
2. Two buttons appear at the top of the thread: **Attend** and **Skip**.
3. Tap **Attend** to RSVP yes, or **Skip** to RSVP no. The button state updates immediately and the RSVP is written back to Google Calendar via `events.patch`.
4. Open the same event in Google Calendar (web or mobile) to confirm the RSVP status changed.

**Read calendar events** (`calendar.events`, read) is exercised passively — events from enabled calendars appear in the thread list as they sync.

---

### Google Contacts — `contacts.readonly`, `contacts.other.readonly`

These scopes are exercised passively. Once the Google Contacts connection is added, Plot reads the user's Contacts and Other Contacts to resolve email addresses to names and avatars across every other synced service.

To verify:

1. Open any synced Gmail thread, calendar event, Drive document, or Chat thread that involves people who are in the user's Google Contacts.
2. Confirm that participant names and profile pictures appear next to email addresses in the thread (instead of bare email addresses). The names and avatars are sourced from Google Contacts.
3. Optionally, type `@` while replying in a thread to bring up an autocomplete of contacts — entries from Google Contacts appear in the suggestions.

---

### Google Tasks — `tasks`

**Choose which task lists sync** (`tasks`, read)

1. Open the Google Tasks connection in the priority's connections settings.
2. The list of the user's task lists loads.
3. Enable one or more task lists. Their tasks sync into the priority as threads.

**Complete a Google Task** (`tasks`, write)

1. Open a synced task in the priority.
2. Tap the checkbox at the top of the thread (or use the **Done** action) to mark the task complete.
3. The completion is written back to Google Tasks. Open Google Tasks to confirm the task is now checked off.

**Create a new task that syncs to Google Tasks** (`tasks`, write)

1. In a priority that has a Google Tasks list enabled, create a new thread and choose **Task** as the type, picking the Google Tasks list as the destination.
2. Enter a title and save.
3. The task is created in Google Tasks via `tasks.insert`. Open Google Tasks to confirm.

---

### Gmail — `gmail.modify`

**Choose which labels sync** (`gmail.modify`, read)

1. Open the Gmail connection in the priority's connections settings.
2. The list of the user's Gmail labels loads.
3. Enable one or more labels. Email threads with those labels sync into the priority.

**Reply to an email thread** (`gmail.modify`, send)

1. Open a synced email thread in the priority.
2. Type a reply in the message composer at the bottom of the thread.
3. Send the reply. Plot calls `messages.send` to post the reply to the original Gmail thread.
4. Open the same thread in Gmail (web or mobile) to confirm the reply appears in-thread.

**Archive an email thread** (`gmail.modify`, label modification)

1. Open a synced email thread in the priority.
2. Tap the **Archive** action (also available via the keyboard shortcut shown on the menu).
3. Plot calls `messages.modify` to remove the `INBOX` label from the thread in Gmail.
4. Open Gmail to confirm the thread is no longer in the inbox.

---

### Google Drive — `drive`

**Choose which folders sync** (`drive`, folder enumeration)

1. Open the Google Drive connection in the priority's connections settings.
2. The folder picker loads, listing My Drive, shared drives, and folders. This exercises folder enumeration, which `drive.file` does not provide.
3. Enable one or more folders. Documents in the selected folders sync into the priority as threads.

**Reply to a document comment** (`drive`, comment write)

1. Open a synced Drive document in the priority. Existing comments appear as replies on the thread.
2. Type a reply in the message composer at the bottom of the thread.
3. Send. Plot calls the Drive `comments.replies.create` endpoint to post the reply on the original comment thread.
4. Open the same document in Google Drive and confirm the reply appears under the same comment.

**Add a new comment to a document** (`drive`, comment create)

1. Open a synced Drive document in the priority.
2. Add a new top-level reply (the first reply on a document creates a new comment thread via `comments.create`).
3. Open the document in Google Drive to confirm the new comment appears.

Reading documents and comments (`drive`, read) is exercised passively as documents from enabled folders sync into the priority.

---

### Google Chat — `chat.spaces.readonly`, `chat.messages`, `chat.memberships.readonly`, `chat.users.readstate`

Google Chat with user authentication requires a Google Workspace account. The Plot Chat connector is only offered to Workspace users.

**Choose which spaces sync** (`chat.spaces.readonly`)

1. Open the Google Chat connection in the priority's connections settings.
2. The list of the user's Chat spaces loads — this is the read of the spaces list.
3. Enable one or more spaces. Their message threads sync into the priority.

**See members on a Chat thread** (`chat.memberships.readonly`)

1. Open a synced Chat thread in the priority.
2. The thread shows participant names and avatars. These are resolved from Chat space membership data.

**Reply to a Chat thread** (`chat.messages`, write)

1. Open a synced Chat thread in the priority.
2. Type a reply in the message composer at the bottom of the thread.
3. Send. Plot calls `messages.create` to post the reply into the same Chat thread.
4. Open the same space in Google Chat to confirm the message appears in-thread, posted as the user.

**Edit a Chat message** (`chat.messages`, update)

1. In a synced Chat thread, open one of the user's own previously-sent messages.
2. Edit the message text.
3. Plot calls `messages.patch`. Confirm the edit reflects in Google Chat.

**React to a Chat message** (`chat.messages`, reactions)

1. In a synced Chat thread, add an emoji reaction to a message (Plot maps its reaction tags to Chat emoji).
2. Plot calls `reactions.create`. Confirm the reaction appears in Google Chat.
3. Remove the reaction in Plot. Plot calls `reactions.delete`. Confirm the reaction disappears in Google Chat.

**Sync read state** (`chat.users.readstate`)

1. In Google Chat, leave a Chat thread with unread messages. The thread shows as unread in Plot.
2. Open the thread in Plot. Plot updates the user's read state for that space via the read-state API.
3. Refresh Google Chat — the thread is no longer marked unread.
4. The reverse also works: marking a thread read in Google Chat causes Plot to clear the unread indicator on the next sync.

---

## CASA Assessment Preparation

### What Assessors Will Review

1. **Application security**: Authentication, authorization, session management
2. **Data handling**: Encryption, storage, transmission, retention, deletion
3. **Infrastructure security**: Hosting environment, access controls, logging
4. **Vulnerability management**: Dependency scanning, security patching
5. **Incident response**: Breach notification process

### Strengths to Highlight

- PKCE OAuth flow with offline access and consent prompting
- Platform-specific OAuth clients (separate client IDs for web, iOS, Android)
- Clerk JWT verification using local PEM keys (no network calls for auth)
- Rate limiting on auth endpoints (20 req/min)
- Webhook verification for all providers (Pub/Sub for Gmail and Chat, UUID secrets for Calendar/Drive)
- Privacy policy already compliant with Limited Use requirements
- Local-first architecture — app functions offline, reducing attack surface for data in transit
- Logical data isolation — private threads, mention-based access control

### Preparation Checklist

- [ ] Document the full data flow diagram (Google API → Cloudflare Worker → PostgreSQL → Flutter app)
- [ ] Verify database encryption at rest configuration
- [ ] Document token storage encryption specifics
- [ ] Prepare incident response plan documentation
- [ ] Document dependency update/patching process
- [ ] Review and document all API rate limits

## Submission Strategy

1. **Submit all scopes at once** — restricted scopes trigger CASA regardless, so batching is more efficient.
2. **Proactively include the video walkthrough** — record a screencast showing: OAuth consent → calendar sync → email sync → Drive folder sync → tasks sync → Chat space sync → reply to email → comment on Drive doc → reply in Chat.
3. **Start CASA assessor engagement early** — begin before Google completes their initial review (CASA is the bottleneck).

## Console Configuration Checklist

- [ ] All 11 scopes listed in Google Cloud Console OAuth consent screen:
  1. `calendar.calendarlist.readonly`
  2. `calendar.events`
  3. `contacts.readonly`
  4. `contacts.other.readonly`
  5. `tasks`
  6. `gmail.modify`
  7. `drive`
  8. `chat.spaces.readonly`
  9. `chat.messages`
  10. `chat.memberships.readonly`
  11. `chat.users.readstate`
- [ ] Google Chat app configured in Cloud Console for Workspace Events API
- [ ] Video walkthrough recorded
- [ ] CASA assessor engaged (App Defense Alliance approved)
- [ ] Scope justifications submitted
- [ ] Chat connector UI shows Workspace-only requirement

## Video Walkthrough Script

Target length: ~7 minutes. Record as a screencast with voiceover. The audience is Google's verification team — demonstrate that every requested scope maps to real, visible functionality.

### Intro (30s)

**Narration:** "Plot is a productivity app that helps teams organize tasks, messages, and documents from all their apps into a single prioritized workspace. Users connect their Google services so they can see and act on everything in one place — without switching between tabs. This video demonstrates how each requested OAuth scope is used."

**On screen:** Plot app open, showing a priority with mixed content (tasks, events, messages).

---

### Section 1: OAuth Consent & Google Calendar (~90s)

**Scopes demonstrated:** `calendar.calendarlist.readonly`, `calendar.events`

**Narration:** "When a user connects their Google account, they see the standard OAuth consent screen listing the requested scopes. After granting access, Plot reads the user's calendar list so they can choose which calendars to sync."

**On screen:**
1. Open a priority → click to add a connection → select Google Calendar
2. OAuth consent screen appears → grant access
3. Calendar list loads — show the selection UI with multiple calendars
4. Enable a calendar → events sync into Plot, appearing alongside tasks and messages

**Narration:** "Users can RSVP to events directly from Plot. This requires the `calendar.events` write scope."

**On screen:**
5. Open a calendar event in Plot → click an RSVP button (Accept/Decline)
6. Show the RSVP status update reflected in the event

---

### Section 2: Google Contacts (~30s)

**Scopes demonstrated:** `contacts.readonly`, `contacts.other.readonly`

**Narration:** "Contacts are synced alongside other Google connectors. Plot reads the user's Google Contacts and Other Contacts to match email addresses to real names and avatars across all synced services."

**On screen:**
1. Point to synced threads showing matched names and profile pictures
2. Show an email thread where the sender's name and avatar were resolved from Contacts

---

### Section 3: Gmail (~90s)

**Scope demonstrated:** `gmail.modify`

**Narration:** "The Gmail connector syncs emails from user-selected labels. Users choose which labels to sync — it's not all-or-nothing. We request `gmail.modify` because it is the narrowest scope that covers all three things Plot needs: reading threads, modifying labels, and sending replies."

**On screen:**
1. Add Gmail connection → label selection UI appears
2. Enable a label → email threads sync into Plot (demonstrates read)

**Narration:** "Users can reply to emails directly from Plot."

**On screen:**
3. Open an email thread → type a reply → send it (demonstrates send)
4. (Optional) Show the reply appearing in Gmail

**Narration:** "When users archive a thread in Plot, the change syncs back to Gmail."

**On screen:**
5. Archive a thread in Plot → show it's archived in Gmail (demonstrates label modification)

---

### Section 4: Google Drive (~60s)

**Scope demonstrated:** `drive`

**Narration:** "The Drive connector syncs documents from user-selected folders. We need the broad `drive` scope because `drive.file` only covers files opened through a picker — it doesn't support folder enumeration or change watching, which are essential for continuous sync."

**On screen:**
1. Add Drive connection → folder selection UI appears (shows shared drives and folders)
2. Enable a folder → documents appear with metadata

**Narration:** "Users can view and reply to document comments directly from Plot."

**On screen:**
3. Open a synced document → show its comments
4. Reply to a comment from Plot

---

### Section 5: Google Tasks (~60s)

**Scope demonstrated:** `tasks`

**Narration:** "The Tasks connector syncs Google Tasks alongside tasks from other services like Linear, Jira, and Asana."

**On screen:**
1. Add Tasks connection → task list selection UI appears
2. Enable a task list → tasks sync into Plot

**Narration:** "Users can complete tasks in Plot and the status syncs back to Google Tasks."

**On screen:**
3. Check off a task in Plot
4. (Optional) Show it completed in Google Tasks
5. Create a new task in Plot → show it appears in Google Tasks

---

### Section 6: Google Chat (~90s)

**Scopes demonstrated:** `chat.spaces.readonly`, `chat.messages`, `chat.memberships.readonly`, `chat.users.readstate`

**Note:** Google Chat requires a Google Workspace account. Mention this in the narration.

**Narration:** "The Chat connector is available to Google Workspace users. It syncs messages from user-selected Chat spaces."

**On screen:**
1. Add Chat connection → spaces list loads (demonstrates `chat.spaces.readonly`)
2. Select a space → messages sync in with member names and avatars resolved from membership data (demonstrates `chat.messages` read + `chat.memberships.readonly`)

**Narration:** "Users can reply to Chat threads from Plot, and the message appears in Google Chat."

**On screen:**
3. Reply to a Chat thread from Plot (demonstrates `chat.messages` write)

**Narration:** "Read state syncs bidirectionally. When a user reads a thread in Plot, it's marked as read in Google Chat — and vice versa."

**On screen:**
4. Mark a thread as read in Plot → note that read state syncs to Google Chat (demonstrates `chat.users.readstate`)

---

### Outro (~30s)

**Narration:** "To summarize: all 11 requested scopes map to real functionality that users interact with daily. Data syncs bidirectionally — user actions in Plot are written back to Google services. All data is encrypted at rest, OAuth tokens are scoped per-user, and Plot complies with Google's Limited Use policy as stated in our privacy policy."

**On screen:** Return to the priority view showing the unified workspace with events, emails, documents, tasks, and chat messages.

---

### Key Points to Emphasize Throughout

| Point | Where to Mention |
|-------|-----------------|
| Every scope maps to visible functionality | Intro and Outro |
| Bidirectional sync — not just reading | Calendar RSVP, Gmail reply/archive, Drive comments, Tasks completion, Chat reply |
| User selects what to sync | Calendar list, Gmail labels, Drive folders, Chat spaces, Task lists |
| Incremental auth — Chat scopes only when Chat is enabled | Section 6 intro |
| Chat is Workspace-only | Section 6 intro |
| Privacy and Limited Use compliance | Outro |
| Contacts improve UX across all connectors | Section 2 |
| `drive` scope justified over `drive.file` | Section 4 narration |

## Console Data Access Form Answers

Ready-to-paste answers for the Google Cloud Console → Google Auth Platform → Data Access form. Each justification is under the 1000-character limit.

> **Note:** `directory.readonly` appears in the console but isn't part of the scope inventory above. Either add it to the inventory or remove it from the console. The sensitive-scope justification below assumes it stays, justified by Workspace coworker name/avatar resolution.

### Top sensitive-scopes block (chat readonly scopes, tasks, calendar.events, contacts, directory)

**"How will the scopes be used?"**

```
Plot is a productivity app that unifies tasks, messages, and documents from Google services into a single prioritized workspace.

- calendar.events: Display events inline with tasks/messages and write RSVPs (Accept/Decline) from Plot.
- tasks: Sync Google Tasks alongside tasks from Linear, Jira, Asana; users complete and create tasks in Plot, writes sync back.
- contacts.readonly + contacts.other.readonly: Match email addresses across synced services to real names/avatars, and power @-mention autocomplete.
- directory.readonly: Resolve Workspace coworker names/avatars on Chat, email, and calendar participants that aren't in the user's personal Contacts.
- chat.spaces.readonly: List the user's Chat spaces for the space-selection UI.
- chat.memberships.readonly: Resolve member names/avatars on synced Chat threads.
- chat.users.readstate: Bidirectionally sync read/unread state between Plot and Google Chat to avoid duplicate unread indicators.
```

### Drive scopes — `.../auth/drive`

**"What features will you use?"** — Select features covering: syncing files and folders, accessing file metadata/content, and working with comments (read + create/reply).

**"How will the scopes be used?"**

```
The Drive connector syncs documents from user-selected Drive folders into Plot, where they appear alongside related tasks, calendar events, and messages. We enumerate folder contents (including shared drives), watch for changes to keep Plot in sync, read file metadata and content to display document references, and read/create/reply to comments so users can participate in document discussions without leaving Plot.

We evaluated narrower scopes and they are insufficient:
- drive.file only grants access to files explicitly opened via Google's picker; it does not support folder enumeration or change watching, which are required for continuous sync of a user-selected folder.
- drive.metadata.readonly has no file content and no comment write access, breaking bidirectional comment sync.

The broad drive scope is the minimum that supports folder-based sync with bidirectional comment replies.
```

### Gmail scopes — `.../auth/gmail.modify`

**"What features will you use?"** — Select: reading email, modifying labels / archiving, and sending email.

**"How will the scopes be used?"**

```
The Gmail connector syncs email threads from user-selected labels into Plot, where they appear alongside related tasks, calendar events, and documents. Users choose which labels to sync — it's not all-or-nothing. Plot reads message content to display threads, writes label and archive changes back to Gmail when users organize threads in Plot, and sends replies so users can respond to threads without switching apps.

We request gmail.modify rather than gmail.readonly + gmail.send because gmail.modify is the narrowest single scope that covers label modification (which neither of the others provides) and is already a superset of both; requesting all three would be redundant. gmail.modify does not grant permanent delete, which Plot does not need. We explicitly do not request mail.google.com/ or gmail.compose.
```

### Chat scopes — `.../auth/chat.messages`

**"What features will you use?"** — Select: reading messages, sending/creating messages, updating messages, and managing reactions (full CRUD + reactions).

**"How will the scopes be used?"**

```
The Chat connector syncs messages from user-selected Google Chat spaces into Plot, where they appear as conversation threads alongside related tasks, emails, and documents. Users can reply to Chat threads directly from Plot, and the reply is posted back to Google Chat as the user. Plot also supports editing and deleting messages the user authored, and adding/removing reactions, so the experience in Plot matches native Chat.

We evaluated chat.messages.create and it is insufficient — it is write-only and does not allow reading existing messages, which breaks the core sync use case. chat.admin.* scopes are explicitly not requested; Plot operates per-user, not as a Workspace admin. The Chat connector is only available to Google Workspace users (a limitation of the Chat API with user auth), and is requested incrementally — only when the user enables the Chat connector.
```
