# App Store Listings

Guidance and rationale for the Plot app-store listings — Apple App Store (iOS and
macOS), Google Play (Android), and Microsoft Store (Windows).

**The shipped copy for the App Store and Google Play is not in this doc.** It
lives in the fastlane metadata files (one field per `.txt`) — those files are the
source of truth. Edit the copy there, then push it with the fastlane `metadata`
lane (`fastlane ios metadata`, `fastlane macos metadata`, `fastlane android
metadata`). The automated release build uploads the binary only and skips
metadata (`skip_upload_metadata`), so copy changes ship as a deliberate, separate
step. This doc holds what those files can't: the cross-store rules, the
ASO/keyword rationale, the screenshot and imagery plan, and the **Microsoft Store
(Windows)** copy, which has no fastlane metadata and is submitted manually.

Write everything in Plot's voice (see [voice.md](./voice.md)) using the current
product terms from [features.md](./features.md).

## Where the copy lives (source of truth)

Edit App Store and Google Play copy in the fastlane metadata files below — not in
this doc. `pnpm lint:store-metadata` (run in CI) fails the build if any field
exceeds its store limit, so character counts no longer need tracking by hand.

Metadata roots (one `.txt` per field):

- **iOS** — `apps/plot/ios/fastlane/metadata/en-US/`
- **macOS** — `apps/plot/macos/fastlane/metadata/en-US/`
- **Android** — `apps/plot/android/fastlane/metadata/android/en-US/`

| Field | Limit | iOS / macOS file | Android file |
| --- | --- | --- | --- |
| App name / title | 30 | `name.txt` | `title.txt` |
| Subtitle | 30 | `subtitle.txt` | — |
| Promotional text | 170 | `promotional_text.txt` | — |
| Short description | 80 | — | `short_description.txt` |
| Keywords | 100 | `keywords.txt` | — |
| Description | 4000 | `description.txt` | `full_description.txt` |
| Release notes ("What's New") | 4000 | `release_notes.txt` | Play Console field |

**Microsoft Store (Windows)** copy lives in source files under
`apps/plot/windows/store/en-US/` (not linted), reproduced in the Microsoft Store
section below for review.

## Pushing listing changes on release (flags)

A regular `Release` run uploads the **binary only** — it does **not** touch any
store's metadata or screenshots. Listing changes ship deliberately, behind two
`workflow_dispatch` inputs that apply uniformly to every store in the run:

- **`update_metadata`** — push the text fields (title, description, features,
  keywords, …) from the source files above. Off by default.
- **`update_screenshots`** — push the screenshot set. Off by default.

They are independent: tick `update_metadata` alone to fix a description without
re-running screenshot processing; tick `update_screenshots` when the images
actually changed. `submit_for_review` still controls whether the result is
committed to certification (vs left as a draft). Mechanics per store:

- **iOS / macOS / Android** — the inputs become `SKIP_METADATA` / `SKIP_SCREENSHOTS`
  env vars consumed by the fastlane `metadata` lane (deliver/supply). Apple's
  deliver uses `sync_screenshots` (idempotent checksum-diff), so re-pushing
  unchanged shots is cheap and safe.
- **Windows** — `update_metadata` runs `msstore submission updateMetadata`;
  `update_screenshots` runs `scripts/ms-store-screenshots.sh`, which pushes the
  shots through the Submission REST API (msstore has no image command). See
  [windows-store-publishing.md](./windows-store-publishing.md).

Because pushes are now gated on an explicit flag, there's no per-release image
churn to guard against — screenshots upload only when you ask.

## How to use this doc

- The copy is tailored per store on purpose. Some repetition across stores is
  expected; don't try to share one description everywhere.
- Each platform section below keeps the **rationale** (keyword strategy, subtitle
  reasoning, compliance notes) next to a pointer to the file that holds the copy.
- **"What's New" / release notes** has a reusable template at the bottom; fill it
  per release in `release_notes.txt`. Never ship "Bug fixes and performance
  improvements."

## Rules baked into this copy (don't undo them)

- **Apple listings name no other platforms.** App Review rejects metadata that
  references Android, Windows, or other app marketplaces. The iOS and macOS copy
  below only ever mentions Apple devices (iPhone, iPad, Mac) and the web. Google
  Play and Microsoft Store copy may mention every platform, and does.
- **Third-party names live in the description, not the Apple keyword field.**
  Saying Plot "works with Gmail, Slack, and Linear" in the description is
  accurate and fine. Stuffing competitor trademarks into the 100-character
  keyword field invites a 2.3.7 rejection, so the keyword string stays generic.
- **Voice holds even under ASO pressure.** Title and subtitle lead with the real
  benefit in plain words, not a slogan. No hype words, no "boost your
  productivity," no "inbox zero." If a keyword can't earn its place in an honest
  sentence, it doesn't go in.

## Shared facts

- **App name (brand):** Plot
- **Store listing name (all platforms):** Plot: All your work, organized — bare
  "Plot" is taken, so the colon-suffix disambiguates while carrying the
  positioning. Use this exact string everywhere.
- **Primary category:** Productivity · **Secondary:** Business
- **Age rating:** 4+ / Everyone
- **Marketing URL:** https://plot.day
- **Support URL:** https://plot.day/help
- **Privacy policy:** https://plot.day/privacy
- **One-line positioning:** Plot brings your work together — team chat, email,
  meeting notes, and the comment threads inside the tools you use — and organizes
  it around the roles and goals you care about, so you can choose a focus and make
  real progress.

---

## Store imagery — shared production guide

Every platform's screenshots are produced from one synthetic data set and one
visual system, then ordered and captioned per store. This section defines the
capture setup, the conventions, and a numbered **screenshot catalog** (S1–S12)
that the per-platform sections below reference by ID — so each screen is
described once and reused.

### Source data and capture setup

All screenshots are captured from the **`libs/db/seeds/margot.yaml`** seed,
loaded at its `baseDate` of **2026-05-01** (a Friday). The persona is **Margot
Whitcombe**, owner of the fictional football club AFC Marlow
(`margot.whitcombe@afcmarlow.com`). The data is invented, so there is no real
PII to scrub — but never swap in a real account.

- Load the seed and sign in as Margot, then **freeze the app clock to 08:32 on
  the baseDate (2026-05-01)** — pin "now" there so it doesn't drift between
  shots. At 08:32 the morning's threads read as minutes-old (a fresh, active
  feed) and the agenda's "now" marker sits inside the 08:00–09:15 women's-team
  block, just ahead of the 09:15 Chelsea-tactics event. Every relative time,
  agenda day, and scheduled grouping then resolves as described below (the agenda
  day reads **Friday, May 1**; the Chelsea match is the next day, Saturday).
- Six focuses exist, each with its seeded icon: **Launch women's team** (rocket),
  **Men's team** (dumbbell), **Facilities** (building), **Commercial &
  partnerships** (handshake), **Community & supporters** (bullhorn), **Personal**
  (heart).
- **Faithful-to-seed constraints — don't stage screens this data can't make:**
  - The seed defines **no custom roles**, so the sidebar is a **flat focus
    list**. Do not mock up a Work/Personal roles-grouped sidebar from it.
  - The **FYI focus is empty** under this seed — don't feature it.
  - Sources actually present: **Slack, Gmail, Google Calendar, Notion, Google
    Sheets, Google Slides, and Plot AI.** WhatsApp is configured but has no
    seeded threads, so it won't appear in the feed — don't rely on it.

### Conventions (apply to every shot)

- **One message per screenshot.** A single benefit-driven caption in Plot's
  voice (see [voice.md](./voice.md)): a short headline (≤ ~6 words) and at most
  one line of subhead. No hype words, same rules as the copy above.
- **Consistent caption system** across each platform's set — same typeface,
  size, and placement (top third), over a calm extension of the brand gradient.
  Captions must stay legible at search-thumbnail size.
- **Clean chrome:** full signal/battery, no debug or notification banners, no
  scrollbars caught mid-drag. Set the **device status-bar clock to 8:32** to
  match the frozen app clock (not the usual 9:41 marketing time) so the device
  time and the in-app "now" agree.
- **One coherent day.** The shots should read as one real day at AFC Marlow;
  that continuity is the selling point — don't mix unrelated states.
- **Light vs dark:** lead in **light** for legibility, and use **dark**
  deliberately on the Agenda (phone) and Plot AI shots to show theme support and
  a calmer, premium feel — one to two dark shots per set.
- **Apple compliance:** third-party services (Gmail, Slack, Linear…) appear only
  as they naturally render inside Plot's UI — small source chips on rows, the
  real Connections / onboarding "Connect your tools" screen. Don't build a slide
  that's a wall of competitor logos, and keep other marketplace names out of
  captions.

### Device framing and angled spanning

- **Phone (iOS / Android):** frame each capture in a current device (iPhone 16
  Pro / Pixel), tilted slightly. The **hero is a single angled device that spans
  the first two store slots** — one composition bleeding across slots 1→2, the
  headline on slot 1 and the device body continuing into slot 2. This is the
  common phone "panorama" hero; every shot after it is one device per slot.
- **Tablet / desktop (iPad / Mac / Windows):** show the real **multi-panel**
  layout — the focus sidebar (with its **agenda squircle** sitting below the
  focus list) + the thread list + the open thread — full-bleed or in a subtle
  frame, flat, not angled. Because that squircle keeps the agenda on screen in
  every multi-panel shot, these sets don't get a dedicated agenda screenshot.

### Screenshot catalog

Each entry names the exact screen, the seeded state to set up, any interaction,
and the default light/dark mode. Per-platform sections may override the mode and
add framing.

| ID | Screen (route) | Seeded state & interaction | Default mode |
| --- | --- | --- | --- |
| **S1** | Focus feed — *Launch women's team* (Focus tab → `PriorityRoute`) | List scrolled to top so the focus title (rocket) and **Active** header show; Active leads with the pinned **"Women's team proposal — vision and viability"** (goal star + Notion / Sheets / Gmail source chips), then the to-dos *Marlow Trust pre-brief*, *Coaching candidate criteria*, *Founding-partner shortlist*, *Board deck*. **Single-panel (phone):** the thread list only, no thread open. **Multi-panel (tablet/desktop):** that same list in the middle panel, agenda squircle below the sidebar focus list, and the **right panel open on the "Founding-season scarf design" thread** (Posy's scarf-concept image note and its reactions). No interaction. | Light |
| **S2** | Thread + reply — *Chelsea (A) — coaching staff plan* (`ThreadRoute`, Men's team, Slack #coaching-staff) | Scrolled to the tail of the Wes / Eli / Murph / Margot exchange. **Interaction: a reply half-typed in the composer, caret active** — e.g. *"Great work, all. Let's go high press from the first whistle"*. | Light |
| **S3** | Agenda — **phone only** (Agenda tab → `AgendaRoute`) | Date header **Friday, May 1**, the "now" marker at 08:32. Events: Chelsea match tactics 09:15, **Women's team board strategy w/ Embry** 11:15 (pinned), Avenir sponsorship lunch 12:30, FA Women's Championship call 14:00, Sky Sports interview 15:00, Evening walk 18:00, Match-day prep review 19:00 — interleaved with the focus time-blocks. No interaction. (Desktop/tablet surface the agenda via the sidebar squircle instead, so they skip this shot.) | Dark |
| **S4** | Focus list / sidebar (Focus tab root on mobile, left sidebar on desktop) | Inbox, FYI, Everything, then the six focuses with their icons and unread dots. No interaction. | Light |
| **S5** | Start a thread (New tab → `NewThreadRoute`) | People-first picker: recent people (Posy, Wes, Eli, Maurice), groups (Coaching staff, Board, Women's team taskforce), and **Plot AI chat**. **Interaction: typing "Po"** → filtered to **Posy Mercer** with reach options shown. | Light |
| **S6** | Search (Search tab → `SearchRoute`) | **Interaction: typing "Chelsea"** → cross-source results spanning Slack, Notion, Sheets, and Calendar (match tactics, travel roster, formation notes, perflab pack, fixture). | Light |
| **S7** | Plot AI — *Revenue model assumptions* (`ThreadRoute`, Women's team, Plot AI chat) | Scrolled to the **@plot** stress-test exchange — the question and Plot AI's three-scenario answer rendered in full. No interaction. | Dark |
| **S8** | Onboarding **"Connect your tools"** step (`OnboardingBloc` driven to that step; full-screen overlay) | Sectioned Messaging / Calendars / Apps connector grid — Gmail, Google Calendar, Google Chat, Slack, Microsoft Teams, Linear, Notion, PostHog, Apple Calendar tiles — plus the user's existing connections under **Your connections**. No interaction. | Light |
| **S9** | Reactions & status (optional) — *Founding-season scarf design* (`ThreadRoute`, Women's team, Slack) | Emoji reaction chips on Posy's image note; or, alternatively, an event/Linear thread showing the single status icon in the header. No interaction. | Light |
| **S11** | Command bar (desktop only) | Multi-panel with the **⌘K command palette open** over it (jump-to-focus / quick actions). No interaction beyond the open palette. | Light |
| **S12** | Share sheet (Android only) | The OS share sheet sending a link from another app into **Plot**, landing on `NewThreadRoute` with the focus picker. | Light |

### Optional motion

- **iOS App Preview** and **Google Play promo video** (optional, 15–30s): walk
  the same narrative — S1 hero → reply (S2) → agenda (S3) → start a
  thread (S5). First frame = the S1 hero so the poster matches slot 1.

---

## Apple App Store — iOS

### Name — 30 char max

**Source:** `apps/plot/ios/fastlane/metadata/en-US/name.txt` — the shared listing
name ("Plot: All your work, organized"); see Shared facts.

### Subtitle — 30 char max

**Source:** `apps/plot/ios/fastlane/metadata/en-US/subtitle.txt`

Leads with "Team chat" (not email), and deliberately does not repeat "organized"
from
the name. Apple indexes the name and subtitle as separate keyword fields, so this
line spends its characters on fresh terms (team, chat, email, app, threads) — the
channels from the site tagline.

### Promotional Text — 170 char max (editable any time, no review)

**Source:** `apps/plot/ios/fastlane/metadata/en-US/promotional_text.txt` — swap
this per launch to highlight what's new; it updates without an App Review pass.

### Keywords — 100 char max, comma-separated, no spaces

**Source:** `apps/plot/ios/fastlane/metadata/en-US/keywords.txt`

Words already in the name (all, your, work, organized) and subtitle (team, chat,
email, app, threads) are omitted on purpose; Apple indexes those separately. "tasks" is
included because it's no longer in the name or subtitle, and it's a core search
term for Plot. Integration names (Slack, Gmail, Linear, Notion) are kept out of
this field to avoid a trademark rejection — they appear in the description instead.

### Description — 4000 char max

**Source:** `apps/plot/ios/fastlane/metadata/en-US/description.txt`

### What's New — 4000 char max

**Source:** `apps/plot/ios/fastlane/metadata/en-US/release_notes.txt` — fill per
release using the **Release notes** template at the bottom of this doc.

### Screenshots — iPhone

Up to 10 per device size. Provide the **6.9" iPhone** set (1290×2796, portrait);
Apple scales it down to 6.5". The **first three** appear in search results, so
the spanning hero (slots 1–2) plus the reply shot (slot 3) must carry the
story on their own. Conventions and catalog IDs are defined in **Store imagery**
above.

| Slot | Catalog | Mode | Caption | Framing |
| --- | --- | --- | --- | --- |
| 1–2 | **S1** | Light | **All your work, ready for action** · *Team chat, email, and app threads in one place* | Angled device spanning slots 1→2 (panorama hero) |
| 3 | **S2** | Light | **Reply to anything without opening another app** | typing a reply |
| 4 | **S3** | Dark | **Your day in context** | |
| 5 | **S5** | Light | **Start anything from one place** | typing "Po" |
| 6 | **S7** | Dark | **AI right alongside your work** · *Use it your way, or turn it off* | |
| 7 | **S6** | Light | **Find anything, wherever it lives** | typing "Chelsea" |
| 8 | **S4** | Light | **Organized by focus** | |

### Screenshots — iPad

Provide the **13" iPad** set (2048×2732 portrait or 2732×2048 landscape); up to
10. Use the landscape **multi-panel** layout (flat, not angled).

| Slot | Catalog | Mode | Caption |
| --- | --- | --- | --- |
| 1 | **S1** (sidebar + women's-team list + scarf-design thread open) | Light | **All your work, ready for action** |
| 2 | **S2** (composer active in the right panel) | Light | **Reply to anything without opening another app** |
| 3 | **S7** | Dark | **AI alongside your work — or off entirely** |
| 4 | **S5** (picker over the multi-panel, typing) | Light | **Start anything from one place** |
| 5 | **S8** | Light | **Works with the tools you already use** |

---

## Apple App Store — macOS

Same name, subtitle, promotional text, and keywords as iOS — see those files
under `apps/plot/macos/fastlane/metadata/en-US/`. The description leans into the
Mac experience (native notifications, command bar) instead of naming iPhone/iPad.

### Name — 30 char max

**Source:** `apps/plot/macos/fastlane/metadata/en-US/name.txt`

### Subtitle — 30 char max

**Source:** `apps/plot/macos/fastlane/metadata/en-US/subtitle.txt`

### Description — 4000 char max

**Source:** `apps/plot/macos/fastlane/metadata/en-US/description.txt` — mirrors
iOS but swaps the iPhone/iPad framing for a **MADE FOR YOUR MAC** section.

### Screenshots — macOS

Landscape, up to 10. Accepted sizes: 1280×800, 1440×900, 2560×1600, or **2880×1800**
(prefer the largest). Capture the real **multi-panel** desktop with the native
title bar — and spend one slot on the Mac-specific command bar.

| Slot | Catalog | Mode | Caption |
| --- | --- | --- | --- |
| 1 | **S1** (sidebar + list + scarf-design thread open) | Light | **All your work, ready for action** |
| 2 | **S2** (composer active) | Light | **Reply to anything without opening another app** |
| 3 | **S11** (⌘K command bar open) | Light | **Drive it from the keyboard** |
| 4 | **S7** | Dark | **AI alongside your work — or off entirely** |
| 5 | **S8** | Light | **Works with the tools you already use** |

---

## Google Play — Android

### Title — 30 char max

**Source:** `apps/plot/android/fastlane/metadata/android/en-US/title.txt`

### Short description — 80 char max

**Source:** `apps/plot/android/fastlane/metadata/android/en-US/short_description.txt`

Keeps the site tagline's exact tail ("organized around your priorities");
compresses "the comment threads inside apps" → "app threads" and drops "meeting"
to fit 80. Leads with "Team chat," not email.

### Full description — 4000 char max

**Source:** `apps/plot/android/fastlane/metadata/android/en-US/full_description.txt`

Google Play ranks on the full description, so the keywords are woven into honest
sentences rather than a separate field, and cross-platform availability is named
in full. Section headers use `<b>…</b>` (Play renders limited HTML).

### Tags / categories

- **Category:** Productivity
- **Tags:** email, calendar, to-do list, team collaboration, notes (choose from
  Play's controlled tag list — these map to Plot's value props)

### Feature graphic — 1024×500 (required)

Google Play **requires** this and shows it at the top of the listing and across
promotional surfaces, so it carries more weight than any single screenshot. Keep
it brand-led, not a screenshot dump: the Plot wordmark and the headline **"All
your work, ready for action"** over the brand gradient, with a sliver of the angled S1
hero device on one side. No store badges, no competitor logos. 24-bit PNG or JPEG,
no alpha.

### Screenshots — phone

Google Play accepts **2–8** phone screenshots (9:16; 1080×1920 or larger, each
side 320–3840px; 24-bit PNG/JPEG). The first 2–3 carry the listing. Android adds
the **share-sheet** shot — sharing into Plot is a real platform-native value here.

| Slot | Catalog | Mode | Caption | Framing |
| --- | --- | --- | --- | --- |
| 1–2 | **S1** | Light | **All your work, ready for action** · *Team chat, email, and app threads in one place* | Angled device spanning slots 1→2 (panorama hero) |
| 3 | **S2** | Light | **Reply to anything without opening another app** | typing a reply |
| 4 | **S3** | Dark | **Your day in context** | |
| 5 | **S5** | Light | **Start anything from one place** | typing "Po" |
| 6 | **S12** | Light | **Share into Plot from any app** | Android share sheet → New Thread |
| 7 | **S6** | Light | **Find anything, wherever it lives** | typing "Chelsea" |

### Screenshots — tablet (7" and 10", recommended)

Up to 8, landscape **multi-panel**. Recommended for Play's large-screen quality
signals and the tablet listing. Reuse the iPad framing and captions.

| Slot | Catalog | Mode | Caption |
| --- | --- | --- | --- |
| 1 | **S1** (sidebar + list + scarf-design thread open) | Light | **All your work, ready for action** |
| 2 | **S2** (composer active) | Light | **Reply to anything without opening another app** |
| 3 | **S7** | Dark | **AI alongside your work — or off entirely** |
| 4 | **S8** | Light | **Works with the tools you already use** |

---

## Microsoft Store — Windows

The Windows listing **text** is now pushed by the `release-windows` workflow
from dedicated source files under `apps/plot/windows/store/en-US/` (mirroring the
fastlane convention the other platforms use). Edit the copy in those files; the
blocks below are reproduced for review only. **Screenshots, release notes, and
the product name are still submitted by hand** via Partner Center — the msstore
`updateMetadata` path cannot upload images, and notes/name are out of scope. The
`lint:store-metadata` check does not cover these files.

### Product name

```
Plot: All your work, organized
```

### Short description / summary — Windows has no subtitle field, so use the full site tagline verbatim

**Source:** `apps/plot/windows/store/en-US/short_description.txt`

```
Team chat, email, meeting notes, and threads from your apps, organized around your priorities.
```

(94) — The Microsoft Store has no subtitle field, so the site's full tagline
fits here verbatim with no trim.

### Description — 10,000 char max

**Source:** `apps/plot/windows/store/en-US/description.txt`

```
Your most important work isn't the newest email or the loudest notification. It's scattered across a dozen apps, mixed in with everything else competing for your attention. Plot brings it together, organized around the roles and goals you care about, so you can choose a focus and make real progress.

Reply, react, assign, and finish work in one place — across team chat, email, meeting notes, and the comment threads inside the tools you already use — without opening five apps full of distractions.

Plot also protects your attention. Low-signal mail — newsletters, receipts, promotions — waits in a muted FYI focus instead of pinging you, and you decide when notifications are allowed. Genuinely urgent threads still break through; the rest of your day stays yours.

WHAT YOU CAN DO
• Bring team chat, email, meeting notes, and app comments into one organized list
• Reply, react, comment, and change status without leaving Plot
• Mark anything To do, schedule it for later, or finish it — so nothing gets dropped
• Group your work under roles and focuses, so the right things get your best attention
• Let low-signal mail — newsletters, receipts, promotions — wait in a muted FYI focus instead of pinging you
• Set when interruptions are allowed; genuinely urgent threads still break through
• See your whole day — calendar events and scheduled work — on one agenda
• Search across everything, wherever it came from
• Use AI right alongside your work, as much or as little as you like — or turn it off entirely

MADE FOR WINDOWS
Native desktop notifications that quiet down when the app is in front of you and respect your Focus assist settings. A keyboard-driven command bar for getting around fast. Light, dark, or system — it follows Windows.

WORKS WITH YOUR TOOLS
Connect Gmail, Google Calendar, Google Chat, Outlook Calendar, Microsoft Teams, Slack, Linear, Notion, PostHog, and Apple Calendar. WhatsApp, Instagram, and LinkedIn messaging are available too. Read and reply in one place; jump to the source whenever you need it.

WORKS OFFLINE, ON EVERY DEVICE
Read, write, organize, and finish work with no connection — everything syncs the moment you're back online. Plot runs on Windows, Mac, iPhone, iPad, Android, and the web, with a consistent experience and platform-native touches.

WORK YOUR WAY
Use AI as much or as little as you want — bring your own key, point it at your own model, or turn it off entirely. Your data stays yours: you connect each account securely without handing Plot your passwords, your data is encrypted in transit, and only you and the people you share with can see it.

Plot has a free plan. Get back to your best work.
```

### Product features — up to 20, 200 char max each

**Source:** `apps/plot/windows/store/en-US/features.txt` (one feature per line)

```
Team chat, email, and app comment threads in one organized place
Reply, react, and change status without leaving Plot
Mark anything To do, schedule it for later, or finish it
Group your work under roles and focuses so the right things get your attention
Low-signal mail waits in a muted FYI focus instead of interrupting you
Notifications on your schedule, with genuinely urgent threads breaking through
One agenda for your calendar events and scheduled work
Search across every connection, focus, and thread
Use AI alongside your work, as much or as little as you like — or turn it off
Works offline and syncs across all your devices
```

### Search terms — up to 7, 30 char max each

**Source:** `apps/plot/windows/store/en-US/search_terms.txt` (one term per line)

```
email client
team chat
task manager
calendar
productivity
collaboration
inbox
```

### Screenshots

At least 1, up to 10; **≥ 1366×768**, PNG, landscape. Capture the real
**multi-panel** desktop, including the Windows-specific command bar.

| Slot | Catalog | Mode | Caption |
| --- | --- | --- | --- |
| 1 | **S1** (sidebar + list + scarf-design thread open) | Light | **All your work, ready for action** |
| 2 | **S2** (composer active) | Light | **Reply to anything without opening another app** |
| 3 | **S11** (Ctrl+K command bar open) | Light | **Drive it from the keyboard** |
| 4 | **S7** | Dark | **AI alongside your work — or off entirely** |
| 5 | **S8** | Light | **Works with the tools you already use** |

---

## Release notes ("What's New") — reusable template

The shipped notes live in each platform's `release_notes.txt` (Apple) and the
Play Console release field; this is the template to fill them from. Specific and
human. Name what changed and why it helps. Never "Bug fixes and performance
improvements." Group several items as short lines. Keep platform mentions out of
the Apple version.

**Template**

```
What's new in this version:

• <Plain-language description of the change and what it does for you>
• <Another change>

Fixes and small improvements:
• <Specific fix a user would notice>
```

**Filled example (works for any store)**

```
What's new in this version:

• Roles: group your focuses under Work, Personal, and more — each with its own colors and notifications, so work and life stay on separate tracks.
• A new FYI focus gathers low-signal mail — newsletters, receipts, promotions — in one muted place to skim on your own schedule, and keeps it out of your Inbox.

Fixes and small improvements:
• Opening a thread no longer bumps it to the top of your Done list.
• Faster focus switching and a calmer agenda when you move between focuses.
```
