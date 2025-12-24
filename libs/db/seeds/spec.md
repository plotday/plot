# Plot Seed Data Specification

This document defines the YAML format for generating sample seed data for the Plot application. This format is designed to be both human-readable and LLM-friendly for generating screenshot-quality test data.

## Overview

The seed data format allows you to define:

- **Contacts**: People and their details. Use personal names, not titles.
- **Priorities**: Hierarchical project/folder structure. All users have a single, root priority called Everything.
  Below it are major areas of their life, like Work, Personal, Social. Add 1-3 levels below each of these.
- **Activities**: Tasks, events, notes, messages, and documents
- **Notes**: Updates and messages related to an activity (can contain links and mentions)
- **Tags**: Either categorize activities (e.g. Urgent, Decision; use sparingly), or reactions (e.g. Yes, No, Volunteer)
- **Settings**: User-specific priority settings, like colors

All dates are specified as offsets from a base date, allowing identical data to be generated at different points in time.

## Top-Level Structure

```yaml
config:
  baseDate: "2025-01-15" # Base date for all date offsets (YYYY-MM-DD)
  userId: "uuid-string" # UUID of the user to generate data for

contacts:
  -  # Contact definitions

priorities:
  -  # Priority definitions

activities:
  -  # Activity definitions
```

## Config Section

**Required fields:**

- `baseDate`: ISO date string (YYYY-MM-DD) - all date offsets are calculated from this
- `userId`: UUID string - the user ID for whom all data is generated

```yaml
config:
  baseDate: "2025-01-15"
  userId: "123e4567-e89b-12d3-a456-426614174000"
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

- `user`: Always refers to the user specified in `config.userId`

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

## Activities

Activities can be tasks (actions), calendar events, or notes. They can have associated notes.

**Activity Types:**

- `action`: A task assigned to someone. Always requires an `assignee_ref`. Use `on` in the future to indicate something scheduled, and `done_at` to indicate completion.
- `event`: A calendar event. Requires a scheduled time in `at`.
- `note`: Everything else -- general notes, discussions, messages, and external documents. The content is in the notes.

**Fields:**

- `ref` (optional): Unique reference string (only needed if referenced elsewhere)
- `title` (optional): Display title
- `type` (required): One of `action`, `event`, `note`
- `priority_ref` (required): Reference to a priority
- `author_ref` (optional, default: "user"): Reference to contact or "user"
- `assignee_ref` (**required for actions**, optional for events/notes): Reference to contact or "user"
  - For `type: action`: **REQUIRED** - every action must have an assignee
  - For `type: event` or `type: note`: Optional
  - Use `assignee_ref: user` for self-assigned tasks
- `done_at` (optional): Date offset when marked done
- `at` (optional): Timestamp range for events (see Date Offsets)
- `on` (optional): Scheduled dates for future actions (See Date Offsets)
- `recurrence_rule` (optional): iCalendar RRULE string
- `tags` (optional): Object mapping tag names to actor arrays
- `notes` (optional but typically at least one): Array of note objects (see Notes section)

**Note:** Activities must have EITHER `at` (timestamp) OR `on` (date), not both.

```yaml
activities:
  - ref: standup
    title: Daily Standup
    type: event
    priority_ref: project-alpha
    at: "+0d 09:00 / +0d 09:30" # Today 9:00-9:30 AM
    recurrence_rule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
    tags:
      pinned: [user]
    notes:
      - note: "Yesterday: Completed API integration\n\nFinished the REST API integration with the new service"
        author_ref: alice

      - note: "Today: Working on frontend"
        author_ref: alice

  - title: Write project proposal
    type: action
    priority_ref: project-beta
    on: "+3d / +5d" # 3-5 days from base date (all-day)
    assignee_ref: bob
    tags:
      todo: [user]
      urgent: [user, alice]
    notes:
      - note: "Use the proposal template for this"
        links:
          - url: https://docs.example.com/proposal-template
            title: Proposal Template
            description: Use this template
```

## Notes

Notes are content associated with an activity, stored as separate entities that reference their parent activity.

**Fields:**

- `ref` (optional): Unique reference string (only needed if referenced elsewhere)
- `author_ref` (optional, default: "user"): Reference to contact or "user"
- `note` (optional): Markdown content
- `links` (optional): Array of link objects
- `mentions` (optional): Array of contact refs mentioned
- `tags` (optional): Object mapping tag names to actor arrays

**Note:** Notes are always associated with an activity through the `notes` array in the activity definition.

```yaml
activities:
  - title: Project kickoff meeting
    type: event
    priority_ref: project-alpha
    at: "+0d 14:00 / +0d 15:00"
    notes:
      - note: "Great discussion about the architecture"
        author_ref: alice
        tags:
          star: [user]

      - note: "Action items:\n- Set up repository\n- Create project board"
        author_ref: user
        links:
          - url: https://github.com/org/repo
            title: Project Repository
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

Tags are labels applied to activities. Multiple users can apply the same count tag, while toggle tags can only have one actor.
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

## Links

Links are URLs with optional metadata.

```yaml
links:
  - url: https://example.com/doc
    title: Documentation
    description: Project documentation

  - url: https://github.com/org/repo/pull/123
    title: "PR #123"
```

## Complete Example

```yaml
config:
  baseDate: "2025-01-15"
  userId: "123e4567-e89b-12d3-a456-426614174000"

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

activities:
  - title: Team Standup
    type: event
    priority_ref: project-alpha
    at: "+0d 09:00 / +0d 09:30"
    recurrence_rule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
    tags:
      pinned: [user]
    notes:
      - note: "Working on feature X"
        author_ref: alice

  - title: Complete API documentation
    type: action
    priority_ref: sprint-1
    on: "+2d"
    assignee_ref: bob
    tags:
      todo: [user]
      urgent: [user]
    notes:
      - note: "Reference the API documentation template"
        links:
          - url: https://docs.example.com/api
            title: API Docs
```

## Common Mistakes

### Forgetting assignee_ref on actions

Actions are tasks assigned to someone and **always require an assignee**.

❌ **Wrong:**

```yaml
- title: Complete documentation
  type: action
  on: "+1d"
  tags:
    todo: [user]
```

✓ **Correct:**

```yaml
- title: Complete documentation
  type: action
  on: "+1d"
  assignee_ref: user # Required for all actions
  tags:
    todo: [user]
```

### Forgetting schedule for actions/events

Actions and events must have a schedule (either `at` or `on`).

❌ **Wrong:**

```yaml
- title: Team meeting
  type: event
  priority_ref: project
```

✓ **Correct:**

```yaml
- title: Team meeting
  type: event
  priority_ref: project
  at: "+1d 14:00 / +1d 15:00" # Timed event
  # OR: on: "+1d"  # All-day event
```

### Marking recurring activities as done

Recurring activities cannot be marked as done.

❌ **Wrong:**

```yaml
- title: Daily standup
  type: event
  at: "+0d 09:00 / +0d 09:30"
  recurrence_rule: "FREQ=DAILY"
  done_at: "+0d" # Cannot mark recurring as done
```

✓ **Correct:**

```yaml
- title: Daily standup
  type: event
  at: "+0d 09:00 / +0d 09:30"
  recurrence_rule: "FREQ=DAILY"
  # No done_at field
```

# Crafting Good Sample Data

- Create intrigue, action, and/or humor, telling a story through the activities.
- Populate a wholistic scope for their whole life while focusing on their work.
- If the scenario lends itself to focus on a particular priority, add extra detail there. The screenshot will be made with that priority focused, which may list all priorities in the sidebar, and all events from all priorities in the timeline, but only notes and actions related to the focused priority.
- Select a base date reasonable for the scenario, and make that the center of activity. Items before that date will show in the past, items after that date will show upcoming.
- Add two full days of activities before the base date, current activities on the base date, and two full days after. The first and last day will likely be off screen for the screenshots.
- Pick one activity to be the current focus and add a detailed set of notes.
- The overriding goal is to demonstrate how Plot brings everything together in a way that drives clarity and action.
