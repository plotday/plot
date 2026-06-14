# OTP / Confirm Detection + Time-Sensitive Action Toast — Design

**Date:** 2026-06-14
**Status:** Approved design, pending implementation plan
**Scope:** Backend (email-classifier + connectors + SDK + DB + API push) **and**
Flutter app (in-app toast + background OS notification). One effort.

## 1. Problem

When a user receives a time-sensitive message — a **one-time passcode (OTP)** or
a **"confirm your account"** email — Plot today treats it like any other
message: it lands in a thread, classified at best as a generic `notification`.
The user has to dig the email out of a feed to copy a code or click a confirm
link, defeating the point of a code that expires in minutes.

We want Plot to **recognize these messages, extract the actionable bit (the code
or the confirm link) and the service it's from**, and surface it immediately and
ephemerally:

- A **dismissable in-app toast** shown for **5 minutes after the message was
  sent**, with either the **code + a copy button**, or a **"Confirm your
  [SERVICE] account"** button.
- A **background OS notification** carrying the same when the app isn't
  foregrounded.

The hard constraint is **precision**: it is far better to miss a detection than
to surface a wrong/forged action. Confirm links in particular are a phishing
vector, so they must be authenticated before we trust them.

## 2. Approach

Extend the **existing facet-extraction pipeline** (heuristic, deterministic, at
the connector source) rather than introducing an LLM:

- **(A) Detection & extraction** — the shared `email-classifier` library gains a
  `format` of `otp` | `confirm` plus a structured **CTA payload**
  `{ kind, service, code, url }`. Pure heuristics with strict precision rules.
  Link extraction is **gated on DMARC pass**; code extraction is not (a forged
  number is harmless, a forged link is not).
- **(B) Delivery to the client** — facets are server-only today, so the CTA is
  carried to the client on a **new synced `note.cta` jsonb column** (per-note,
  because the 5-minute window keys off the message's sent time).
- **(C) In-app toast** — a single global, replace-by-latest, dismissable overlay
  driven by a controller backed by a Drift watch over recent notes with a `cta`.
- **(D) Background push** — when a fresh `cta` note is persisted, fire an
  **immediate, data-only** push on a dedicated path that bypasses the standard
  push gates; the client shows a local OS notification, with the code read from
  the local DB (never sent through FCM/APNs).

Design priorities (inherited from the facet system): deterministic & cheap;
extensible to other connectors later; **bias to false-negative** on every
ambiguous extraction.

## 3. Sources & SDK surface

- Detection lives in **`public/libs/email-classifier`** (in the `public/`
  submodule). **Gmail** and **outlook-mail** both already call
  `classifyEmail()`; both gain the new inputs and the `extractCta()` call.
- The **SDK (`public/twister`)** is the source of truth for the shapes any
  connector consumes: the two new `Format` values and the new `Cta` type. This
  lets non-email connectors opt in later. **Non-email connectors are explicitly
  out of scope for this effort.**
- A **twister changeset** accompanies the SDK change (required by AGENTS.md). The
  `EmailSignals` *input* type lives in the classifier lib (no changeset), but the
  whole `public/` change ships as one public PR.

## 4. Detection & extraction (heuristics)

### 4.1 New `EmailSignals` inputs

`classifyEmail()` is header/metadata-only today. The classifier lib's
`EmailSignals` gains:

| Field | Purpose |
|---|---|
| `bodyText: string \| null` | code keyword/adjacency scan |
| `fromName: string \| null` | service-name derivation (display name) |
| `links: { text: string; href: string }[]` | confirm-link candidate set (anchor text → href) |
| `authResults: string \| null` | raw `Authentication-Results` header for DMARC parsing |

Both connectors populate these. They already have the raw HTML body
(`extractBody`) and `Authentication-Results` (`getHeader` / Graph
`internetMessageHeaders`) with no new API calls. A shared
`extractLinkCandidates(html)` helper produces the `{text, href}[]` pairs.

### 4.2 Output

`classifyEmail()` stays facet-only (returns `ThreadFacets`). A sibling
**`extractCta(signals): Cta | null`** returns the actionable payload:

```ts
// public/twister/src/facets.ts (or a new cta.ts export)
export type Cta = {
  kind: "otp" | "confirm";
  service: string;        // e.g. "Acme"
  code: string | null;    // present for kind === "otp"
  url: string | null;     // present for kind === "confirm" (DMARC-verified)
};
```

`Format` gains `"otp"` and `"confirm"`. When `extractCta` returns non-null, the
connector sets the thread `format` accordingly (precedence below) and attaches
the `Cta` to the originating note.

### 4.3 OTP code rule

Extract a token of **4–8 chars** (digits, or grouped forms like `G-123456`,
`ABZ-419`) that sits **adjacent** (same line / within N chars) to an OTP keyword:
`code`, `verification code`, `security code`, `confirmation code`, `one-time`,
`one time`, `passcode`, `OTP`, `2FA`, `two-factor`, `PIN`, `verify`.

**Reject** tokens that look like: a 4-digit year, a `$`-prefixed amount, a phone
number, or an order/invoice number (`#`-prefixed, "order", "invoice" context).
On multiple candidates, prefer the first strong keyword-anchored match. No
DMARC requirement (a forged code is inert).

→ sets `code`, `kind = "otp"`.

### 4.4 Confirm link rule (all must hold)

1. **DMARC = pass** (parsed from `authResults`). No pass ⇒ no link, full stop.
2. A link whose **anchor text** matches a confirm-verb: `confirm`, `verify`,
   `activate`, `confirm your email/account/subscription`, `verify your
   email/account`, `activate your account`, `complete (your) sign-up /
   registration`.
3. The anchor text does **not** match any negative/secondary pattern: `wasn't
   you`, `was not you`, `didn't request`, `didn't sign`, `not you`, `reset`,
   `change password`, `unsubscribe`, `report`, `cancel`, `decline`, `manage`,
   `view in browser`, `privacy`, `terms`, `help`.
4. **No conflicting candidates** — if two distinct hrefs both match confirm-verbs
   with no clear single winner, **skip** (ambiguity ⇒ false-negative).

A subject/preheader confirm signal is corroborating but **not** sufficient
alone; anchor-text match is primary.

→ sets `url`, `kind = "confirm"`.

### 4.5 Service name

From `fromName` (display name, cleaned of "no-reply"/"team"/"notifications"
noise), else the registrable domain of `fromAddress` title-cased
(`noreply@acme.com` → "Acme"). This is `[SERVICE]` in the UI.

### 4.6 Format precedence

Code present ⇒ `format = "otp"` (and `kind = "otp"`); else valid confirm link ⇒
`format = "confirm"`. Both `code` and `url` may be stored, but the **toast
prefers the code** (codes are the more time-sensitive, dominant pattern). Neither
found ⇒ existing format heuristic unchanged.

### 4.7 Gating side-effect (flagged)

Adding `otp`/`confirm` to `Format` means an OTP email that previously classified
as `notification` now classifies as `otp`, so a focus filtering on `notification`
no longer catches it. This is desirable (OTPs are ephemeral) and the default
no-filter behavior is unchanged — they still appear in unfiltered focuses.

## 5. Delivery to the client

A new nullable **`note.cta` jsonb** column (per the chosen name) holds the `Cta`.
Per-note granularity is required because the 5-minute window keys off
`note.source_created_at` (= email sent time) of the specific message.

Flow (parallels existing `link.facets` → `thread.facets`):

1. Connector's facet/cta path attaches `cta` to the originating `NewNote`
   (the note for the parent message).
2. Twister `NewNote`/`Note` gain `cta?: Cta | null`.
3. The API note-write chokepoint (`workers/api/src/twist/tools/plot/note.ts`,
   the `dbNote` mapping) persists it to `note.cta`.
4. It syncs to the Flutter client like any other note column.

`thread.facets.format` is still set server-side (classifier signal), but the
toast is driven **solely** by `note.cta` — the client never needs the
server-only facets blob.

*Privacy:* the code already lives in the synced note body, so `note.cta` does not
widen exposure. `note.canonical_source` dedup means the same email synced by two
connections converges to one note (one CTA).

**Considered alternative:** a new `Action` variant on the existing `note.actions`
array (migration-free, already synced). Rejected in favor of a dedicated column
to keep the transient toast trigger decoupled from in-note action buttons
(attachments, etc.).

## 6. In-app toast (foreground)

- An **`OtpPromptController`** (`ValueNotifier`) wired in
  `lib/state/root_provider.dart`, backed by a **Drift `.watch()`** over recent
  notes with a non-null `cta`. Firing on both **live sync arrival** and **app
  foreground** falls out of the watch naturally.
- Window: visible while `now − note.sourceCreatedAt < 5 min`; auto-dismisses at
  expiry (timer).
- **OTP variant:** "**[Service]** verification code", the code shown large, a
  **Copy** button (`Clipboard.setData`, ✓ feedback) — matches the existing
  `_CopyButton` pattern in `lib/widget/toast.dart`.
- **Confirm variant:** "Confirm your **[Service]** account" + a primary button →
  opens `url` externally (`url_launcher`).
- **Dismissable** (X); dismissed note ids tracked in-memory so a dismissed CTA
  doesn't reappear within its window.
- **Replace-by-latest:** the controller holds a single current CTA; a newer
  qualifying note replaces whatever is showing.
- Rendered via the global overlay (forui `FToaster` / `showOverlayToast`
  infrastructure), styled with the app's forui tokens (no `material.dart`).

## 7. Background push (app not foregrounded)

Reuse the existing **data-only** push + client-local-content pattern so the code
never transits FCM/APNs.

- **Server:** when the API persists a note with a fresh `cta`, fire an
  **immediate, data-only** push (`type: "otp"`) to the owning user's devices on
  a **dedicated path that bypasses** the importance / 10-min-inactivity /
  5-min-interval / notify-window gates (those gates live in
  `state/push-notify.ts` and the client handlers). Integration point: the
  note-creation path resolves the owning user and calls the existing
  `sendDataNotificationToUser` directly with the new type. "Fresh" = within the
  5-minute window at persist time.
- **Client:** `lib/notifications/background_handler.dart` (and the foreground
  FCM handler) recognize `type: "otp"`, sync, read `note.cta` from the local DB,
  and show a **local OS notification immediately** (skipping the notify-window
  defer): OTP → code in the body (enables iOS code autofill); confirm →
  "Confirm your [Service]" deep-linking to the thread.
- **Replace-by-latest:** a single reserved stable notification id so a newer CTA
  replaces the prior one.
- **Foreground vs background:** foreground shows the in-app toast only (no OS
  notification); background shows the OS notification only. Tapping it opens the
  thread, where the in-app toast (if still in-window) offers copy/confirm.

## 8. Testing

### 8.1 Corpus from anonymized prod (read-only)

Use the **`prod-db-investigate`** skill (read-only) to pull real examples from
Kris's prod account:

- **Positives:** OTP emails (varied phrasings/services), confirm-account emails.
- **Critical negatives:** password-reset, "if this wasn't you", unsubscribe-only,
  promos containing numbers, receipts with order totals / `$` amounts,
  newsletters with "verify"-ish marketing copy, **unauthenticated (DMARC-fail)**
  confirm-looking emails.

**Anonymize** before committing fixtures: synthetic same-shape codes,
structurally-faithful but fake URLs/domains, scrubbed names/emails/PII —
preserving the linguistic and structural features the heuristics key on.

### 8.2 Unit tests

- `email-classifier/src/classify-email.test.ts` (+ a new `extract-cta.test.ts`):
  every positive extracts the right code/link/service; every negative extracts
  **nothing**; DMARC-fail ⇒ no link even with a confirm anchor; code-rejection
  rules (year/price/phone/order).
- `extractLinkCandidates(html)` anchor-text/href extraction.

### 8.3 Flutter tests

- Window math (in-window vs expired), replace-by-latest, dismiss-doesn't-reappear,
  variant selection (otp vs confirm), service-name rendering.

## 9. Files touched (orientation, not exhaustive)

**`public/` submodule (one PR + changeset):**
- `public/twister/src/facets.ts` — `Format` += `otp`/`confirm`; `Cta` type/export.
- `public/twister/src/plot.ts` — `NewNote`/`Note` gain `cta`.
- `public/libs/email-classifier/src/` — `EmailSignals` inputs; `extract-cta.ts`;
  `extractLinkCandidates`; tests.
- `public/connectors/gmail/src/{gmail.ts,gmail-facets.ts,gmail-api.ts}` — populate
  new signals, call `extractCta`, attach `cta` to the note.
- `public/connectors/outlook-mail/src/{outlook-mail.ts,outlook-facets.ts,graph-mail-api.ts}` — same.
- `public/.changeset/*.md`.

**This repo:**
- `libs/db/schema/50-tables/25-note.sql` — `cta jsonb` column; migration via
  `pnpm gen-migration`; commit regenerated `libs/db/src/types.ts`.
- `workers/api/src/twist/tools/plot/note.ts` — map `cta` into `dbNote`.
- `workers/api/src/notifications/` + note-creation path — immediate data-only
  OTP push (gate-bypassing).
- `apps/plot/libs/store/` — note entity gains `cta`.
- `apps/plot/lib/state/root_provider.dart` — `OtpPromptController` + Drift watch.
- `apps/plot/lib/widget/` — the toast widget (otp/confirm variants).
- `apps/plot/lib/notifications/{background_handler.dart,notification_service.dart}` —
  `type:"otp"` handling.
- `docs/updates.md` / `docs/features.md` — user-facing change.

## 10. Build sequence (high level; detailed plan to follow)

1. SDK types (`Format`, `Cta`, `NewNote.cta`) + changeset; build twister.
2. `email-classifier`: inputs, `extractCta`, `extractLinkCandidates`, tests
   (seed with anonymized corpus).
3. Connectors (Gmail, Outlook): populate signals, attach `cta`.
4. DB: `note.cta` column + migration + types.
5. API: persist `cta`; immediate OTP push path.
6. Flutter: store entity, controller + Drift watch, toast widget.
7. Flutter: background/foreground push handling.
8. Tests (Flutter), `/finalize`, docs.

## 11. Open questions / risks

- **DMARC parsing robustness** across providers' `Authentication-Results`
  formats — handle absence/malformed as "not pass".
- **Heuristic precision on real mail** — the anonymized corpus is the guardrail;
  tune to zero false-positives on negatives, accept misses.
- **Push gate-bypass** must not regress the normal notification throttling for
  non-OTP traffic — the OTP path is additive and narrowly typed.
