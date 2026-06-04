# New-thread target picker: two-line rows, focus colour, multi-recipient email

**Date:** 2026-06-03
**Status:** Draft for review
**Area:** `apps/plot` step-1 target picker (`lib/widget/compose/target_picker_list.dart`,
`lib/state/compose_targets.dart`, `lib/widget/compose/compose_target.dart`,
`lib/widget/compose/email_parser.dart`, `lib/page/new_thread.dart`) plus a small
server change in `workers/api/src/app/sync/threads.ts`.

---

## 1. Goal

Reformat the step-1 "new thread" target rows from a single line
(`[logo] Label · detail`) into a richer two-line row, and along the way:

1. Reframe Plot-native items (drop the Note/Chat distinction).
2. Tint each row's connection header by the most-common focus for that
   connection (cached so it never slows opening or search).
3. Render people with an `AvatarGroup` + names, and channels with the channel
   name.
4. Accept multiple recipients in one query (separated by spaces, commas, or
   semicolons) and the `Name <email>` form, creating **named** contacts.
5. Surface email addresses only when needed to disambiguate identically-named
   people, with the full list always available on hover.

### Confirmed decisions (from brainstorming)

- **Drop Note vs Chat.** A Plot item is one of: a roster of contacts/groups
  (a shared thread), a twist, or a **focus** (a plain note filed to that focus).
- **All headers** get the muted focus tint; fall back to neutral (`ThemeColor`
  index 7) when there's no history.
- **Named contacts:** `Name <email>` flows through to submit and creates a
  contact actually named "Name".
- **Exception-only inline emails:** show just the name normally; append the
  email only when a display name maps to >1 address within a connection, and
  only on the non-primary (less-used) entry. Hover always shows every name +
  full email.
- **Focus-note rows:** header is the same as a Plot chat (`Plot`, plus team
  scope when the user belongs to ≥1 team); the second line uses the **focus
  icon** (not the Plot logo) and shows the focus name, both painted in the
  focus's colour. Searching a focus surfaces the focus's most-common Plot scope
  first, with other scopes after.
- **Twist rows:** the twist name is its own header (tinted by the twist's
  most-common focus); the second line shows the twist logo + twist name.

---

## 2. Row anatomy

Every row is two lines. Line 1 is a small muted header in the focus tint (style
copied from the ThreadWidget channel header: `typography.xs`, `height: 1`,
`mutedForeground` base colour, `ellipsis`). Line 2 is the content: a 16px
leading glyph (connector logo, Plot logo, focus icon, or twist logo) followed by
either an `AvatarGroup` + names, a channel name, or a focus name.

```
Gmail · kris@plot.day                 ← header, focus-tinted
 [G]  (◔◔)  Greg Smith, Dana Lee +2   ← logo + avatars + names   (DM/people)

Slack · Acme Workspace
 [S]  #general                        ← logo + channel name       (channel)

Plot · Personal
 [P]  (◔)  Kris Braun                  ← Plot logo + avatars + names (Plot chat)

Plot · Personal
 (•)  Marketing                       ← focus icon + name, focus-coloured (note)

Plot AI
 [AI] Plot AI                         ← twist logo + twist name    (twist)
```

| Kind | Header (line 1) | Line 2 |
| --- | --- | --- |
| Connector — channel | `{Connector} · {account}` | connector logo + channel name |
| Connector — DM/contacts/addresses | `{Connector} · {account}` | connector logo + AvatarGroup + names |
| Plot chat (roster) | `Plot` (`· {scope}` w/ teams) | Plot logo + AvatarGroup + names |
| Plot focus-note | `Plot` (`· {scope}` w/ teams) | focus icon + focus name, in focus colour |
| Twist | `{Twist name}` | twist logo + twist name |
| Add a connection | (unchanged single-line synthetic row) | `+ Add a connection…` |

Notes:

- **Account in the connector header:** keep today's rule — show `· {accountLabel}`
  only when the connector has >1 connection of that type; a single-connection
  connector shows just `{Connector}`.
- **Focus-note tint:** because the focus is explicit, the header *and* the
  content share that focus's colour. For all other rows the header tint is the
  most-common focus for that connection (§4).
- **AvatarGroup** uses the existing widget (`maxVisible: 3`, overflow "+N",
  built-in name tooltip). We add a row-level tooltip carrying names + emails
  (§7), so the names line itself is hoverable.
- **Row height:** two lines exceed the current `estimatedItemHeight = 50.0`.
  Bump the estimate (≈ 60) in both the constant used by `_scrollToIndex` and the
  `ListViewSelector(estimatedItemHeight:)` arg, and re-check the scroll math.
  The synthetic "Add a connection…" row stays single-line.

---

## 3. Plot-native model change (drop Note vs Chat)

`_materializeBaseList()` today emits a generic `Note` and `Chat` per team scope,
plus one connector template per create-target, plus recently-used combos. New
composition:

- **Remove** the generic per-scope `Note`/`Chat` template rows.
- **Focus-note targets:** for each focus appearing in the cached authored-thread
  scan (MRU order, deduped), emit one focus-note target. Its scope is that
  focus's **most-common** Plot team/personal in the scan; additional scope
  variants rank after. `ComposeTarget` gains an optional `priorityId` so the
  target carries its focus into step 2 (§6).
- **People combos** (rostered Plot chats and connector DM combos) continue to
  come from the used-combos pass — unchanged sourcing, new rendering.
- **Twist targets:** *net-new in step 1* (twists are not surfaced today) —
  **included** in this change. Load chat-capable `TwistInstance`s (the same
  instances the step-2 Connection field resolves via `TwistConnectionChoice`)
  and emit a `ComposeTarget.twist` for each.
- **Starting an empty shared thread:** with bare Note/Chat gone (intentional),
  the entry points are: pick a focus-note (then add people in step 2) or type a
  person/email (synthesises a people target).

`ComposeTargetKind` keeps `note`/`chat`/`connector`/`twist` internally
(`note` = focus-note, `chat` = roster), so signatures and the step-2
`toConnectionChoice()` bridge stay intact.

---

## 4. Focus-colour tally and caching (must not slow open/search)

There is **no synchronous `Priority` cache**, and `displayColor` needs a loaded
`Priority`. We avoid per-open / per-keystroke cost by computing colours **once**
during the search-context build (already cached in `_ComposeSearchContext`,
rebuilt only on `refresh()` / cache-invalidation):

1. Every scanned `ThreadRow` already carries a non-nullable `priorityId`. Extend
   `ComposeScanThread` with `priorityId` (it's read from the same row in
   `_scanAuthoredThreads`).
2. During context build, tally, per **connection-grouping key**, the
   most-common `priorityId`:
   - connector → twist-instance id
   - twist → twist-instance id
   - Plot chat → `plot:{scope}` (Personal and each team are **separate** keys,
     so a work team's dominant colour stays distinct from personal threads)
   The winner per key is one `priorityId`.
3. Collect the **distinct** winning `priorityId`s (a handful) plus the distinct
   focus-note `priorityId`s, and resolve them in **one** `Priority.get(...)`
   call. Build a `Map<priorityId, ThemeColor>` (via `displayColor`) and a
   `Map<connectionKey, ThemeColor>`, cached on the context.
4. At render time the header colour is a synchronous map lookup →
   `context.colour.colours.fromTheme(themeColor, muted: true)`; missing →
   `fromTheme(const ThemeColor.defaultColor(), muted: true)` (neutral 7).
5. Focus-note rows look up their own focus's colour (same map).

Cost: one extra bounded `Priority.get` per context build (i.e. per `refresh()`),
reused across every keystroke. No new work on open or per-search.

We also batch-load the distinct **roster contact ids** from the scan via one
`Actor.get(...)` during context build so `Actor.fromCache` hits at render time
(needed for avatars + names). One bounded query, cached.

---

## 5. Multi-recipient email parsing + named contacts

### Parser (`EmailParser`)

Replace the single-address matcher with a multi-recipient parser:

- `parseRecipients(String) -> List<ParsedRecipient>` where
  `ParsedRecipient { String email; String? name; }`.
- Algorithm: split top-level on `,` and `;` into segments; for each segment,
  match `^(.*?)<([^>]+)>$` → `name` (trim/unquote) + `email`; else split the
  segment on whitespace and treat each token as a bare email. Validate each
  email with the existing lenient pattern. Drop non-email junk.
- `isEmailQuery(String)` (or callers check `parseRecipients(...).isNotEmpty`) →
  email mode when ≥1 valid email parsed; otherwise fall through to name search.

### Search synthesis (`_searchByEmail` → multi-recipient)

`search()` routes an email-mode query to a generalised `_searchByRecipients`:

- Resolve each parsed email against known contacts (`Actor.get(search:)`,
  exact-email match). Resolved → roster contact id; unresolved → a pending
  **named** invite.
- Emit one Plot chat target per scope (Personal + each team) carrying **all**
  resolved contacts as `contacts` and all unresolved as named invites in
  `inviteEmails`; pin chats above address-capable connector targets, which also
  carry the full multi-recipient roster.
- `contactDetail`/label generalise to a multi-recipient summary
  ("Greg Smith, Dana Lee +1").

### Named-invite encoding (no migration, no wire change)

`inviteEmails` stays `List<String>` (Drift `text().nullable()` column + sync
`invite_emails: string[]`). Encode a named invite as the RFC-style
`"Name <email>"`; a nameless invite stays bare `"email"`. Add helpers:

- `InviteAddress.format(name, email)` / `InviteAddress.parse(str) -> {name?, email}`.
- `ContactChipEmail` parses for display: label = name (fallback email); hover
  shows the email.
- Picker rows parse for display likewise.

### Server (`workers/api/src/app/sync/threads.ts`)

`upsert_contacts` **already** stores `name` (`COALESCE(EXCLUDED.name, …)`); only
the call site drops it. Change line ~781 to parse each `inviteEmails` entry with
the same `Name <email>` rule and pass `{ email, name }` (name omitted when
absent). No schema change.

**Backwards compatibility:**

- Old client → new server: sends bare emails → parses to `{ email }` → identical
  behaviour.
- New client → new server: sends `"Name <email>"` → named contact.
- New client → old server: the old server would pass the whole `"Name <email>"`
  string as `email`, which fails `upsert_contacts`' email regex and is silently
  dropped. Prevented by the enforced **workers-deploy-before-app** ordering
  (zero-downtime deploy work) — the server learns to parse before any app that
  emits the named form ships. *Call out in the finalize/back-compat check.*

---

## 6. Step-2 hand-off

- **Focus pre-select:** add optional `priorityId` to `ComposeTarget`
  (focus-note). In `_suggestFocusForTarget`, if `target.priorityId != null`,
  resolve that `Priority` and `_switchToPriority(it)` directly, skipping MRU
  ranking. Other kinds keep today's roster/global MRU suggestion.
- **Named invites:** `_applyTarget` already forwards `target.inviteEmails` to the
  draft; with the encoded `"Name <email>"` strings this is unchanged. The
  contacts compose field shows the parsed name on each invite chip.

---

## 7. Hover: full names + emails

Wrap the line-2 content (people line) in an `FTooltip` listing every recipient
as `name — email` (resolved contacts and named/bare invites alike). This
supplements `AvatarGroup`'s built-in name-only tooltip, satisfying "on hover,
show the full list of names and email addresses." Mind the thread-panel tooltip
clipping note if the picker ever renders inside the right panel (not the case
for the inline step-1 page).

---

## 8. Exception-only email disambiguation

Goal: in the list, a person reached at a single address shows just their name;
when a display name maps to >1 address **within a connection**, the primary
(most-used/most-recent) stays bare and the secondary entries show
`Name <email>`.

Data (built in the context build, cached): per connection-grouping key, a
`Map<lowercased name, List<contactId>>` ordered by recency/frequency from the
scan. At render time, for each roster contact:

- resolve name + email;
- if that name's address list for the connection has length 1 → bare name;
- else if this contact is the first (primary) → bare name; otherwise →
  `Name <email>`.

Hover (§7) always shows the full address regardless.

---

## 9. Resolved decisions

1. **Account in connector header:** keep the quieter ">1 connection only" rule
   (§2).
2. **Twist targets:** included in this change (§3).
3. **Empty-start flow:** removing the bare generic Note/Chat rows is intentional;
   empty shared threads start from a focus-note (+ add people) or by typing a
   person/email (§3).
4. **Plot chat header tint scope:** tint by the most-common focus of all Plot
   threads **in that scope**, with `plot:{scope}` as a per-Personal/per-team
   grouping key (§4) — a work team's dominant colour stays distinct from
   personal.

---

## 10. Build sequence (phases)

1. **Model & parsing:** `EmailParser.parseRecipients` + `ParsedRecipient`;
   `InviteAddress` encode/parse; `ComposeTarget.priorityId`; `ContactChipEmail`
   name parsing. Unit tests for the parser/encoder.
2. **Bloc:** `ComposeScanThread.priorityId`; per-connection focus tally + the
   one-shot `Priority.get` colour map; roster-actor batch load; per-connection
   name→address map; focus-note + twist targets replacing Note/Chat;
   multi-recipient `_searchByRecipients`. Extend `compose_targets_test.dart`.
3. **Row UI:** two-line row widget (header + content), focus-tinted header,
   logo/focus-icon/twist-logo leading, AvatarGroup + names / channel / focus
   name, exception-only email rendering, row-level hover tooltip,
   `estimatedItemHeight` + scroll-math update. Keep highlight/hover/keyboard nav.
4. **Step-2:** focus pre-select in `_suggestFocusForTarget`; verify named-invite
   chips render names.
5. **Server:** `threads.ts` parses `Name <email>` → `{ email, name }`.
6. **Finalize:** `flutter analyze` (full app — none of these are non-null Drift
   columns, but run full per the analyze guidance), `pnpm lint` for the worker,
   back-compat check (deploy order), `captureException` on new catches,
   `docs/updates.md` bullet, `docs/features.md` if warranted.

## 11. Testing

- `EmailParser.parseRecipients`: bare, comma/semicolon/space lists, `Name
  <email>`, mixed, quoted names, junk-rejection.
- `InviteAddress` round-trip.
- Bloc: focus-note targets from a scan (MRU + scope), per-connection colour
  tally winner, exception-only disambiguation (single vs multi address per
  name), multi-recipient email search (resolved + named-invite mix). Reuse the
  DB-free pure-helper testing style already in `compose_targets_test.dart`.
- Manual (run-app): row rendering for each kind, focus tints, avatars + names
  truncation, hover tooltip, typing `a@x.com, Kris Braun <k@y.com>` →
  multi-recipient chat with one named invite; submit → named contact created.
