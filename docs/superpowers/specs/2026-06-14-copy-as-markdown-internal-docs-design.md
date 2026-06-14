# "Copy as Markdown" on internal docs pages

## Goal

On each internal doc page — `/internal/features`, `/internal/updates`, `/internal/voice` —
add a button in the top-right of the content area that copies the **raw `.md` source**
to the clipboard. The copied text is the synced file verbatim (no stripping of the title,
front-matter, or anything else), so a team member can paste a doc straight into an LLM or
another tool.

## Background

The internal docs site lives in `apps/site` (React Router v7, SSR + hydration). The
pipeline:

1. `apps/site/scripts/sync-internal-docs.mjs` copies `docs/{features,updates,voice}.md`
   into `apps/site/app/lib/internal-docs/`.
2. `apps/site/app/lib/internal-docs.server.ts` imports those files with `?raw`, renders
   each to HTML with `marked`, and exposes `renderFeatures()` / `renderUpdates()` /
   `renderVoice()`, each currently returning an HTML `string`.
3. Each route (`internal.features.tsx`, `internal.updates.tsx`, `internal.voice.tsx`) calls
   the matching render function in its `loader` and dumps the HTML through
   `dangerouslySetInnerHTML` inside a `Container` + `TypographyStylesProvider`.
4. `internal-layout.tsx` is the shared shell (header nav + `Outlet`); `internal._index.tsx`
   is the link index.

The three route bodies are near-identical. There is an existing clipboard precedent in
`apps/site/app/routes/slack.tsx` (manual `useState` + `navigator.clipboard.writeText` +
`IconCopy`/`IconCheck` from `@tabler/icons-react`). Mantine 8.3 is the UI library and ships
a purpose-built `CopyButton` component.

## Design

### 1. Expose the raw markdown from the server module

`apps/site/app/lib/internal-docs.server.ts`: change `renderFeatures` / `renderUpdates` /
`renderVoice` to each return `{ html: string; markdown: string }` instead of a bare HTML
string. The raw `?raw` string is already in scope in that file, so this only adds the
markdown field to the existing return — the bundled source stays exactly as today.

### 2. Shared `InternalDoc` component

New `apps/site/app/components/internal-doc.tsx` — a client-interactive component (clipboard
runs on click in the browser; no RSC concerns under RR v7 SSR + hydration, same as
`slack.tsx`). Props: `{ html: string; markdown: string }`. It renders:

- The `Container` (size `md`, matching the current voice/features pages).
- A right-aligned (`Group justify="flex-end"`) Mantine `CopyButton` with `value={markdown}`
  and `timeout={1500}`. Label toggles "Copy as Markdown" → "Copied", icon toggles
  `IconCopy` → `IconCheck`. `CopyButton`'s render prop handles the copied-state timeout, so
  no hand-rolled `useState` is needed; the manual `slack.tsx` pattern is an acceptable
  fallback if `CopyButton` proves awkward.
- The `TypographyStylesProvider` wrapping the existing
  `<div className="internal-doc" dangerouslySetInnerHTML={{ __html: html }} />`.

This de-duplicates the three route bodies into one place.

### 3. Wire the three routes

Each of `internal.features.tsx`, `internal.updates.tsx`, `internal.voice.tsx`:

- Loader returns the `{ html, markdown }` object from the (updated) render function. Keep
  `requireTeamMember(args)` and the existing `meta`.
- Component renders `<InternalDoc html={loaderData.html} markdown={loaderData.markdown} />`.

## Out of scope

- `/internal` index page — no single doc to copy.
- The global `internal-layout.tsx` header — the chosen placement is per-doc, top-right of
  the content, not a global header button.
- Any change to the sync script or the `docs/*.md` source files.

## Verification

- `pnpm --filter @plotday/site typecheck` (or the package's lint/build) is clean.
- Manual: run the site, open one internal doc page, click "Copy as Markdown", confirm the
  label/icon flips to "Copied" and the clipboard holds the raw `.md` text.
