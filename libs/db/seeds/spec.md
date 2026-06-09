# Plot Seed Data Specification

This document defines the YAML format for generating sample seed data for the Plot application. This format is designed to be both human-readable and LLM-friendly for generating screenshot-quality test data.

## Overview

The seed data format allows you to define:

- **Contacts**: People and their details. Use personal names, not titles.
- **Priorities**: Hierarchical project/folder structure. All users have a single, root priority called Everything.
  Below it are major areas of their life, like Work, Personal, Social. Add 1-3 levels below each of these.
- **Sources**: External services (Slack, Gmail, GitHub, etc.) that provide link logos
- **Twists**: Non-source integrations (e.g., Claude, ChatGPT) whose logos can be used as thread icons
- **Threads**: Discussions, tasks, events — the primary content items
- **Notes**: Updates and messages related to a thread (can contain mentions)
- **Links**: External references attached to threads (emails, messages, issues, etc.)
- **Schedules**: Time-based scheduling for threads (events, due dates, recurrence)
- **Tags**: Either categorize threads (e.g. Urgent, Decision; use sparingly), or reactions (e.g. Yes, No, Volunteer)
- **Settings**: User-specific priority settings, like colors

All dates are specified as offsets from a base date, allowing identical data to be generated at different points in time.

## Top-Level Structure

```yaml
config:
  baseDate: "2025-01-15" # Base date for all date offsets (YYYY-MM-DD)
  email: "user@example.com" # Email address (used as password for local testing)
  userName: "User Name" # Display name for the user

contacts:
  -  # Contact definitions

priorities:
  -  # Priority definitions

sources:
  -  # Source definitions (for link logos)

twists:
  -  # Non-source twist definitions (for AI chat icons, etc.)

threads:
  -  # Thread definitions
```

## Config Section

**Required fields:**

- `baseDate`: ISO date string (YYYY-MM-DD) - all date offsets are calculated from this
- `email`: Email address - the user will be created if it doesn't exist (email is used as password for local testing)
- `userName`: Display name for the user

```yaml
config:
  baseDate: "2025-01-15"
  email: "alice@example.com"
  userName: "Alice Johnson"
```

## Contacts

Contacts represent people (users or non-users) who can be authors, assignees, or tag actors.

**Fields:**

- `ref` (required): Unique reference string for this contact (used in other definitions)
- `email` (required): Email address (will be lowercased)
- `name` (optional): Display name
- `avatar_url` (optional): URL to avatar image
- `user_id` (optional): UUID if this contact is also a Plot user

**Special refs:**

- `user`: Always refers to the user specified in `config.email`

```yaml
contacts:
  - ref: alice
    email: alice@example.com
    name: Alice Johnson
    avatar_url: https://example.com/avatars/alice.jpg

  - ref: bob
    email: bob@company.com
    name: Bob Smith
```

## Priorities

Priorities are hierarchical (like folders/projects) and use a tree structure.

**Fields:**

- `ref` (required): Unique reference string
- `title` (required): Display title
- `icon` (optional): A curated focus-icon key (one of: user, family, briefcase, house, code, receipt, bullhorn, handshake, rocket, building, lightbulb, heart, flask, paintbrush, dumbbell, seedling, balloons, music, plane, mountain, globe, billboard). Written to `priority.icon`. Unknown keys warn but don't fail.
- `root` (optional, default: false): Whether this is a root priority (only one per user)
- `archived_at` (optional): Date offset when archived
- `settings` (optional): User-specific settings (see below)
- `children` (optional): Array of nested child priorities
- `shared_with` (optional): Array of user refs to share this priority with

**Settings fields:**

- `color`: Integer 0-7 (corresponding to theme colors), or omit to inherit from parent priority. Most common to set colors only on children of root priority unless meant to stand out.
- `path_override`: Custom path display override
- `pomodoro_duration`: Duration in minutes

```yaml
priorities:
  - ref: work
    title: Work
    root: true
    settings:
      color: 0
    children:
      - ref: project-alpha
        title: Project Alpha
        settings:
          color: 1
        children:
          - ref: sprint-1
            title: Sprint 1
            # No color - inherits from project-alpha

      - ref: project-beta
        title: Project Beta
        # No color - inherits from work

  - ref: personal
    title: Personal
    root: false
    settings:
      color: 2
```

## Sources

Sources define external services that provide link logos. Each source creates the twist/priority_twist records needed for logo resolution.

**Fields:**

- `ref` (required): Unique reference string (used by links via `source_ref`)
- `name` (required): Display name (e.g., "Slack", "Gmail")
- `priority_ref` (required): Priority to attach the source to
- `logo` (optional): Logo URL for the source itself
- `logo_dark` (optional): Dark mode logo URL for the source
- `link_types` (required): Array of link type definitions
- `channels` (optional): Array of enabled connection channels (e.g. Slack channels). Each surfaces in the new-thread picker's Channels section. A channel-bearing source is created as a live (non-archived) connection.

**Channel fields:**

- `channel_id` (required): Provider channel id (e.g. `C04general`)
- `title` (required): Display title (e.g. `#general`)
- `enabled` (optional, default `true`)
- `link_types` (optional): Override the default compose-capable link type

**Link type fields:**

- `type` (required): Link type identifier (e.g., "message", "email", "issue")
- `label` (required): Display label (e.g., "Message", "Email", "Issue")
- `logo` (required): Logo URL for this link type
- `logo_dark` (optional): Dark mode logo URL
- `includes_schedules` (optional): Marks this link type as producing calendar events. Set on calendar sources (e.g. Google Calendar) so the app's agenda is enabled. The agenda is hidden unless the user has a live calendar connection whose link type declares this. The seed carries the flag on its personal-fallback connection, so the agenda works even when the real connector hasn't been deployed (see the deploy note in README).

```yaml
sources:
  - ref: slack
    name: Slack
    priority_ref: everything
    logo: "https://api.iconify.design/logos/slack-icon.svg"
    logo_dark: "https://api.iconify.design/simple-icons/slack.svg?color=%23E01E5A"
    link_types:
      - type: message
        label: Message
        logo: "https://api.iconify.design/logos/slack-icon.svg"
        logo_dark: "https://api.iconify.design/simple-icons/slack.svg?color=%23E01E5A"

  - ref: gmail
    name: Gmail
    priority_ref: everything
    logo: "https://api.iconify.design/logos/google-gmail.svg"
    link_types:
      - type: email
        label: Email
        logo: "https://api.iconify.design/logos/google-gmail.svg"

  - ref: github
    name: GitHub
    priority_ref: everything
    logo: "https://api.iconify.design/logos/github-icon.svg"
    logo_dark: "https://api.iconify.design/simple-icons/github.svg?color=%23FFFFFF"
    link_types:
      - type: issue
        label: Issue
        logo: "https://api.iconify.design/logos/github-icon.svg"
        logo_dark: "https://api.iconify.design/simple-icons/github.svg?color=%23FFFFFF"
      - type: pull_request
        label: Pull Request
        logo: "https://api.iconify.design/logos/github-icon.svg"
        logo_dark: "https://api.iconify.design/simple-icons/github.svg?color=%23FFFFFF"
```

## Twists

Twists are non-source integrations (e.g., AI chat services like Claude, ChatGPT) that can be referenced by threads via `twist_ref` to display the twist's logo as the thread icon.

**Fields:**

- `ref` (required): Unique reference string (used by threads via `twist_ref`)
- `name` (required): Display name (e.g., "Claude", "ChatGPT")
- `priority_ref` (required): Priority to attach the twist to
- `logo` (optional): Logo URL
- `logo_dark` (optional): Dark mode logo URL

```yaml
twists:
  - ref: claude
    name: Claude
    priority_ref: everything
    logo: "https://api.iconify.design/simple-icons/anthropic.svg"
    logo_dark: "https://api.iconify.design/simple-icons/anthropic.svg?color=%23D4A574"
```

Threads can reference twists to display their logo:

```yaml
threads:
  - title: "Revenue model assumptions"
    priority_ref: business_case
    twist_ref: chatgpt
```

## Groups

Reusable named sets of contacts, surfaced in the new-thread picker's Groups
section. The seed user is automatically an admin of every group (so it appears
for them).

**Fields:**

- `ref` (required): Unique reference string
- `name` (required): Display name
- `privacy` (optional, default `open`): `open` (members see roster & can address) or `private` (only admins)
- `members` (required): Array of contact refs
- `admins` (optional): Extra user refs to make admins (rarely needed)

```yaml
groups:
  - ref: coaching_staff_grp
    name: Coaching staff
    privacy: open
    members: [wes, murph, eli]
```

## Threads

Threads are the primary content items — discussions, tasks, events, or documents. What a thread represents is inferred from its schedule and links, not from a `type` field.

**Fields:**

- `ref` (optional): Unique reference string (only needed if referenced elsewhere)
- `title` (optional): Display title
- `priority_ref` (required): Reference to a priority
- `created` (optional): Date offset when this thread was created
- `author_ref` (optional, default: "user"): Reference to contact or "user" — only used to resolve note author defaults
- `draft` (optional, default: false): Whether this is a draft
- `private` (optional, default: false): Whether this is private
- `archived_at` (optional): Date offset when archived
- `icon` (optional): Thread icon type. Valid values: `"notes"`, `"idea"`, `"goal"`, `"decision"`, `"discussion"`, `"announcement"`, `"ask"`
- `twist_ref` (optional): Reference to a twist (sets the thread icon to the twist's logo)
- `tags` (optional): Object mapping tag names to actor arrays
- `notes` (optional): Array of note objects
- `schedule` (optional): Schedule block for events and tasks
- `links` (optional): Array of external link objects

```yaml
threads:
  - title: Spring menu discussion
    priority_ref: menu
    tags:
      pinned: [user]
    notes:
      - created: "-1d"
        content: "Let's plan the spring menu changes"

  - title: Team meeting
    priority_ref: project-alpha
    schedule:
      at: "+0d 14:00 / +0d 15:00"
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
    notes:
      - created: "+0d 14:30"
        content: "Discussed project timeline"

  - title: Order supplies
    priority_ref: operations
    schedule:
      on: "+1d"
      done_at: "+1d 16:00"
    links:
      - source_ref: gmail
        type: email
        title: "Supply order confirmation"
        source_url: "mailto:supplier@example.com"
```

## Schedule

The schedule block defines when a thread is scheduled (events, tasks, reminders).

**Fields:**

- `at` (optional): Timestamp range for timed events (e.g., "+0d 10:00 / +0d 11:00")
- `on` (optional): Date range for all-day items (e.g., "+3d / +5d")
- `duration` (optional): Duration string (e.g., "30 minutes", "2 hours")
- `recurrence_rule` (optional): iCalendar RRULE string
- `todo` (optional): Whether this is a to-do (user schedule) or event (shared schedule).
  - `true`: Creates a per-user schedule (to-do with ordering)
  - `false`: Creates a shared schedule (event)
  - Omitted: Timed (`at`) defaults to event; date-only (`on`) defaults to to-do
- `done_at` (optional): Date offset when marked done

**Note:** A schedule should have EITHER `at` (timestamp) OR `on` (date), not both.

```yaml
# Timed event
schedule:
  at: "+0d 09:00 / +0d 09:30"
  recurrence_rule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"

# All-day task
schedule:
  on: "+3d / +5d"

# Completed task
schedule:
  on: "-1d"
  done_at: "-1d 16:00"

# Duration-based
schedule:
  at: "+0d 14:00"
  duration: "45 minutes"
```

## Links

Links are external references attached to threads — emails, messages, issues, pull requests, documents, etc. They display with logos from their source.

**Fields:**

- `source_ref` (optional): Reference to a source (for logo resolution)
- `type` (optional): Link type (e.g., "message", "email", "issue") — must match a link type in the source
- `status` (optional): Status string (e.g., "open", "closed")
- `title` (optional): Display title
- `source_url` (optional): External URL
- `assignee_ref` (optional): Contact ref for assignee
- `author_ref` (optional): Contact ref for author
- `meta` (optional): Arbitrary metadata object

```yaml
links:
  - source_ref: slack
    type: message
    title: "#project-discussion"
    source_url: "https://slack.com/archives/C123/p456"

  - source_ref: github
    type: issue
    status: open
    title: "Fix login timeout #42"
    source_url: "https://github.com/org/repo/issues/42"
    assignee_ref: alice

  - source_ref: gmail
    type: email
    title: "Re: Project proposal"
    source_url: "mailto:client@example.com"
    author_ref: bob
```

## Notes

Notes are content associated with a thread, stored as separate entities.

**Fields:**

- `ref` (optional): Unique reference string (only needed if referenced elsewhere)
- `created` (required): Date offset when this note was created (e.g., "-2d 14:30", "+1w 09:00")
- `author_ref` (optional, default: "user"): Reference to contact or "user"
- `content` (optional): Markdown content (preferred field name)
- `note` (optional): Markdown content (alias for backward compatibility)
- `mentions` (optional): Array of contact refs mentioned
- `actions` (optional): Array of action objects (file attachments, etc.)
- `tags` (optional): Object mapping tag names to actor arrays
- `draft` (optional, default: false): Whether this is a draft
- `private` (optional, default: false): Whether this is private

```yaml
threads:
  - title: Project kickoff meeting
    priority_ref: project-alpha
    schedule:
      at: "+0d 14:00 / +0d 15:00"
    notes:
      - created: "+0d 14:30"
        content: "Great discussion about the architecture"
        author_ref: alice
        tags:
          star: [user]

      - created: "+0d 15:05"
        content: "Action items:\n- Set up repository\n- Create project board"
        author_ref: user
```

### File Attachments

Notes can include file attachments via the `actions` field. Files must be uploaded to R2 separately; the action references the file by its UUID.

```yaml
notes:
  - created: "+0d 10:00"
    content: "Here's the design mockup"
    actions:
      - type: file
        fileId: "b7e3f1a2-4d5c-6e8f-9a0b-1c2d3e4f5a6b"
        fileName: mockup.png
        fileSize: 245000
        mimeType: image/png
```

## Date Offset Syntax

All dates and times are specified as offsets from `config.baseDate`. Time-of-day is preserved.

**Format:** `[+/-]<number><unit> [HH:MM]`

**Units:**

- `d`: days
- `w`: weeks
- `M`: months
- `y`: years

**Examples:**

- `+0d 14:00`: Today at 2:00 PM
- `+7d 09:30`: 7 days from base date at 9:30 AM
- `-2w 18:00`: 2 weeks before base date at 6:00 PM
- `+1M`: 1 month from base date (all-day, no time specified)

**Ranges** (for `at` and `on` fields):

- `+0d 10:00 / +0d 11:00`: 10:00 AM to 11:00 AM today
- `+3d / +5d`: 3-5 days from base date (all-day range)

**Note:** If no time is specified, it's treated as all-day (use `on` field instead of `at`).

## Tags

Tags are labels applied to threads or notes. Multiple users can apply the same count tag, while toggle tags can only have one actor.
Use these sparingly and intentionally to reflect meaningful states or reactions.

**Format:** Object with tag names as keys and arrays of actor refs as values.

**Available tags:**

- **Toggle**: `pinned`, `urgent`, `todo`, `goal`, `decision`, `waiting`, `blocked`, `warning`, `question`, `star`, `idea`
- **Count (reactions)**: `yes`, `no`, `volunteer`, `tada`

```yaml
tags:
  pinned: [user] # User pinned this
  urgent: [user, alice] # User and Alice marked as urgent
  todo: [user] # User marked as to-do
  yes: [user, alice, bob] # Three people gave thumbs up
```

## Complete Example

```yaml
config:
  baseDate: "2025-01-15"
  email: "charlie@example.com"
  userName: "Charlie Davis"

contacts:
  - ref: alice
    email: alice@example.com
    name: Alice Johnson

  - ref: bob
    email: bob@company.com
    name: Bob Smith

priorities:
  - ref: work
    title: Work
    root: true
    settings:
      color: 0
    children:
      - ref: project-alpha
        title: Project Alpha
        children:
          - ref: sprint-1
            title: Sprint 1

sources:
  - ref: slack
    name: Slack
    priority_ref: work
    logo: "https://api.iconify.design/logos/slack-icon.svg"
    link_types:
      - type: message
        label: Message
        logo: "https://api.iconify.design/logos/slack-icon.svg"

  - ref: github
    name: GitHub
    priority_ref: work
    logo: "https://api.iconify.design/logos/github-icon.svg"
    logo_dark: "https://api.iconify.design/simple-icons/github.svg?color=%23FFFFFF"
    link_types:
      - type: issue
        label: Issue
        logo: "https://api.iconify.design/logos/github-icon.svg"
        logo_dark: "https://api.iconify.design/simple-icons/github.svg?color=%23FFFFFF"

threads:
  - title: Team Standup
    priority_ref: project-alpha
    schedule:
      at: "+0d 09:00 / +0d 09:30"
      recurrence_rule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
    tags:
      pinned: [user]
    notes:
      - created: "+0d 09:15"
        content: "Working on feature X"
        author_ref: alice

  - title: Complete API documentation
    priority_ref: sprint-1
    schedule:
      on: "+2d"
    links:
      - source_ref: github
        type: issue
        status: open
        title: "API docs update #15"
        source_url: "https://github.com/org/repo/issues/15"
        assignee_ref: bob
    tags:
      todo: [user]
      urgent: [user]
    notes:
      - created: "+2d 10:00"
        content: "Reference the API documentation template"

  - title: Slack thread about deployment
    priority_ref: project-alpha
    links:
      - source_ref: slack
        type: message
        title: "#deployments"
        source_url: "https://slack.com/archives/C123/p456"
    notes:
      - created: "-1d 14:00"
        content: "Deployment went smoothly, all services are green"
        author_ref: bob
```

## Common Mistakes

### Forgetting schedule for events

Threads that represent events need a `schedule` block.

❌ **Wrong:**

```yaml
- title: Team meeting
  priority_ref: project
```

✓ **Correct:**

```yaml
- title: Team meeting
  priority_ref: project
  schedule:
    at: "+1d 14:00 / +1d 15:00"
```

### Marking recurring threads as done

Recurring threads cannot be marked as done.

❌ **Wrong:**

```yaml
- title: Daily standup
  priority_ref: project
  schedule:
    at: "+0d 09:00 / +0d 09:30"
    recurrence_rule: "FREQ=DAILY"
    done_at: "+0d"
```

✓ **Correct:**

```yaml
- title: Daily standup
  priority_ref: project
  schedule:
    at: "+0d 09:00 / +0d 09:30"
    recurrence_rule: "FREQ=DAILY"
    # No done_at field
```

### Missing source_ref on links

Links need a `source_ref` to resolve logos.

❌ **Wrong:**

```yaml
links:
  - type: message
    title: "#general"
```

✓ **Correct:**

```yaml
links:
  - source_ref: slack
    type: message
    title: "#general"
```

# Crafting Good Sample Data

- Create intrigue, action, and/or humor, telling a story through the threads.
- Populate a wholistic scope for their whole life while focusing on their work.
- If the scenario lends itself to focus on a particular priority, add extra detail there. The screenshot will be made with that priority focused, which may list all priorities in the sidebar, and all events from all priorities in the timeline, but only notes and actions related to the focused priority.
- Select a base date reasonable for the scenario, and make that the center of activity. Items before that date will show in the past, items after that date will show upcoming.
- Add two full days of threads before the base date, current threads on the base date, and two full days after. The first and last day will likely be off screen for the screenshots.
- Pick one thread to be the current focus and add a detailed set of notes.
- Add diverse links from various sources (Slack, Gmail, GitHub, etc.) to showcase how Plot brings external context together.
- The overriding goal is to demonstrate how Plot brings everything together in a way that drives clarity and action.
