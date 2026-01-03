# Plot Seed Data Generator

Generate SQL seed data from YAML definitions for screenshots and testing.

## Quick Start

```bash
# Set required environment variables
export SUPABASE_URL="http://127.0.0.1:54321"
export SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"

# Generate SQL to stdout
pnpm gen-seed libs/db/seeds/screenshot-data.yaml

# Generate and save to file
pnpm gen-seed my-data.yaml > seed.sql

# Generate and apply to local database
pnpm gen-seed my-data.yaml | psql -d plot_local
```

## Requirements

- **Environment Variables**: The generator requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to create or lookup users via the Supabase Admin API
- **Local Testing**: For local development, users are created with their email as the password for convenience

## Features

- **Reproducible**: Same YAML + base date = identical SQL output
- **Date offsets**: All dates relative to a base date (easy to shift scenarios in time)
- **Nested structures**: Priorities and activity threads use intuitive YAML nesting
- **Ref-based linking**: Reference entities by name instead of UUIDs
- **LLM-friendly**: YAML format designed for LLM-generated seed data
- **Validation**: Comprehensive validation with helpful error messages

## YAML Format

See [YAML_SPEC.md](./YAML_SPEC.md) for the complete specification.

### Basic Structure

```yaml
config:
  baseDate: "2025-01-15" # All dates are offsets from this
  email: "user@example.com" # User email (used as password for local testing)
  userName: "Your Name" # Display name for the user

contacts:
  - ref: alice
    email: alice@example.com
    name: Alice Johnson

priorities:
  - ref: work
    title: Work
    root: true
    children:
      - ref: project-a
        title: Project Alpha

activities:
  - title: Team Meeting
    type: event
    priority_ref: project-a
    at: "+0d 10:00 / +0d 11:00" # Today 10-11 AM
    tags:
      pinned: [user]
```

### Date Offset Syntax

Dates are specified as offsets from the base date:

- `+0d 14:00` - Today at 2:00 PM
- `+7d 09:30` - 7 days from base at 9:30 AM
- `-2w 18:00` - 2 weeks before base at 6:00 PM
- `+1M` - 1 month from base (all-day)

Units: `d` (days), `w` (weeks), `M` (months), `y` (years)

Ranges use `/`:

- `+0d 10:00 / +0d 11:00` - 10-11 AM today
- `+3d / +5d` - 3-5 days from base (all-day range)

### Entity References

Use `ref` to name entities and `*_ref` to reference them:

```yaml
priorities:
  - ref: my-project
    title: My Project

activities:
  - title: A task
    priority_ref: my-project # References the priority above
    author_ref: alice # References a contact
    assignee_ref: bob
```

Special ref: `user` always refers to the user specified in `config.email`

### Nested Structures

Priorities and activities support nesting:

```yaml
priorities:
  - ref: work
    title: Work
    children:
      - ref: project-a
        title: Project A
        children:
          - ref: sprint-1
            title: Sprint 1

activities:
  - title: Discussion thread
    type: note
    priority_ref: work
    children:
      - title: Reply 1
        type: note
      - title: Reply 2
        type: note
```

## Examples

### Screenshot Scenario

Generate realistic data for app screenshots:

```yaml
config:
  baseDate: "2025-01-15"
  email: "charlie@company.com"
  userName: "Charlie Davis"

contacts:
  - ref: alice
    email: alice@company.com
    name: Alice Johnson
  - ref: bob
    email: bob@company.com
    name: Bob Smith

priorities:
  - ref: work
    title: Work
    root: true
    settings:
      color: "#3B82F6"
    children:
      - ref: mobile-app
        title: Mobile App Redesign
      - ref: api-migration
        title: API v2 Migration

activities:
  # Daily standup (recurring)
  - title: Daily Standup
    type: event
    priority_ref: mobile-app
    at: "+0d 09:00 / +0d 09:30"
    recurrence_rule: "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"
    tags:
      pinned: [user]

  # Task with thread
  - title: Implement new login flow
    type: action
    priority_ref: mobile-app
    on: "+0d / +2d"
    assignee_ref: alice
    tags:
      todo: [user]
      urgent: [user]
    children:
      - title: "Design looks great! 👍"
        type: note
        author_ref: bob
        tags:
          yes: [bob]

  # Completed task
  - title: Update API documentation
    type: action
    priority_ref: api-migration
    done_at: "-1d 16:00"
    tags:
      done: [user]
```

### Project Planning

```yaml
config:
  baseDate: "2025-01-15"
  email: "user@example.com"
  userName: "Project Manager"

priorities:
  - ref: q1-goals
    title: Q1 2025 Goals
    root: true
    children:
      - ref: launch
        title: Product Launch
      - ref: growth
        title: User Growth

activities:
  - title: Launch prep tasks
    type: note
    priority_ref: launch
    children:
      - title: Finalize marketing materials
        type: action
        on: "+7d"
        tags:
          todo: [user]

      - title: Set up analytics
        type: action
        on: "+10d"
        tags:
          todo: [user]

      - title: Launch date
        type: event
        on: "+14d"
        tags:
          goal: [user]
```

## LLM Prompting

The YAML format is designed to be generated by LLMs. Example prompt:

```
Generate Plot seed data in YAML format for this scenario:
- Base date: 2025-01-15
- A software development team with 3 developers (Alice, Bob, Carol)
- Two projects: "Mobile App Redesign" and "API v2 Migration"
- Include daily standups (recurring), sprint planning, various tasks
- Some tasks should be completed, some in progress, some blocked
- Include realistic notes and comments in threads
- Use appropriate tags (urgent, todo, done, blocked)
- Make it look like realistic project activity over 2 weeks

Format according to the Plot Seed Data YAML Specification.
```

See [YAML_SPEC.md](./YAML_SPEC.md) for the full specification to include in your LLM context.

## Validation

The generator validates:

- Config section is complete and valid
- All refs are unique within their type
- All ref references point to existing entities
- Activities have either `at` or `on`, not both
- Recurring activities have a schedule
- Tag names are valid
- Email addresses are properly formatted
- Date offsets use valid syntax

Validation errors show the path and message:

```
Validation errors:
  activities[0].priority_ref: Unknown priority_ref: nonexistent
  activities[1]: Activity cannot have both 'at' and 'on' fields
  contacts[0].email: Invalid email
```

## Generated SQL

The generator produces PostgreSQL-compatible SQL with:

- UUIDs for all entity IDs
- ltree paths for hierarchical structures
- Proper foreign key references
- JSONB for metadata
- Array literals for mentions
- tstzrange/daterange for schedules

Example output:

```sql
-- Generated by seed-generator on 2025-01-15T12:00:00.000Z
-- Config: baseDate=2025-01-15, email=user@example.com, userName=User Name, userId=123e4567-e89b-12d3-a456-426614174000

BEGIN;

-- Contacts
INSERT INTO contact (id, email, name, avatar_url, user_id, created_at, updated_at)
VALUES
  ('...', 'alice@company.com', 'Alice Johnson', NULL, NULL, NOW(), NOW());

-- Priorities
INSERT INTO priority (id, created_by, title, path, root, archived_at, created_at, updated_at)
VALUES
  ('...', '...', 'Work', 'aBcD1234eFgH', true, NULL, NOW(), NOW());

-- Activities
-- ...

COMMIT;
```

## Development

### Requirements

- Node.js 18+
- pnpm
- TypeScript

### File Structure

```
libs/db/seeds/
├── README.md              # This file
├── YAML_SPEC.md           # Complete YAML format specification
├── generate-seed.ts       # Main generator script
├── types.ts               # TypeScript type definitions
└── screenshot-data.yaml   # Example seed data
```

### Adding New Features

1. Update `YAML_SPEC.md` with new format
2. Update `types.ts` with new TypeScript types
3. Add validation in `validate()` function
4. Add SQL generation in `generateSQL()` function
5. Update examples

## Troubleshooting

### "Missing baseDate" or "Invalid date format"

Ensure `config.baseDate` is in YYYY-MM-DD format:

```yaml
config:
  baseDate: "2025-01-15" # ✓ Correct
  email: "user@example.com"
  userName: "User Name"
  # baseDate: 2025-01-15  # ✗ Wrong (unquoted)
  # baseDate: "01/15/2025"  # ✗ Wrong (format)
```

### "Missing email" or "Invalid email format"

Ensure `config.email` and `config.userName` are provided:

```yaml
config:
  baseDate: "2025-01-15"
  email: "user@example.com" # ✓ Required, valid email format
  userName: "User Name" # ✓ Required
```

### "Unknown priority_ref"

Ensure the priority is defined before it's referenced:

```yaml
priorities:
  - ref: work
    title: Work

activities:
  - priority_ref: work # ✓ 'work' is defined above
```

### "Activity cannot have both 'at' and 'on' fields"

Use `at` for specific times (events) or `on` for all-day (tasks), not both:

```yaml
# Event with time
- type: event
  at: "+0d 10:00 / +0d 11:00"

# All-day task
- type: action
  on: "+3d / +5d"
```

### "Invalid date offset"

Check offset syntax:

```yaml
at: "+7d 14:00" # ✓ Correct
# at: "+7 14:00"    # ✗ Missing unit
# at: "7d 14:00"    # ✗ Missing +/-
# at: "+7d 14:00:00"  # ✗ Seconds not supported
```
