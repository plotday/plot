# Plot Seed Data Generator

Generate SQL seed data from YAML definitions for screenshots and testing.

## Quick Start

```bash
# Generate SQL to stdout
pnpm gen-seed libs/db/seeds/margot.yaml

# Generate and apply to local database
pnpm gen-seed --apply libs/db/seeds/margot.yaml
```

## Production Demo Accounts

To apply a seed to **production** with a separate login email (so we can receive
sign-in emails at `team+<persona>@plot.day` while the app displays the persona's
fictional email):

```bash
# One-time prep: make sure libs/db/.env.production has CLERK_SECRET_KEY
pnpm --filter @plotday/db get-env

# Then:
pnpm --filter @plotday/db apply-seed:prod \
  libs/db/seeds/margot.yaml \
  --login-email team+margot@plot.day
```

The `apply-seed:prod` wrapper (`scripts/seed-prod`):

1. Prompts for confirmation (set `SEED_PROD_CONFIRM=yes` to skip).
2. Reads `CLERK_SECRET_KEY` from `libs/db/.env.production`.
3. Resolves the prod DB username/password from 1Password (`op` CLI, `plotco`
   account).
4. Auto-starts the Cloud SQL Proxy on `127.0.0.1:5433` if it isn't already
   running (via `pnpm prod-db-connect`).
5. Runs `gen-seed --apply --r2-bucket plot-files-production --r2-remote`,
   uploading any referenced assets via `wrangler r2 object put --remote`.

The YAML's `config.email` becomes the **display** email written to
`public."user".email` and the primary contact. The Clerk user is
created/looked-up by `--login-email`, and its `externalId` is set to the
new DB user ID so authentication via the login email resolves to the
persona.

You'll need to be logged in with the `op` CLI and `wrangler` (api
worker's Cloudflare account) before running this.

## Requirements

- **Local Testing**: For local development, users are created with their email as the password for convenience

### Connectors and a fresh database

When a source's name matches a deployed **public** connector twist (Slack, Gmail,
Google Calendar, …), the seed binds the connection to that public twist and uses
its link-type config. When no public twist exists (e.g. right after a DB reset,
before `plot deploy`), the seed creates a **personal-fallback** twist from the
YAML's own `link_types`.

For the agenda to appear, the user needs a live calendar connection whose link
type declares `includes_schedules`. The seed sets this on its Google Calendar
source, so the agenda works **either way** — deployed connector or personal
fallback. If you reset the DB, you can seed before or after deploying connectors
and the calendar/agenda will still light up. (Other connector niceties — real
logos, channel routing — do benefit from deploying connectors first.)

## Features

- **Reproducible**: Same YAML + base date = identical SQL output
- **Date offsets**: All dates relative to a base date (easy to shift scenarios in time)
- **Nested structures**: Priorities use intuitive YAML nesting
- **Ref-based linking**: Reference entities by name instead of UUIDs
- **Source logos**: External services (Slack, Gmail, GitHub, etc.) with proper logo resolution
- **Focus icons**: Priorities carry a curated `icon` key
- **Groups**: Reusable contact sets for the new-thread picker
- **Channels**: Enabled connection channels (e.g. Slack) for the new-thread picker
- **LLM-friendly**: YAML format designed for LLM-generated seed data
- **Validation**: Comprehensive validation with helpful error messages

## YAML Format

See [spec.md](./spec.md) for the complete specification.

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

roles:
  - ref: work_role
    name: Work
    color: 0

priorities:
  - ref: work_inbox
    title: Inbox
    root: true
    role_ref: work_role
    inbox: true
    children:
      - ref: project-a
        title: Project Alpha
        role_ref: work_role

sources:
  - ref: slack
    name: Slack
    priority_ref: work_inbox
    logo: "https://api.iconify.design/logos/slack-icon.svg"
    link_types:
      - type: message
        label: Message
        logo: "https://api.iconify.design/logos/slack-icon.svg"

threads:
  - title: Team Meeting
    priority_ref: project-a
    schedule:
      at: "+0d 10:00 / +0d 11:00"
    tags:
      pinned: [user]
    links:
      - source_ref: slack
        type: message
        title: "#team-meetings"
        source_url: "https://slack.com/archives/C123/p456"
    notes:
      - created: "+0d 10:30"
        content: "Discussed project timeline and priorities"
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

sources:
  - ref: gmail
    name: Gmail
    priority_ref: my-project
    link_types:
      - type: email
        label: Email
        logo: "https://api.iconify.design/logos/google-gmail.svg"

threads:
  - title: A discussion
    priority_ref: my-project # References the priority above
    links:
      - source_ref: gmail # References the source above
        type: email
        title: "Important email"
    notes:
      - created: "+0d"
        author_ref: alice # References a contact
        content: "Some update"
```

**Reserved ref**: `user` is a special ref that always refers to the user specified in `config.email`. Do NOT define a contact with `ref: user` - the user contact is created automatically from the config.

## Validation

The generator validates:

- Config section is complete and valid
- All refs are unique within their type
- All ref references point to existing entities
- Source refs on links reference defined sources
- Tag names are valid
- Email addresses are properly formatted
- Date offsets use valid syntax

Validation errors show the path and message:

```
Validation errors:
  threads[0].priority_ref: Unknown priority_ref: nonexistent
  threads[1].links[0].source_ref: Unknown source_ref: missing
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
- DO $ blocks for twist/source creation (bigint IDENTITY keys)

## Development

### Requirements

- Node.js 18+
- pnpm
- TypeScript

### File Structure

```
libs/db/seeds/
├── README.md              # This file
├── spec.md                # Complete YAML format specification
├── generate-seed.ts       # Main generator script
├── types.ts               # TypeScript type definitions
├── margot.yaml            # AFC Marlow scenario (the maintained persona)
└── margot.md              # Persona notes for margot.yaml
```

### Adding New Features

1. Update `spec.md` with new format
2. Update `types.ts` with new TypeScript types
3. Add validation in `validate()` function
4. Add SQL generation in `generateSQL()` function
5. Update examples

## Troubleshooting

### "Missing baseDate" or "Invalid date format"

Ensure `config.baseDate` is in YYYY-MM-DD format:

```yaml
config:
  baseDate: "2025-01-15" # Correct
  email: "user@example.com"
  userName: "User Name"
```

### "Unknown priority_ref"

Ensure the priority is defined before it's referenced:

```yaml
priorities:
  - ref: work
    title: Work

threads:
  - priority_ref: work # 'work' is defined above
```

### "Unknown source_ref"

Ensure the source is defined in the `sources` section:

```yaml
sources:
  - ref: slack
    name: Slack
    priority_ref: work
    link_types:
      - type: message
        label: Message
        logo: "https://api.iconify.design/logos/slack-icon.svg"

threads:
  - title: Discussion
    priority_ref: work
    links:
      - source_ref: slack # 'slack' is defined above
        type: message
```

### "Invalid date offset"

Check offset syntax:

```yaml
at: "+7d 14:00" # Correct
# at: "+7 14:00"    # Missing unit
# at: "7d 14:00"    # Missing +/-
# at: "+7d 14:00:00"  # Seconds not supported
```
