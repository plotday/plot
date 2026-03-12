# Plot Product Features

Internal catalog of product features for marketing content generation. Direct and terse - not user-facing.

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
- Hierarchical organization (unlimited nesting depth)
- Path-based structure (e.g., Work/Q1/Marketing)
- Custom colors with inheritance to children
- Per-priority Pomodoro timer settings (default 25 min)
- Pin favorites with top order
- Search scoped to priority trees
- Unread indicators per priority

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
- Built-in twists:
  - Plot (default workflows)
  - Calendar Sync
  - Message Tasks
  - Project Sync
  - Chat
  - Contacts

### Available Tools for Twist Developers
- Google: Calendar, Gmail, Contacts
- Microsoft: Outlook Calendar
- Slack integration
- Linear integration
- Notion: Page and comment sync
- OAuth ready: Atlassian, Monday.com, GitHub, Asana, HubSpot

### Upcoming Connections
- 65+ upcoming connectors browsable in-app
- Vote for connections you want — feeds into website vote counts
- Get notified when voted connections become available
- Categories: Calendar, Communication, Email, Project Management, Design, Documents, Development, CRM, Customer Support, Cloud Storage, Finance, HR, Marketing, Analytics, Notes, Productivity, Automation, E-commerce, Cloud, Security, Product

### Built-in Tool Capabilities
- AI: Multiple LLM providers (OpenAI, Anthropic, Google, Workers AI)
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
- Multi-device sync via Supabase (PostgreSQL)
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

### Smart Features
- AI-powered title generation
- Auto-categorization (Now/Later/Done)
- Unread intelligence across priorities
- Active actions filtering
- Quick priority switching (keyboard shortcuts)

### Automation (via Twists)
- Calendar sync (Google/Outlook auto-import)
- Email to tasks
- Project sync (Linear, Asana, etc.)
- Message tasks (Slack to activities)
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
- PostgreSQL backend (Supabase enterprise-grade)
- SQLite local storage
- Vector search (AI-powered similarity)
- Full-text search (FTS5-based)
- Data portability via standard APIs

## Subscription Management

- Three plans: Free, Pro, Business
- Connection-based pricing (no per-seat fees)
- Monthly and annual billing options (20% annual discount)
- Stripe Checkout integration for secure payments
- Stripe Customer Portal for self-service subscription management
- Business plan scales per 50 connections

## Organizations

- Create organizations for team billing and shared limits
- Organization admin and member roles
- Invite members by email (pending invitations auto-applied on signup)
- Email domain auto-join (anyone with matching domain can join automatically)
- Organization-level Stripe billing (separate from personal subscription)
- Effective plan resolution (highest tier across personal + org memberships)
- Organization management page (members, domains, billing)

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
- Supabase (scalable PostgreSQL)
- Queue system (background processing)
- Durable Objects (stateful twist runtime)
- Webhook support (event-driven)
