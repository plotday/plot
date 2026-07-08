# Newsletter email formatting — design

**Date:** 2026-07-07
**Branch:** `newsletter-email-formatting`
**Status:** Design approved; spec under review

## Problem

Newsletter / digest emails (Firefox "Ten Tabs", Substack, Mailchimp/SendGrid/Braze
campaigns, etc.) render as noisy notes in Plot. The triggering example was a Firefox
Ten Tabs digest: 10 stories, each rendered with a duplicated link, a "Share" button,
decorative chrome, and a hidden preheader teaser.

## Root cause (confirmed)

Mail connectors do **not** convert HTML themselves. Both Gmail (`extractBody`,
`public/connectors/gmail/src/gmail-api.ts:612`) and Outlook
(`graph-mail-api.ts:658`) **prefer the HTML part** and send it to the server with
`contentType: "html"`. All HTML→Markdown conversion happens server-side in a single
chokepoint both connectors share:

`workers/api/src/twist/tools/plot/thread-helpers.ts` → `convertNoteToMarkdown` (`:770`)

```
preprocessEmailHtml (HTMLRewriter, pre-AI)  →  ai.toMarkdown (Workers AI)  →  cleanConvertedMarkdown (post-AI)
```

The existing pipeline already handles a lot (unwraps layout tables, drops decorative
image-links, strips zero-width preheader padding, collapses blank lines, repairs glued
inline elements). What it does **not** handle is the digest shape specifically. Because
the fix is in this shared server function, one change improves **every** mail
connector at once — no connector edits, no `public/` submodule PR, no changeset.

## Goal & scope

Add **three** deterministic transforms to the two existing pure functions so a
newsletter becomes **one cleaned note**. No AI, no re-structuring, no per-email gating.

The three transforms are precise enough to be safe on *all* email (a normal message has
no adjacent duplicate-href links, no empty-recipient `mailto:` buttons, and no hidden
`display:none` blocks), so they run unconditionally in the shared path and need no
newsletter classifier signal threaded down from the connector.

### Transform 1 — De-duplicate same-href links
**Where:** `cleanConvertedMarkdown`, immediately after the existing
empty-image / empty-link / decoration-image-link removal (current `:388`–`:406`) and
before the line-splitting loop. (Running after the image-link drop matters: the
poster-thumbnail link — which shares the story href — is already gone, so the title
becomes the first link.)

**Why:** In digest layouts the poster image, the headline, and the dek all link to the
*same* story URL, so each story renders its link 2–3×.

**Algorithm (operate on inline link tokens `[text](href)`, never images `![…]`):**
1. Scan left-to-right for inline links; capture text, href (href taken up to whitespace
   or `)`), and start/end offsets.
2. Maintain `lastEndByHref: Map<href, endOffset>`.
3. For each link with href `h`: if `h` was seen before **and** the raw substring between
   the previous same-href occurrence's end and this link's start is whitespace-only,
   mark this link for de-linking (replace `[text](href)` → `text`). Otherwise keep it as
   a link. Update `lastEndByHref[h]` to this link's end **either way** (so a run of 3+
   contiguous same-href links all collapse to the first).
4. Apply the de-link replacements right-to-left so offsets stay valid.

**Precision:** Only *contiguous* same-href links (whitespace-only gap) collapse. A
same-href link separated by prose (e.g. "click here" repeated across paragraphs) has
non-whitespace between the occurrences, so it is left as a link. Different-href links are
never touched.

**Known limitation:** links carrying a title (`[t](url "title")`) won't dedupe (href
capture stops at whitespace). Acceptable — `ai.toMarkdown` effectively never emits link
titles for email.

### Transform 2 — Drop empty-recipient share buttons
**Where:** `preprocessEmailHtml` (HTMLRewriter), new `a` element handler.

**Rule:** remove `<a>` whose `href` matches `/^mailto:(\?|$)/i` (i.e. `mailto:` with no
address before the `?`, such as `mailto:?subject=Shared%20Via%20Firefox…`). This is
*always* a compose/share widget, never "email this person," so a real
`mailto:someone@example.com` link is preserved. Removing at the HTML level also benefits
the `stripHtmlToText` fallback path (it runs on the already-preprocessed HTML).

### Transform 3 — Drop hidden preheader / teaser + tracking pixel
**Where:** `preprocessEmailHtml` (HTMLRewriter).

**Rule:** remove any element whose `style` attribute indicates it is visually hidden:
`display:none`, `visibility:hidden`, or `opacity:0` (whitespace-insensitive;
`opacity:0` must not match `opacity:0.9` → require the `0` not be followed by `.`/digit).
Hidden = the recipient's own mail client never showed it, so removal matches what the
user saw. Covers the hidden "Plus: …" teaser and the wrapper that carries the 1×1
tracking-pixel `<img>`.

**Implementation note:** fold the hidden check into the existing `table`/`tr`/`td`/`th`
handlers (check hidden → `el.remove(); return;` before the unwrap/`toDiv`), and add
`div`/`span`/`p` handlers plus an `img` handler that also removes ≤1×1 pixels. Detail
belongs to the implementation plan.

## Explicit non-goals (v1)

- **Footer stays.** The Unsubscribe / Manage Preferences / Privacy / Help Center links
  are legitimately useful and already render cleanly (they are plain `https` links; the
  social-icon row is dropped as decoration). No footer trimming.
- **No re-structuring.** We do not promote the category to a heading or synthesize a
  numbered list — that is the AI-reformat approach, declined.
- **No network URL-unwrapping.** Opaque path-based trackers (`clicks.mozilla.org/f/a/…`)
  don't carry the destination in the URL; recovering it needs an HTTP fetch, which fires
  the sender's open/click tracking and leaks that Plot opened the mail. After Transform 1
  the *visible* text is already clean; only the underlying href stays a tracker, which is
  acceptable. (Param-embedded unwrap like `?url=…` is a safe future add.)
- **No newsletter gating / no connector changes / no changeset / no `public/` PR.**

## Result on the Ten Tabs email (expected)

Each story collapses from *image-link + linked-title + linked-dek + source + author +
Share-button* to:

```
Sports
**What we learned, big and small picture, from the USMNT's awful World Cup exit**   ← link
This generation may still turn out to be golden…                                     ← plain text
NBC Sports · Nicholas Mendola
```

…×10, with the hidden teaser and tracking pixel gone and the Unsubscribe/legal footer
intact.

## Testing

All three transforms live in the two **pure** functions, which the existing suite
(`workers/api/src/twist/tools/__tests__/email-html.test.ts`, run under
`vitest.integration.config.ts`) already unit-tests directly — no AI binding required, so
tests are deterministic and fast.

Add cases:

- **`cleanConvertedMarkdown` (Transform 1):**
  - title + dek links to the same href (blank line between) → first stays a link, second
    becomes plain text.
  - three contiguous same-href links → one link + two plain-text.
  - **negative:** two links to *different* hrefs → both preserved.
  - **negative:** same href separated by a prose paragraph → the prose-separated
    occurrence stays a link.
- **`preprocessEmailHtml` (Transforms 2 & 3):**
  - `<a href="mailto:?subject=…">Share</a>` → removed.
  - **negative:** `<a href="mailto:real@example.com">Email</a>` → preserved.
  - `<div style="display:none…">Plus: teaser</div>` → removed.
  - hidden wrapper containing a 1×1 `<img>` tracking pixel → removed.
  - **negative:** a visible `<div>` and an `opacity:0.9` element → preserved.

Baseline before changes: `email-html.test.ts` = 36 passing.

## Verification

- Unit tests above (deterministic, no AI).
- Optional end-to-end eyeball: `wrangler dev` the API worker and run the real Ten Tabs
  HTML through `convertNoteToMarkdown` to confirm the full pipeline output.

## Rollout

Single-file change (`thread-helpers.ts`) + test additions. No DB/schema/migration, no
connector or `public/` changes, no changeset. Ships via the normal API worker deploy and
retroactively improves newsletters on **re-sync** (existing notes are re-converted when
the message is next synced).
