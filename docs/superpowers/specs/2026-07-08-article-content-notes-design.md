# Auto-attach article content to threads with public links

**Status:** Design approved 2026-07-08. Ready for implementation planning.

## Goal

When a user creates a thread that includes a public article link (via OS share
or manual composition), Plot fetches the linked page, converts it to Markdown,
and adds that content as a note authored by **Plot**. Scraping is cached
globally (cross-user, keyed by normalized URL) so any given page is fetched and
converted at most once. Scraping is also triggered **early**, at compose time,
so that by the time the thread is committed the content is usually already
available — minimizing the wait before the note appears.

## Key insight: the engine already exists

The URL→Markdown extraction pipeline is fully built and tested in
`workers/api/src/extract/*` + `workers/api/src/queue/extract.ts`, but currently
has **no production callers**. This feature is almost entirely *wiring* — two
triggers plus durable delivery of the result as a note. We do **not** build a
new scraper or cache, and we do **not** add a client-facing read-back endpoint
(the content becomes an ordinary synced note).

Reused as-is:

- **`requestExtraction(env, rawUrl)`** (`workers/api/src/extract/request.ts`) —
  already the idempotent trigger: normalizes + SHA-256-hashes the URL, upserts
  an `extracted_url` row with `ON CONFLICT (url_hash) DO NOTHING`, and enqueues
  an `EXTRACT_QUEUE` job **only on a genuine insert**. Safe to call
  concurrently for the same URL; returns the `extracted_url` record (with
  `status`).
- **`EXTRACT_QUEUE` consumer** (`workers/api/src/queue/extract.ts`) — atomic
  row claim → `classifyUrlAccess` pre-filter → fetch HTML (desktop UA, 5 MB
  cap) → defuddle → Markdown, with a Cloudflare Browser Rendering fallback when
  `md.length < 200`. Writes the blob to R2 `ARTICLES_BUCKET/{urlHash}.md` and
  sets terminal status.
- **`extracted_url`** (`libs/db/schema/50-tables/30-extracted_url.sql`) — the
  global, server-only cache (no `user.*` view, no `seq`, never synced).
  `status ∈ {pending, extracting, completed, failed, auth_required, paywalled}`.
- **`classifyUrlAccess`** (`workers/api/src/extract/access.ts`) — short-circuits
  known auth-walled / paywalled hosts to a terminal status. Combined with the
  `md.length < 200` check for SPAs/web-apps, this already implements the
  "not an auth page, not a web app" filtering — no extra client-side filter
  needed.

## Components

### 1. Client warm-up trigger — `POST /extract`

New authed Hono route in `workers/api` (mounted under the app section, e.g.
alongside `link-metadata.ts`).

- Request body: `{ url: string }`.
- Behavior: validate the URL is `http(s)`, call `requestExtraction(c.env, url)`,
  return `{ status }` (200). Idempotent by construction.
- Auth: behind the app's normal user auth. Consider attaching one of the
  existing `RateLimit` bindings to bound abuse (nice-to-have, not required for
  v1).

Called **fire-and-forget** from the Flutter compose sites where the link first
becomes known — these already run a server round-trip (`fetchUrlMetadata`), so
we add a sibling call:

- `apps/plot/lib/page/new_thread.dart` — `_enterLinkMode(url)` (covers both the
  OS-share `sharedUrl` route param **and** a paste into the step-1 filter).
- `apps/plot/lib/widget/note_editor.dart` — `_handleUrlPasteWhenEmpty(url)`.

Implementation: a small helper next to `fetchUrlMetadata` in
`apps/plot/lib/util/url_title.dart` (e.g. `warmArticleExtraction(url)`) that
POSTs via the `api.dart` client, unawaited, swallowing errors. This front-runs
the compose→commit window (target selection + composing + the 5 s
`sendThreadWithUndo` delay), so the extraction is usually already `completed`
when the thread lands.

### 2. Server detect-and-request hook — in `POST /sync/notes`

The article URL rides on the **note**, not a link row: the compose flow appends
an `ExternalUserAction` (`{ type: "external", title, url, favicon? }`) to
`note.actions`, and `POST /sync/notes` persists it via `upsert_note`'s
`p_actions` (verified: `notes.ts:354`, `upsert_note` line 341/369). So the hook
lives in the notes handler.

Add a `waitUntil` block after `upsert_note` succeeds (mirrors the existing
AI-analysis background block). A note **qualifies** only when all hold:

1. **User-authored** — `created_by === c.var.user.id` (not a connector/twist).
2. **First note of its thread** — no earlier note exists on the thread. Matches
   the "first note" intent and prevents auto-fetching links pasted into ongoing
   conversations.
3. **Live** — not `draft`, not held (`send_at` in the future).
4. **Carries a link** — `note.actions` contains at least one
   `ExternalUserAction` with an `http(s)` `url`.

For each qualifying URL (cap at the first ~3 to bound work):

- Call `requestExtraction(c.env, url)`.
- Dispatch on the returned `status`:
  - `completed` → inject the note immediately (Component 4).
  - `failed` / `auth_required` / `paywalled` (terminal) → **do nothing** (silent
    skip — this is the intended behavior for auth pages / web apps / dead URLs).
  - `pending` / `extracting` → register durable delivery (Component 3).

Follow the background-DB rules: open a **fresh** DB connection inside the
`waitUntil` and destroy it in `finally`; never use the request-scoped `c.var.db`
in `waitUntil`. Snapshot needed values (`thread_id`, `user.id`, actions) into
locals first.

### 3. Durable delivery — pending-injection table + fulfillment

The global cache is URL-keyed and thread-agnostic, so "add the note once ready"
needs an explicit URL→waiting-threads mapping.

**New table** `extracted_url_injection` — server-only, same conventions as
`extracted_url` (no `user.*` view, no `seq`, no `archived_at`, never synced):

| column         | type        | notes                                              |
| -------------- | ----------- | -------------------------------------------------- |
| `id`           | bigint PK   | identity                                           |
| `url_hash`     | text        | indexed; matches `extracted_url.url_hash`          |
| `thread_id`    | uuid        | thread to inject into                              |
| `priority_id`  | uuid        | for Plot-instance resolution + notify              |
| `requested_by` | uuid        | user_id (logging / author resolution)              |
| `status`       | text        | `pending` \| `fulfilled` \| `skipped`              |
| `created_at`   | timestamptz | default `now()`                                    |
| `updated_at`   | timestamptz | `update_updated_at` trigger                        |

`UNIQUE (thread_id, url_hash)` makes registration idempotent (retries and
duplicate pushes collapse). Add `api`/`readonly` grants per
`libs/db/AGENTS.md`, an expand migration, and regenerated `types.ts`.

**Fulfillment routine** `fulfillArticleInjection(env, urlHash)`:

- Load the `extracted_url` row for `urlHash`.
  - `completed` → for each `pending` injection row: read R2
    `{urlHash}.md`, insert the Plot note (Component 4), mark the row
    `fulfilled`, ping `SYNC_NOTIFY` for its priority.
  - terminal failure → mark waiting rows `skipped` (no note).
  - still in progress → leave rows `pending`.
- Per-row isolation: a failure injecting into one thread must not block the
  others; catch, `captureException` on unexpected errors, and leave that row
  `pending` for the cron safety-net.

Fulfillment is driven from **three** places for robustness (the user chose
durable delivery):

1. **Queue consumer** (`queue/extract.ts` `runOne`) — after a URL reaches a
   terminal status, call `fulfillArticleInjection(env, urlHash)`. This is the
   primary "add once ready" path. (The consumer already acks even on failure
   and has no retry, so fulfillment errors here must not throw out of the
   handler — see the cron net below.)
2. **Immediate re-check** (Component 2) — after inserting a `pending` row, re-read
   `extracted_url.status`; if it is now `completed`, fulfill inline. Closes the
   race where extraction finishes between the initial status read and the row
   insert (so the consumer's drain found no waiting row).
3. **Cron safety-net** — on the existing `*/5 * * * *` cron, drain
   `pending` injection rows whose `extracted_url.status = 'completed'`, and mark
   `skipped` those whose URL terminal-failed. Catches stragglers from transient
   fulfillment failures.

### 4. The Plot-authored content note

Precedent: `addTrialNote` in `workers/api/src/utils/trial.ts:166-227`.

- Resolve the per-user Plot `twist_instance` via the existing
  `getPlotTwistInstanceId(db, priorityId)` (`workers/api/src/utils/trial.ts`).
  Guard `null` and skip (as `addTrialNote` does) if the user has no Plot
  instance.
- Insert directly into `note`:
  - `created_by = author_id = plotTwistInstanceId`
  - `thread_id`
  - `content = <article markdown>` (see cap below)
  - `link_id = NULL` (a "Plot-tool authored" note, not a connector note)
  - `key = "article:{urlHash}"` for idempotency, with a pre-check select (the
    `(thread_id, link_id, key)` partial unique index does not dedupe NULL-link
    rows, so pre-check like `addTrialNote` at `trial.ts:191-198`).
- After insert, ping the priority's `SYNC_NOTIFY` DO so the note appears live
  (pattern at `trial.ts:311-321`).
- **Content cap:** truncate very long articles to ~100 KB with a trailing
  "… (truncated)" marker, to avoid syncing multi-MB notes. Real articles are
  5–50 KB of Markdown; only Wikipedia mega-pages exceed the cap.

Rendering: because the per-user Plot instance is `is_builtin` and lives in the
client's `TwistInstance` cache, the note resolves to the **"Plot"** name and the
Plot logo avatar (`apps/plot/lib/widget/avatar.dart` `_buildForTwist`). No new
system actor and no special "assistant bubble" style are needed — attribution
is name + logo only.

## Scope (v1)

**In scope**

- User-composed threads only (OS share + manual compose) — both funnel the URL
  through `note.actions`, so the single `/sync/notes` hook covers both.
- First note of the thread only.
- Public articles only (engine's access classifier + `md.length < 200`
  self-filter).
- Cache indefinitely — re-extract only on `extractor_version` bump (already how
  `requestExtraction` behaves). No TTL, no revalidation.

**Out of scope**

- The `AddThreadWithLink` link-row path (`/sync/links`) — the described flows
  don't use it.
- Any "couldn't fetch" / error UI — failures are silent (no note).
- ETag / Last-Modified revalidation and time-based staleness.
- Client-facing endpoint to read R2 Markdown (unnecessary — content is a note).

## Cross-cutting concerns

- **Migration:** new `extracted_url_injection` table is additive (expand
  migration); add grants; regenerate and commit `libs/db/src/types.ts`.
- **Background DB isolation:** fresh connection inside `waitUntil` / queue
  consumer, destroyed in `finally`; never the request-scoped `db`.
- **Error capture:** unexpected errors in new catch blocks call
  `tracker.captureException` (or `postHog.captureException`). Expected terminal
  extraction states (`failed`/`auth_required`/`paywalled`) and transient network
  errors are **not** captured.
- **Backwards compatibility:** additive endpoint + additive table + additive
  note inserts; no changes to existing sync contracts, so old clients are
  unaffected (they simply receive an extra synced note).
- **Docs:** add a user-facing fragment via `pnpm updates:new` (e.g. under a
  "Starting a thread" section) — "Share or paste an article link and Plot adds
  the readable article text to the thread for you."

## Testing

- **URL detection:** parsing `ExternalUserAction` URLs out of `note.actions`.
- **Scope guard:** first-note-only and user-authored-only gating (connector
  notes, non-first notes, drafts/held notes are skipped).
- **Idempotent injection:** re-pushing the same note / re-processing the same
  URL does not create a duplicate note (`key` pre-check) or duplicate injection
  row (`UNIQUE(thread_id, url_hash)`).
- **Delivery paths:** cache hit → immediate inject; cache miss → register →
  consumer drains on completion → note appears; terminal failure → no note,
  row `skipped`; race → re-check fulfills.
- **Extractor smoke tests:** keep/extend the existing MDN code-fence and
  Wikipedia footnote regression checks noted in `docs/read-later-extraction.md`.

## Key references

- `workers/api/src/extract/request.ts` — `requestExtraction` (idempotent trigger)
- `workers/api/src/queue/extract.ts` — `EXTRACT_QUEUE` consumer (`runOne`)
- `workers/api/src/extract/access.ts` — `classifyUrlAccess`
- `libs/db/schema/50-tables/30-extracted_url.sql` — global cache table
- `workers/api/src/app/sync/notes.ts:354` — `p_actions` persisted via `upsert_note`
- `apps/plot/lib/store/user_action.dart:56` — `ExternalUserAction` shape
- `apps/plot/lib/page/new_thread.dart` `_enterLinkMode` — client warm-up site
- `apps/plot/lib/widget/note_editor.dart` `_handleUrlPasteWhenEmpty` — warm-up site
- `apps/plot/lib/util/url_title.dart` `fetchUrlMetadata` — existing round-trip helper
- `workers/api/src/utils/trial.ts:166-227` — `addTrialNote` (Plot-authored note precedent)
- `workers/api/src/utils/trial.ts:20-40` — `getPlotTwistInstanceId`
- `apps/plot/lib/widget/avatar.dart` `_buildForTwist` — Plot name/logo rendering
- `docs/read-later-extraction.md` — extraction pipeline handoff notes
