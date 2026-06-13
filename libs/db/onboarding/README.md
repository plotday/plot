# Onboarding source

These markdown files are the **canonical source** for Plot's onboarding threads —
the welcome/getting-started threads every new user receives. Edit the content and
state here; do not hand-edit the generated SQL or migrations.

## Layout

```
onboarding/
  global/      One file per global onboarding thread, shared by all users.
  per-user/    Per-user onboarding threads (e.g. the personal welcome).
  README.md    This file.
```

- The **filename numeric prefix** (`01-`, `02-`, …) sets the order of the threads.
- Within a file, the order of `## note: <key>` sections sets the order of the
  notes in that thread.
- **Archive a thread** by deleting its file.

## File format

```markdown
---
key: <thread key>
title: <thread title>
preview: <thread preview>
state:
  active: <true|false>   # whether the thread starts with an actionable to-do
  importance: <int>      # ordering weight in the feed (higher = earlier)
  dateOffset: <int>      # days after signup the thread is scheduled for
---

## note: <note key>
<note content, verbatim markdown>

## note: <next note key>
<note content, verbatim markdown>
```

The frontmatter is YAML. The note bodies below each `## note:` heading are raw
markdown, placed verbatim. A note with the key `todo` is the thread's actionable
task.

## Workflow

1. Edit the content and/or `state` in these markdown files.
2. From `libs/db/`, regenerate the SQL and migration:
   ```bash
   pnpm gen-onboarding
   ```
3. Apply the generated migration to your local database:
   ```bash
   pnpm apply-migrations
   ```
4. Commit the markdown changes **together with** the generated migration, the
   `.snapshot.json`, and the regenerated schema files in the same commit.

## What changes affect whom

- **Global thread content** edits (title, preview, note bodies) affect onboarding
  for all users.
- **Per-user state** (`active` / `importance` / `dateOffset`) and the **per-user
  welcome** thread affect new signups only.
