# Margot seed data for the new layout — design

**Date:** 2026-06-09
**Scope:** Rewrite `libs/db/seeds/margot.yaml` and extend `libs/db/seeds/generate-seed.ts`
so the seed produces screenshot-quality data for the *current* product shape:
flat focuses, a sectioned activity feed, and a NewThreadPage populated with
contacts, groups, and channels.

## Problem

`margot.yaml` was authored for the *old* model and no longer demonstrates the
product well:

- **Deeply nested priorities** (`AFC Marlow › Men's team › Match preparation`).
  The product now treats focuses as a **flat** list under `Everything`.
- **Agenda-oriented** content: ~60 threads across ~2100 lines, much of it
  gap-pinned to-dos and event-associated supporting threads built to fill a
  dense day-planner agenda. The product now leads with a **sectioned activity
  feed** (active / scheduled / done).
- **No NewThreadPage data.** The new "Start a thread" page surfaces People,
  Groups, and Channels. The seed has contacts but **no groups** and **no
  connection channels**, so two of the three sections render empty.

The generator (`generate-seed.ts`) likewise has no concept of focus icons,
groups, or channels.

## Goals

1. ~5–6 **flat** focuses, each with a curated icon + theme colour; related
   focuses share a colour.
2. Two focuses **fully built** (~30 threads each, mostly Done) so their feeds
   demonstrate a long, scrollable "infinite list". The other focuses are
   **sidebar-only** but still contribute events to the shared agenda.
3. A **sectioned activity feed** per complete focus: ~5 active, several
   scheduled, the rest done; 2–3 threads carry full note trees (the scarf
   thread is one).
4. A realistic **agenda** spanning a few days around `baseDate`.
5. **NewThreadPage** data: synthetic **groups** and enabled Slack **channels**
   so People / Groups / Channels all render.
6. Reproducible: same YAML + `baseDate` → identical SQL (unchanged guarantee).

## Non-goals

- No change to the persona's voice, world, or the `margot.md` narrative.
- No production seeding workflow changes (`apply-seed:prod` etc. unchanged).
- No new UI; this is data + generator only.

---

## Design

### 1. Flat focuses

Replace the nested tree with six flat children under `Everything`. Each gets a
`priority.icon` (a key from the app's `kFocusIcons` map in
`apps/plot/lib/widget/icon.dart`) and a `color` (theme index 0–7). Related
focuses share a colour.

| ref | Title | icon | color | Role | Built out? |
|---|---|---|---|---|---|
| `womens_team` | Launch women's team | `rocket` | 2 (green) | Headline initiative | **Full (~30 threads)** |
| `commercial` | Commercial & partnerships | `handshake` | 2 (green) | Sponsors, founding partners | Sidebar (few events) |
| `mens_team` | Men's team | `dumbbell` | 1 (blue) | Squad, match prep, Chelsea away | **Full (~30 threads)** |
| `facilities` | Facilities | `building` | 1 (blue) | Training ground, stadium | Sidebar (few events) |
| `community` | Community & supporters | `bullhorn` | 6 (orange) | Fans, media, schools | Sidebar (few events) |
| `personal` | Personal | `heart` | 4 (purple) | Pen, walks, journal | Sidebar (few events) |

Colour families: green = women's team + commercial (forward/growth);
blue = men's team + facilities (club operations); orange and purple stand alone.

All existing threads are **rehomed** from the old sub-priorities onto these six
flat refs. The deep sub-priorities (`coaching_staff`, `player_performance`,
`board_process`, `business_case`, `media_pr`, …) are removed; their threads move
to the nearest flat focus (e.g. everything board/finance/FA-related →
`womens_team`; everything tactics/training/match → `mens_team`).

`shared_with` stays on focuses (it already drives `priority_contact` /
`shared_with`), so the sidebar focuses still look collaborative.

### 2. The two complete focuses (~30 threads each)

Each complete focus carries ~30 threads partitioned to read well in the
sectioned feed:

- **~5 active** — `todo`/`now` (no future event, no `done_at`). These head the
  feed.
- **~6–8 scheduled** — events with a future `at` (today→+2d). Several land in
  the agenda too.
- **~17–19 done** — `done_at` in the past. This is the long tail that makes the
  feed scroll like a real inbox.

**Launch women's team** content (rehomed + extended): women's-team proposal
(full vision doc), revenue model (ChatGPT exchange), board talking points
(Claude exchange), Embry board strategy, FA Championship call + checklist,
founding-season scarf (Posy DM + image attachment), Marlow Trust pre-brief,
coaching-candidate criteria, founding-partner shortlist, financial model
benchmarking, plus ~18 done items (research notes, sentiment summaries,
historical board soundings, etc.).

**Men's team** content (rehomed + extended): Chelsea tactics, Wes formation
notes, Eli positioning, match-day travel logistics, training reports, perflab
match preview/post-match analysis, match-day prep review, the Chelsea fixture
itself, plus ~18 done items (prior match reviews, training updates, set-piece
indexes, etc.).

**Fully-noted threads (2–3, story-rich):**
1. **Founding-season scarf** — Posy DM thread + `image/jpeg` file action
   (kept verbatim from current seed; rehomed to `womens_team`).
2. **Women's Team Proposal** — the long vision doc + the Plot-AI Q&A exchange.
3. **Board talking points** — the Claude exchange.

Every other thread still gets: a connection logo (Slack / Gmail / Notion /
Sheets / GCal / WhatsApp link), an author and/or contact, a title, and a
one-line preview placeholder note — just not a deep tree.

### 3. Sidebar-only focuses

`commercial`, `facilities`, `community`, `personal` each get **2–4 threads**,
biased toward scheduled events (Avenir lunch, sponsorship huddle, evening walk,
ops meeting, board dinner, schools partnership) so the **shared agenda** stays
full. Their feeds are intentionally light — they exist to make the sidebar and
agenda realistic, not to be screenshotted.

### 4. Agenda

Keep `baseDate: "2026-05-01"`. Events span **−1d → +2d**, densest on base date:
morning focus block (8:00), Embry board strategy (11:15), FA call (14:00),
Avenir lunch (12:30), Sky interview (15:00), evening walk (18:00); the
Chelsea-away fixture and travel land on **+1d**. Events are pulled from all six
focuses so the timeline reads full regardless of which focus is selected.

### 5. NewThreadPage data

**Groups** (new `groups:` section) — reusable contact sets:

| ref | name | privacy | members |
|---|---|---|---|
| `coaching_staff_grp` | Coaching staff | open | wes, murph, eli |
| `board_grp` | Board | private | maurice, + 2 new contacts |
| `womens_taskforce_grp` | Women's team taskforce | open | posy, maurice |

The seed user (Margot) is admin of each (drives `group_admin` → `user.group`
`is_admin`/`can_post`). A couple of new contacts (e.g. two extra board members)
are added so `Board` has a believable roster.

**Channels** (new per-source `channels:` on the Slack source) — enabled
`channel` rows on the Slack connection's `twist_instance`:

| channel_id | title |
|---|---|
| `C04general` | #general |
| `C04coaching` | #coaching-staff |
| `C04womens` | #womens-team-launch |
| `C04fans` | #fan-engagement |

Each channel row carries a `link_types` JSON array containing **one
compose-capable link type** modeled on the real Slack connector
(`public/connectors/slack/src/slack.ts`):

```json
[{
  "type": "thread",
  "label": "Thread",
  "noteLabel": "Message",
  "sharingModel": "channel",
  "logo": "https://api.iconify.design/logos/slack-icon.svg",
  "compose": { "targets": "channels" }
}]
```

The `compose` block is load-bearing: NewThreadPage's Channels section
(`connection_targets.dart`) only surfaces a channel whose `link_types` declares
`compose`. Without it the channels sync but never appear as compose targets.

People come for free from contacts + MRU (no generator change).

### 6. Dropped old-agenda scaffolding

The current seed leans on two mechanisms built specifically for the old
gap-filling day-planner agenda: `priority_blocks` (per-gap priority ordering)
and a large set of `schedule.todo: true` items pinned to gap start times. These
are **dropped from the YAML** (the `priority_blocks` generator feature stays in
place, just unused) because the sectioned feed orders by section/recency, not by
agenda gaps. To-dos become ordinary active threads.

---

## Generator changes (`generate-seed.ts` + `types.ts` + `spec.md`)

1. **Focus icon** — add `icon?: string` to the `Priority` type and write it into
   the `priority.icon` column. Validate against the `kFocusIcons` key set
   (mirror the list as a constant; warn, don't hard-fail, on unknown keys so the
   list can drift). `color` already supported.

2. **`groups:` top-level section** — new `SeedGroup` type
   (`ref`, `name`, `privacy?`, `members: string[]` of contact refs, optional
   `admins`). Emit:
   - `group` (id `uuidv7`-style deterministic UUID, `created_by` = user,
     `privacy`, `name`).
   - `group_member` per member contact.
   - `group_admin` for the user (and any listed admins).
   Validate member refs resolve to contacts. Respect the
   "bump parent seq on child write" rule implicitly — these are static inserts,
   so a single `group.seq`/`updated_at` at insert time is fine.

3. **`channels:` on a source** — new optional `channels: SeedChannel[]` on
   `SeedSource` (`channel_id`, `title`, `enabled?` default true, optional
   `link_types` override). Emit `channel` rows bound to that source's
   `twist_instance`, defaulting `link_types` to the Slack-style compose JSON
   above. Validate the parent source exists.

4. **Docs/types** — update `types.ts`, `spec.md`, and `README.md` with the new
   `icon`, `groups`, and `channels` shapes and a short NewThreadPage note.

The SQL stays additive and deterministic; no schema migration is required (all
target tables — `priority.icon`, `group`, `group_member`, `group_admin`,
`channel` — already exist).

## Validation / done criteria

- `pnpm gen-seed libs/db/seeds/margot.yaml` produces SQL with no validation
  errors.
- `pnpm gen-seed --apply libs/db/seeds/margot.yaml` applies cleanly to a local
  DB.
- Running the app against the seeded user (manual / `run-app`) shows:
  - Sidebar: 6 flat focuses with distinct icons and the two colour pairs.
  - Selecting **Launch women's team** or **Men's team**: a sectioned feed
    (active / scheduled / done) long enough to scroll; the scarf thread renders
    its image; the proposal/board threads render full note trees.
  - Agenda: events across −1d→+2d.
  - NewThreadPage: People, Groups (3), and Channels (4 Slack channels) all
    populated.
- Same YAML + baseDate regenerates byte-identical SQL (reproducibility).

## Risks / open questions

- **Channel compose gating** — if NewThreadPage requires more than enabled
  `channel` rows with a `compose` block (e.g. a connector-capability flag on the
  Slack `twist`), the Channels section may still not render. Confirm during
  implementation by running the app; fall back to inspecting
  `compose_targets.dart` / `connection_targets.dart` for any additional gate.
- **Thread count vs clutter** — ~30 threads/focus is a lot of YAML. Mitigate by
  keeping done-tail threads terse (title + one preview note + one link), so the
  bulk is cheap to author and read.
- **Focus icon key drift** — `kFocusIcons` may change; the generator validates
  softly (warn) so a future icon rename doesn't break seeding.
