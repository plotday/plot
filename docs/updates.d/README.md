# Changelog fragments

Each user-facing change adds **one file here** instead of editing
`../updates.md`. Because every PR touches a different file, changelog edits
never conflict.

## Add an update

```bash
pnpm updates:new "short description"
```

Then edit the created file. A fragment is one or more `### <Section>` blocks with
bullets — exactly what you'd write in `updates.md`:

```md
### Fixes

- Plain-language description of the change a user would notice.
```

- Use a descriptive feature section (e.g. `### Threads`) for features; put bug
  fixes under `### Fixes` (always rendered last).
- One fragment may contain several sections if a PR spans a feature and a fix.
- Skip internal refactors / infra / changes users wouldn't notice.

## What happens next

- `pnpm updates:next` prints everything queued for the next release.
- The internal docs page (`/internal/updates`) shows queued fragments above the
  released history.
- At release, the fragments are folded into `../updates.md` under the new version
  heading and deleted automatically.
