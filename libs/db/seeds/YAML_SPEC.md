# Plot Seed Data YAML Specification

This document defines the YAML format for generating seed data for the Plot application. This format is designed to be both human-readable and LLM-friendly for generating screenshot-quality test data.

## Overview

The seed data format allows you to define:
- **Contacts**: People and their details
- **Priorities**: Hierarchical project/folder structure
- **Activities**: Tasks, events, and notes with associated note content
- **Notes**: Content associated with activities (markdown, links, mentions)
- **Tags**: Labels applied to activities and notes
- **Settings**: User-specific priority settings

All dates are specified as offsets from a base date, allowing identical data to be generated at different points in time.

## Top-Level Structure

```yaml
config:
  baseDate: "2025-01-15"    # Base date for all date offsets (YYYY-MM-DD)
  userId: "uuid-string"      # UUID of the user to generate data for

contacts:
  - # Contact definitions

priorities:
  - # Priority definitions

activities:
  - # Activity definitions
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

**Fields:**
- `ref` (optional): Unique reference string (only needed if referenced elsewhere)
- `title` (optional): Display title
- `type` (required): One of `action`, `event`, `note`
- `priority_ref` (required): Reference to a priority
- `author_ref` (optional, default: "user"): Reference to contact or "user"
- `assignee_ref` (optional): Reference to contact or "user"
- `draft` (optional, default: false): Whether this is a draft
- `private` (optional, default: false): Whether this is private
- `archived_at` (optional): Date offset when archived
- `done_at` (optional): Date offset when marked done
- `at` (optional): Timestamp range for events (see Date Offsets)
- `on` (optional): Date range for all-day events (see Date Offsets)
- `duration` (optional): Duration string (e.g., "30 minutes", "2 hours")
- `recurrence_rule` (optional): iCalendar RRULE string
- `mentions` (optional): Array of contact refs mentioned
- `tags` (optional): Object mapping tag names to actor arrays
- `notes` (optional): Array of note objects (see Notes section)

**Note:** Activities must have EITHER `at` (timestamp) OR `on` (date), not both.

```yaml
activities:
  - ref: standup
    title: Daily Standup
    type: event
    priority_ref: project-alpha
    at: "+0d 09:00 / +0d 09:30"  # Today 9:00-9:30 AM
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
    on: "+3d / +5d"  # 3-5 days from base date (all-day)
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
- `draft` (optional, default: false): Whether this is a draft
- `private` (optional, default: false): Whether this is private

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

Tags are labels applied to activities. Multiple users can apply the same tag.

**Format:** Object with tag names as keys and arrays of actor refs as values.

**Available tags:**
- **Compute (system-managed)**: `now`, `later`, `done`, `archived`
- **Toggle**: `pinned`, `urgent`, `todo`, `goal`, `decision`, `waiting`, `blocked`, `warning`, `question`, `star`, `idea`
- **Count (reactions)**: `yes`, `no`, `volunteer`, `tada`

```yaml
tags:
  pinned: [user]              # User pinned this
  urgent: [user, alice]       # User and Alice marked as urgent
  todo: [user]                # User marked as to-do
  yes: [user, alice, bob]     # Three people gave thumbs up
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

## LLM Generation Guidelines

When prompting an LLM to generate seed data:

1. **Specify the scenario**: "Generate seed data for a software team with 3 members working on 2 projects"
2. **Request realistic data**: Ask for realistic titles, notes, and timing
3. **Specify date context**: "Base date is 2025-01-15, generate activities for the current week and next week"
4. **Request variety**: Ask for different activity types, tags, and thread depths
5. **Ensure completeness**: Request contacts, priorities, and activities with threads

**Example prompt:**
```
Generate Plot seed data in YAML format for this scenario:
- Base date: 2025-01-15
- A software development team with 3 developers (Alice, Bob, Carol)
- Two projects: "Mobile App Redesign" and "API v2 Migration"
- Include daily standups (recurring), sprint planning meetings, various tasks
- Some tasks should be completed, some in progress, some blocked
- Include realistic notes and comments associated with activities
- Use appropriate tags (urgent, todo, done, blocked, etc.)
- Make it look like realistic project activity over 2 weeks
```

## Validation Rules

The generator will validate:
- All refs are unique within their type
- All ref references exist
- Activities have EITHER `at` OR `on`, not both
- Recurring activities have a schedule (`at` or `on`)
- Tag names are valid (see tag list above)
- Actor refs in tags exist
- Email addresses are properly formatted
- Date offsets are valid syntax
- Only one root priority per user
- Contacts have unique emails

## Implementation Notes

- Generated UUIDs use UUIDv4 for unique IDs
- Activity ordering uses timestamp-based ordering
- All timestamps include timezone (UTC)
- Priority children create proper hierarchical ltree paths
- Notes are stored as separate entities in the `note` table with references to their parent activity
- Links are stored within notes, not directly on activities
