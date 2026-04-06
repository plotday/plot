# Google OAuth Scope Request

Preparation for requesting additional Google OAuth scopes. We currently have Calendar and Contacts approved (sensitive-tier). Adding Drive, Gmail, Tasks, and Chat triggers a CASA security assessment due to restricted Gmail and Drive scopes.

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
| `gmail.readonly` | Gmail | **Restricted** | Read email messages and threads for sync |
| `gmail.modify` | Gmail | **Restricted** | Modify labels, archive messages |
| `gmail.send` | Gmail | **Sensitive** | Send email replies from Plot |
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
| `mail.google.com/` | Legacy full-access scope. `gmail.readonly` + `gmail.modify` + `gmail.send` covers everything needed. |
| `gmail.compose` | Covered by `gmail.send`. Only needed for IMAP/SMTP which we don't use. |
| `chat.admin.*` | Admin-level scopes for managing all org spaces. Restricted and not needed — we use per-user auth. |
| `chat.messages.create` | Narrower write-only scope. We need `chat.messages` (full CRUD) for two-way sync. |

## Classification Impact

| Tier | Current | After Expansion |
|------|---------|-----------------|
| **Non-sensitive** | 1 scope | 1 scope (no change) |
| **Sensitive** | 3 scopes | 9 scopes (+tasks, +gmail.send, +4 chat scopes) |
| **Restricted** | 0 scopes | 3 scopes (+gmail.readonly, +gmail.modify, +drive) |

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
| Skip `gmail.readonly`/`gmail.modify` | **No** | Gmail connector's core purpose is reading and organizing email threads. |

**Restricted scopes are unavoidable.** Since CASA is required for any restricted scope, adding multiple doesn't increase cost. Request all together.

## Certification Audit

### Issue 1: Unused broad scopes in code (FIXED)

`GMAIL_SCOPES` in `workers/api/src/twist/tools/network.ts` previously included `mail.google.com/` and `gmail.compose`. Cleaned up to only include scopes actually used by the Gmail connector.

### Issue 2: `drive` scope justification

Google will ask why `drive.file` won't suffice. Justification: the Drive connector needs folder enumeration (`drive.file` only covers files opened via picker), change watching across folders, and bidirectional comment sync.

### Issue 3: Privacy policy

Already compliant (`apps/site/app/routes/privacy.tsx`). Explicitly states adherence to Google API Services User Data Policy including Limited Use requirements.

### Issue 4: Data storage and retention

CASA assessors will want documentation of: encryption at rest (Supabase/PostgreSQL AES-256), TLS for all API communication, Clerk JWT verification, token refresh mechanism, data deletion on connector disconnect, and account deletion flow.

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

**`gmail.readonly`** — Read email messages and threads. Plot syncs emails from user-selected labels/folders, displaying them alongside related tasks and documents in the appropriate priority context.

**`gmail.modify`** — Modify email labels and archive status. When users organize emails in Plot (e.g., archiving a thread, applying labels), those changes sync back to Gmail so the user's inbox stays consistent.

**`gmail.send`** — Send email replies. Users can reply to email threads directly from Plot without switching to Gmail, maintaining conversation context alongside related tasks and documents.

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

- **Location**: PostgreSQL database hosted on Supabase (AWS, with data residency in Canada and the United States).
- **Encryption at rest**: Database is encrypted at rest using AES-256.
- **Encryption in transit**: All connections use TLS 1.2+. API endpoints are HTTPS-only.
- **Access controls**: Database access is restricted to our API workers (Cloudflare Workers). No direct database access is provided to end users. Authentication is handled via Clerk with JWT verification using local PEM keys.
- **OAuth tokens**: Stored encrypted in the database. Refresh tokens are used to maintain access. Tokens are scoped per-user and per-service.
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
- **Infrastructure providers**: Supabase (database hosting), Cloudflare (API hosting, edge computing). These providers process data on our behalf under data processing agreements.
- **AI providers** (only when user explicitly invokes AI features): Anthropic (Claude). AI features are opt-in and do not automatically process Google data.

We do not sell user data. We do not use Google data for advertising.

### Do you comply with the Limited Use policy?

Yes. Our privacy policy (https://plot.day/privacy) explicitly states compliance with the Google API Services User Data Policy including Limited Use requirements. Specifically:
- Data is used only to provide and improve Plot's functionality
- Data is not used for advertising
- Data is not read by humans except with consent, for security, or for legal compliance
- Data is not transferred to third parties except for service provision, legal compliance, or asset sale with data protection obligations

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

- [ ] All 13 scopes listed in Google Cloud Console OAuth consent screen:
  1. `calendar.calendarlist.readonly`
  2. `calendar.events`
  3. `contacts.readonly`
  4. `contacts.other.readonly`
  5. `tasks`
  6. `gmail.readonly`
  7. `gmail.modify`
  8. `gmail.send`
  9. `drive`
  10. `chat.spaces.readonly`
  11. `chat.messages`
  12. `chat.memberships.readonly`
  13. `chat.users.readstate`
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

**Scopes demonstrated:** `gmail.readonly`, `gmail.modify`, `gmail.send`

**Narration:** "The Gmail connector syncs emails from user-selected labels. Users choose which labels to sync — it's not all-or-nothing."

**On screen:**
1. Add Gmail connection → label selection UI appears
2. Enable a label → email threads sync into Plot

**Narration:** "Users can reply to emails directly from Plot, which requires the `gmail.send` scope."

**On screen:**
3. Open an email thread → type a reply → send it
4. (Optional) Show the reply appearing in Gmail

**Narration:** "When users archive a thread in Plot, the change syncs back to Gmail via the `gmail.modify` scope."

**On screen:**
5. Archive a thread in Plot → show it's archived in Gmail

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

**Narration:** "To summarize: all 13 requested scopes map to real functionality that users interact with daily. Data syncs bidirectionally — user actions in Plot are written back to Google services. All data is encrypted at rest, OAuth tokens are scoped per-user, and Plot complies with Google's Limited Use policy as stated in our privacy policy."

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
