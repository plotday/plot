# Plot Product Features

Internal catalog of product features for marketing content generation. Direct and terse - not user-facing.

## Positioning

Plot is a unified workspace for human collaboration. It pulls together every conversation that needs a thoughtful human reply — email, team chat, and threads from the tools you use (Linear, Docs, etc.) — and organizes them by the projects, relationships, and areas they belong to, sorted by what's important and what's urgent. Newsletters, automated messages, and admin noise are excluded.

Sessions, agenda, priorities, and tasks remain part of the product but are supporting capabilities, not the headline. Marketing copy should lead with collaboration and momentum (carry on, keep moving, nothing slips, end the day on something that mattered) and imply identity (the reader is a high-agency collaborator with important work outside their inbox) without naming it. Avoid administrative words like "filed."

## Core Functionality

### Activities
- Three activity types: Notes, Actions, Events
- Markdown-based rich content editor
- AI-generated titles when not provided
- Activity preview text for quick scanning
- Draft mode for work-in-progress
- Private activities (visible only to creator)
- @-mentions for users, contacts, and twists

### Priorities
- Per-user priority trees — each user owns their own hierarchy, no shared folders
- Hierarchical organization (unlimited nesting depth)
- Path-based structure (e.g., Work/Q1/Marketing)
- Custom colors with inheritance to children
- Per-priority Pomodoro timer settings (default 25 min)
- Pin favorites with top order
- Search scoped to priority trees
- Unread indicators per priority
- Multi-thread notification taps open the priority on the Catch up tab (single-thread taps still jump straight to the thread)

### Thread Sharing
- Threads are shared by adding contacts via the "With" field at creation
- Globally shareable thread URLs (/t/{id}) — no priority context needed
- Each user's copy of a shared thread is filed into their own priority tree automatically
- Connector-created threads are filed via priority matching per user

### Notes & Content
- Full Markdown support with live preview
- Rich formatting (bold, italics, lists, headers)
- Multiple links per activity
- @-mentions with auto-extraction
- Threading (multiple notes per activity)
- Note authorship tracking
- Private notes (author-only visibility)
- Full-text search across titles and content

## Platform Support

- Web application (full-featured)
- Desktop: macOS, Windows (native apps)
- Mobile: iOS, Android (native apps)
- Share target: receive links from other apps via the share sheet (iOS, Android)
- Consistent experience across all platforms
- Platform-specific native UI elements

## Time Management & Scheduling

### Scheduling
- Dual scheduling modes:
  - Date-based (all-day activities)
  - DateTime-based (specific time slots)
- Duration tracking
- Recurring activities (full RRULE support)
  - Weekly, daily, monthly patterns
  - Custom recurrence dates
  - Exception dates for skipped occurrences
- Smart categorization: "Do Now", "Do Later", "Done"
- Calendar integration with time blocking

### Time Intelligence
- Dynamic views based on timing
- Agenda view (chronological)
- Date navigation (next/previous)
- Range filtering
- Completion tracking
- Automatic time accrual from calendar events — events you accepted, or did not decline, contribute their non-overlapping duration to the priority's running total without requiring you to start a session

## Collaboration

### Multi-User
- Shared priorities
- Built-in contact database
- Activity assignment
- Author tracking (activities and notes)
- @-mentions for notifications
- Per-user unread tracking
- Real-time sync across users and devices

### Access Control
- Priority-level sharing
- Private content (activities and notes)
- Priority contacts management
- Invitation system with codes

## Integrations (Twists & Tools)

### Twist System
- Twist Creator SDK (Twister) for custom integrations
- Development environments: Personal, Private, Review, Public
- Twists with a `threadType` appear in the new-thread connection picker, so users can start a chat with the twist alongside picking a connector channel or a plain Plot thread
- The new-thread connection field defaults to the connection last used in that priority (falling back to the most recent across priorities) — a connector channel, a twist chat, or a plain Plot thread — so repeat workflows skip re-picking; share-intent captures stay a plain Plot thread
- Built-in twists:
  - Plot (default workflows; available as "Plot AI chat" in the connection picker)
  - Calendar Sync
  - Message Tasks
  - Project Sync
  - Chat
  - Contacts

### Available Tools for Twist Developers
- Google: Calendar, Gmail, Chat, Contacts
- Microsoft: Outlook Calendar, Teams (channels + DMs, two-way sync)
- Slack integration
- Linear integration
- Notion: Page and comment sync
- PostHog: Event sync grouped by person, with event details as notes
- OAuth ready: Atlassian, Monday.com, GitHub, Asana, HubSpot
- API key connections: Connectors that use API keys instead of OAuth (e.g., PostHog)

### Upcoming Connections
- 65+ upcoming connectors browsable in-app
- Vote for connections you want — feeds into website vote counts
- Get notified when voted connections become available
- Categories: Calendar, Communication, Email, Project Management, Design, Documents, Development, CRM, Customer Support, Cloud Storage, Finance, HR, Marketing, Analytics, Notes, Productivity, Automation, E-commerce, Cloud, Security, Product

### Built-in Tool Capabilities
- AI: Multiple LLM providers (OpenAI, Anthropic, Google, Workers AI, custom OpenAI-compatible endpoints)
  - Flexible provider configuration: add multiple providers and choose which to use for built-in features vs twist AI
  - Custom OpenAI-compatible endpoints: point to any API (local LLMs, proxies, alternative providers) with configurable model names
  - Text generation and analysis
  - Structured output with schemas
  - Tool calling support
  - BYOK (Bring Your Own Key): Users can add their own API keys per provider, scoped to personal or organization priorities
- Network: HTTP requests for external APIs
- Store: Persistent key-value storage
- Task Queue: Background processing
- Callback: Webhook and event handling

### Twist Features
- Auto-approve mode
- Granular permission system
- Callback links (interactive buttons)
- Auth links (OAuth flows)
- Source-based deduplication
- Activity upserts (smart updates vs. creates)

## Data Sync & Offline

### Local-First Architecture
- Full offline functionality
- SQLite local storage (via Drift)
- Automatic sync when connected
- Conflict resolution
- Multi-device sync via PostgreSQL (GCP Cloud SQL)
- Cloud backup

### Sync Intelligence
- Incremental sync (changes only)
- Pull on demand (archived items, date ranges)
- Pagination for large lists
- Real-time updates broadcast

## User Interface

### Navigation & Views
- Bidirectional infinite scrolling
- Calendar view
- Agenda view
- Priority list (hierarchical tree)
- Global search interface
- Command modal (keyboard-driven)
- Resizable panels (draggable)

### Interactive Elements
- Swipeable actions (mobile gestures)
- Drag & drop reordering
- Color dots (visual priority indicators)
- Unread badges
- Smart time display (relative/absolute)
- Hoverable link previews

### Onboarding
- Guided first-run flow with full-screen and highlight steps
- Inline OAuth for Google and Microsoft Calendar — auth runs on the same brand-styled button without a separate modal
- Responsive connector grid for the rest of the available tools — N-up on wide screens, single column on narrow
- Tabs in the priority shell switch automatically as the highlight steps advance, so the panel beneath the spotlight always shows the right view
- Highlights resolve seeded threads by title (e.g. "Everything in its place" in Using Plot) so the per-user thread id doesn't need to be hardcoded
- Plan-limit aware: when a user is at their connection cap, the setup modal swaps "Add connection" for "Upgrade to add more connections"
- Back, dismiss, and replay (debug command) controls always available

### Editor Experience
- Super Editor (markdown with live rendering)
- Auto-detect @-mentions
- Mention popover (quick selection)
- Inline link management
- Speech dictation (voice-to-text)
- Extensive keyboard shortcuts

## Organization

### Activity Management
- Tags system:
  - Toggle tags (single state)
  - Count tags (multiple users)
  - System tags (Now, Later, Done, Archived)
- Filtering (tags, dates, priorities)
- Multiple sort orders (chronological, manual, priority)
- Archiving (non-destructive)
- Full-text search
- Modify individual recurring occurrences

### Activity Tab Sections
The Activity tab on each priority is the consolidated home for thread management, organized into four sections:
- **Today** — Active threads (marked "Do today" via the sentinel, or scheduled for today/past)
- **Scheduled** — One section per future day (Tomorrow, Friday, "Apr 28") for threads scheduled ahead
- **New** — Unread threads that aren't active or scheduled
- **Done** — Inactive threads (read, no active todo)

Drag-and-drop moves threads between sections (drop on Today to make active, on a future day to schedule, on New to mark unread, on Done to finish) and reorders within Today / Scheduled. Drop slots expand to hold the dragged row's height so the surrounding list stays stable.

### Action Type Classification
Each new thread is auto-classified by Plot's AI into one of five action types that drive which inbox tab it lives in:
- **Respond** — needs a reply from the recipient (questions directed at them, asks that require an answer).
- **Do** — needs an action (assigned task, a step that's clearly theirs to take).
- **Read** — longer read-later material: newsletters, long corporate communications, documents to set aside time for.
- **Update** — default. Worth knowing about but no follow-up required. FYIs, mentions without a clear ask, unsolicited pitches and cold outreach all land here.
- **None** — clearly passive records (receipts, account sign-in confirmations, system acknowledgements). Surfaces in the All tab only; no unread indicator, no notification.

The user can drag a thread between tabs to override the AI's classification at any time. Respond / Do / Read also accept "do on this date" intent, surfacing the thread on that day in the agenda.

### Importance Threshold
The AI scores each thread 0–100 for the recipient. Items below 50 (unsolicited material, promotional content, low-relevance updates) appear in Catch up but do not trigger push notifications, email digests, or priority unread indicators. Items ≥ 50 surface proactively. Strong relational signal and direct messages between known contacts score 60+; cold outreach 10–25.

### Urgent Flag
Separate from importance, the AI flags a thread `urgent` only when the user should be notified before their next scheduled response window — time-sensitive items or messages clearly needing a quick response. Urgent threads bypass the per-priority `see_within` delay, the `notify_window` clamping, and the 10-minute inactivity gate that normally defers pushes.

### Priority Features
- Unlimited nesting depth
- Path syntax (Work/Projects/Q1)
- 8+ theme colors with inheritance
- Activity counts (active and unread)
- Breadcrumb navigation
- Per-priority settings

## Productivity

### Focus & Time Management
- Pomodoro timer (customizable duration)
- Do Now view (current and overdue)
- Focus modes (filtered views)
- Manual reordering for prioritization
- Duration tracking for time budgeting

### Daily Planning
- Flag items as Do Now or Do Later to build your daily plan
- Schedule activities with specific dates or times to block your calendar
- Reassign timing on the fly — move items between Now/Later or reschedule with minimal friction
- Do Now view surfaces everything current and overdue in one place
- Agenda view shows your day chronologically across all priorities

### Response Times
Each priority carries two settings the user controls together under "Response times":

- **Schedule time to respond** — master toggle plus a `respond_window` (active hours, e.g. weekdays 9–5) and a `respond_within` SLA (e.g. 4 hours). When enabled, the agenda automatically places a 15-minute response block per priority for unread respond-type threads (importance ≥ 50 or urgent), inside the configured hours and around existing calendar events. Block placement is window-aware, deterministic, and computed entirely on the client.
- **Early notifications** — master toggle plus a `notify_window` (when interruptions are allowed, e.g. 8am–8pm any day) and a `see_within` deadline (max delay before a thread notifies, e.g. 30 minutes). Notifications fire at the earlier of the placed block-start or the see-within deadline. Block-start notifications are always honoured. Early notifications are clamped to the next opening when the window is closed; urgent threads bypass both the batching delay and the window.

Both settings inherit by priority path: a sub-priority that matches its parent's value reverts to inheritance automatically on save.

### Smart Notifications
- AI flags genuinely time-sensitive threads as urgent (direct requests, deadlines) — those fire immediately, even outside the notify window; everything else waits for the user's configured `see_within` or the next placed response block
- Items with importance < 50 (promotional content, unsolicited outreach) never trigger a push, an auto-block, or an email digest on their own
- Batched updates are summarized by AI, grouped by top-level priority, so you get one coherent digest instead of a flood of individual pings
- No manual do-not-disturb rules needed — the system infers what matters based on content and your preferences
- Desktop notifications on macOS and Windows — native OS notifications triggered by real-time sync, with automatic suppression when the app is focused and respect for OS-level Focus/DnD modes

### Smart Features
- AI-powered title generation
- Auto-categorization (Now/Later/Done)
- Unread intelligence across priorities
- Active actions filtering
- Quick priority switching (keyboard shortcuts)

### AI Chat
- Built-in Chat connection for conversational AI within Plot
- Supports top models: Claude (Anthropic), ChatGPT (OpenAI), Gemini (Google)
- Chat in the context of your priorities and threads
- BYOK: use your own API keys for supported providers

### Automation (via Twists)
- Calendar sync (Google/Outlook auto-import)
- AI task detection in emails and chat messages (Gmail, Slack, Google Chat) — automatically creates to-dos when someone asks you to do something
- Project sync (Linear, Asana, etc.)
- Custom workflows with Twister

## Unique/Differentiating Features

### Plot-Specific Innovations
- Activity-first design (everything is an activity)
- User-extensible twist ecosystem
- Dual scheduling (date-based and time-based)
- Source-based upserts (intelligent deduplication)
- Hierarchical priorities with path navigation
- Per-user unread (collaborative read tracking)
- Callback system (interactive twist functions)
- Local-first sync (offline + cloud)

### Developer-Friendly
- Twist Creator SDK (complete TypeScript SDK)
- Fully typed API
- Rich toolset (AI, Network, Store, etc.)
- Open ecosystem with public marketplace
- CLI tools for twist management
- Real-time logs for debugging

## Design & Customization

### Visual
- Theme modes: Light, dark, system-based
- 8 customizable priority colors
- Color inheritance (children inherit parents)
- Platform-native interface elements
- Responsive design (all screen sizes)

### Preferences
- Per-priority settings
- Global app preferences
- Device-specific local settings
- Cross-device theme persistence

## Data & Privacy

### Security
- Row-level security (database-level)
- Private activities and notes
- OAuth standards
- Encrypted data transmission

### Data Management
- PostgreSQL backend (GCP Cloud SQL, enterprise-grade)
- SQLite local storage
- Vector search (AI-powered similarity)
- Full-text search (FTS5-based)
- Data portability via standard APIs

## Subscription Management

- Four plans: Free, Core, Pro, Team
- Free: 2 connections, 1 twist
- Core: 5 connections, 2 twists ($15/mo or $12/mo annual)
- Pro: Unlimited connections and twists, no-code Twist builder ($25/mo or $20/mo annual)
- Team: Shared org connections (50 per group), unlimited twists, no-code Twist builder ($124/mo or $99/mo annual)
- 30-day Core plan trial for new signups with automated reminders and downgrade
- Connection-based pricing (no per-seat fees)
- Monthly and annual billing options (20% annual discount)
- Stripe Checkout integration for secure payments
- Stripe Customer Portal for self-service subscription management
- Team plan scales per 50 connections
- Real-time plan sync — plan changes propagate instantly to all connected devices

## Organizations

- Create organizations for team billing and shared limits
- Organization admin and member roles
- Invite members by email (pending invitations auto-applied on signup)
- Email domain auto-join (anyone with matching domain can join automatically)
- Organization-level Stripe billing (separate from personal subscription)
- Effective plan resolution (highest tier across personal + org memberships)
- Organization management page (members, domains, billing)
- Team-firewalled priorities: threads under a team-tagged top-level priority are visible only to current team members; joining a team auto-creates a priority, and archiving your last team priority prompts to leave the team

## Performance & Scalability

### Optimization
- Efficient pagination
- Indexed database queries
- Incremental sync (minimal data transfer)
- Virtual scrolling
- Lazy loading (archived/historical data)
- Smart caching

### Infrastructure
- Cloudflare Workers (globally distributed API)
- GCP Cloud SQL (scalable PostgreSQL)
- Queue system (background processing)
- Durable Objects (stateful twist runtime)
- Webhook support (event-driven)
