# Internal docs hosting + release-stamped changelog — Design

Date: 2026-06-10
Status: Approved (brainstorming) — pending implementation plan

## Goal

Two improvements to the `docs/features.md` and `docs/updates.md` processes:

1. **Host both docs privately at deploy time** somewhere non-technical
   teammates (who have no GitHub account) can read them.
2. **Stamp `docs/updates.md` with the release version on every native
   release**, so the team can see what shipped in each release.

## Decisions (locked in during brainstorming)

- **Access gate:** a gated route on the existing marketing site
  (`apps/site`), behind Clerk sign-in, restricted to the `@plot.day` email
  domain. Reuses existing Clerk auth + Cloudflare deploy pipeline.
- **Who can view:** any signed-in Clerk user whose primary email ends in
  `@plot.day`.
- **Release stamping:** automated inside `release.yml` — no manual step.

## Hard security constraint

The doc content must **never** be reachable without authentication. Gating
the route on the client is not enough: if markdown is statically imported
into a client component, Vite bundles it into the public JS that anyone can
download unauthenticated.

The design enforces server-only delivery:

- The auth + domain check runs in the **server `loader`**, before any
  content is read. Unauthenticated → redirect to `/signin`, zero doc bytes.
  Signed-in non-`@plot.day` → 403, zero doc bytes.
- The markdown is read and rendered **server-side only** and returned *from
  the loader*. It is imported with Vite's `?raw` **only** from a `.server.ts`
  module, which is consumed **only** by loaders — so it lands in the server
  bundle exclusively, never the client bundle.
- The one discipline to hold: **no** static `import doc from ".../updates.md"`
  in any component. Content flows through the loader only.

This is the same server-side auth primitive already used in
`apps/site/app/routes/twister.login.tsx` (`getAuth(args)` from
`@clerk/react-router/ssr.server`).

---

## Part A — Private hosted docs on the site

### Build-time content bundling

The Cloudflare Worker has no runtime filesystem (`ssr.target: webworker` in
`apps/site/vite.config.ts`), so the docs must be bundled at build time.

- A prebuild step `apps/site/scripts/sync-internal-docs.mjs` copies the two
  repo-root files `docs/features.md` and `docs/updates.md` into a
  **gitignored**, server-only directory `apps/site/app/lib/internal-docs/`.
- The site `build` script becomes:
  `node scripts/sync-internal-docs.mjs && react-router build`.
- Result: the hosted docs always reflect `main` at the moment of deploy
  (deploy-site checks out the default branch). "Hosted at deploy time."

### New modules

- `apps/site/app/lib/internal-auth.server.ts` — exports
  `requireTeamMember(args)`:
  - `initClerkEnv(args.context.cloudflare.env)` then `getAuth(args)`.
  - If `!auth.userId` → `throw redirect("/signin?returnTo=" + encodeURIComponent(path))`.
  - Fetch the user's primary email via the Clerk backend client
    (`createClerkClient({ secretKey })` → `users.getUser(userId)` →
    `primaryEmailAddress.emailAddress`). (Exact Clerk client import to be
    confirmed in the plan; `getAuth` session claims may also carry email.)
  - If email does not end in `@plot.day` (case-insensitive) →
    `throw new Response("Forbidden", { status: 403 })`.
  - Returns `{ email }` on success.
- `apps/site/app/lib/internal-docs.server.ts` — holds the `?raw` markdown
  imports and renders them to HTML with `marked` (new dependency). Exports
  `renderFeatures()` and `renderUpdates()` returning HTML strings. Content is
  first-party and gated, so `marked` alone (no sanitizer) is acceptable.

### New routes (own minimal layout, NOT the public marketing layout)

Registered in `apps/site/app/routes.ts` under a new
`layout("./components/internal-layout.tsx", [...])` block — **not** inside
`public-layout`, and **not** linked from any public header/footer/sitemap:

- `route("internal", "routes/internal._index.tsx")` — landing: links to the
  two docs + sign-out.
- `route("internal/features", "routes/internal.features.tsx")` — renders
  `docs/features.md`.
- `route("internal/updates", "routes/internal.updates.tsx")` — renders
  `docs/updates.md`.

Each route:

- Loader calls `requireTeamMember(args)` **first** (defense in depth — every
  loader re-checks, not just the layout), then returns rendered HTML from
  `internal-docs.server.ts`.
- Component renders the HTML via `dangerouslySetInnerHTML` (first-party,
  gated content).
- `meta` includes `<meta name="robots" content="noindex">`.

`internal-layout.tsx` provides simple internal chrome (title, tabs for
Features / Updates, sign-out) and may also call `requireTeamMember` in its
own loader for the redirect-to-signin UX; child loaders still self-check.

### New dependency

- `marked` (server-side markdown → HTML).

---

## Part B — Version-stamp `updates.md` on every native release

### Convention change

- **Today:** the top of `updates.md` (above the first `---`) is the
  unreleased pile, archived manually by inserting `---`.
- **New:** unreleased bullets accumulate at the very top, **above the first
  `## <version> — <date>` heading**. At a native release the workflow inserts
  the heading automatically. Legacy `---`-delimited blocks stay untouched at
  the bottom as history (no destructive back-fill of versions).

### Heading format

`## {release_version} — {YYYY-MM-DD}` — e.g. `## 1.1.0+296 — 2026-06-10`.
`release_version` matches existing store tags like `ios/1.1.0+296`.

### Automation in `release.yml` → `prepare-release` job

A script `scripts/stamp-updates.mjs` (run on `main` in the same place the job
already checks out `main` and bumps the build number):

1. Read `docs/updates.md`.
2. Compute the **unreleased block** = everything above the first line
   matching `^## ` (the first existing version heading; if none, the whole
   file above the first legacy `---`, else the whole file).
3. If the unreleased block contains **no** `^- ` bullet → **skip** stamping
   and log "no user-facing changes" to the job summary. (Never create empty
   release sections.)
4. Otherwise prepend `## {release_version} — {YYYY-MM-DD}\n\n` immediately
   above the unreleased bullets, so they become that release's section and
   the top of the file is clear for the next cycle.
5. The edit is folded into the **same `main` commit** as the pubspec
   build-number bump:
   `Release {release_version}: stamp changelog + bump to {next} [skip ci]`
   (stage both `apps/plot/pubspec.yaml` and `docs/updates.md`).

Notes:

- The stamp lands on `main` only — the canonical changelog the hosted page
  reads. The already-cut `release/<version>` branch and the built apps are
  unaffected (apps don't consume `updates.md`).
- `release_version`, `version_name`, `build_number`, and the date
  (`date -u +%Y-%m-%d`) are all already available / trivially derivable in
  the `prepare-release` job.

### Hosted page tie-in

Once version headings exist, `/internal/updates` renders naturally as one
section per release (h2 headers), with the live unreleased items at the top.

### Doc update

Revise the `AGENTS.md` "Hints" bullet about `docs/updates.md` to describe the
new flow: accumulate bullets at the very top above the first `## ` heading;
`release.yml` auto-stamps the version heading at native release; the manual
`---` archival step is removed (legacy `---` history remains as-is).

---

## Out of scope / non-goals

- Back-filling versions onto the existing `---`-separated history.
- Any change to how the native apps are built or what they bundle.
- Rich per-release accordion UI (h2 sections are sufficient for v1).
- Hosting `features.md` with release stamping (only `updates.md` is stamped).

## Affected files (summary)

- `apps/site/app/routes.ts` — register internal layout + 3 routes.
- `apps/site/app/components/internal-layout.tsx` — new.
- `apps/site/app/routes/internal._index.tsx`, `internal.features.tsx`,
  `internal.updates.tsx` — new.
- `apps/site/app/lib/internal-auth.server.ts` — new.
- `apps/site/app/lib/internal-docs.server.ts` — new.
- `apps/site/scripts/sync-internal-docs.mjs` — new; `package.json` build
  script + `.gitignore` updated.
- `apps/site/package.json` — add `marked`.
- `.github/workflows/release.yml` — stamp step in `prepare-release`.
- `scripts/stamp-updates.mjs` — new.
- `AGENTS.md` — update the `updates.md` hint.
