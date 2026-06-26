# Pricing page rewrite

Date: 2026-06-26
Status: Draft design — in review

## Summary

The marketing pricing page (`apps/site/app/routes/pricing.tsx` + `app/lib/plans.ts`)
is rewritten around a new positioning and a simplified, more honest pricing
model. Two forces drive the change:

1. **The product repositioned** from a Slack-replacement (collaboration-first)
   to a **universal inbox** (bring all your apps into one prioritized place).
   The old hero — *"Simple pricing. No per-seat fees."* — no longer fits: the
   individual plans are effectively per-person, and the thing you actually pay
   for is **connections** (per account, finer than a seat).
2. **The pricing model is being simplified** alongside the independent,
   usage-based connection add-ons work
   (`docs/superpowers/specs/2026-06-25-independent-usage-based-add-ons-design.md`):
   the Core plan is dropped, connections become à-la-carte, twist/AI pricing is
   folded into a single weighted **automation capacity**, and the patchwork of
   AI limits and BYOK/model-choice options is removed.

**This spec covers the marketing page only.** The product/billing changes
required to make this model real are designed separately in Spec B
(`2026-06-26-pricing-model-product-changes-design.md`) and built by another
agent. Where this page promises something the backend doesn't yet do, that
gap is tracked in Spec B, not here.

## Goals

- Replace the hero/positioning so it reflects the universal-inbox product and
  the "platform is free; pay for what you add" pricing spine.
- Drop the Core plan; present **Free / Pro / Team**.
- Present connections as à-la-carte: each plan includes some; extras are a flat
  **$5/mo connection add-on**; a few connectors **always require** one.
- Replace per-plan twist counts and separate AI pricing with a single
  **automation capacity** story (weighted slots, AI bundled in, +20 for $10/mo,
  built-in assistant included free).
- Highlight how generous the Free tier is (the whole platform, not a crippled
  trial), now that Free-tier AI limits are removed.
- Rewrite the FAQ to match; remove stale answers (per-seat, BYOK, model choice,
  add-on-counts-as-a-connection).

## Non-goals

- Implementing the backend that supports this model (Spec B).
- Changing plan prices ($0 / $25·$20 / $124·$99) or the $5 add-on price.
- The in-app `apps/plot` purchase UX, or the `apps/site` `upgrade.tsx`
  checkout/account flow (both are client payment work tracked in Spec B).
- Touching `workers/api/src/utils/limits.ts` `PLAN_LIMITS` (Spec B), even though
  `plans.ts` mirrors it. `plans.ts` here is updated for the page; the API mirror
  is updated in the same PR as the backend work per the note at the top of
  `plans.ts`.

## Terminology (decided)

- **Automations** is the user-facing term for what the app/SDK calls **twists**.
  We lead with "automations" because readers don't yet know "twist," and we
  avoid "extensions" because it reads as an *integration* (which is our
  *connection*). Introduce the product name once, in the body
  ("Automations — we call them twists — …"), never in the hero.
- **Connections that require an add-on** are never called "premium" or "pro" in
  copy. The connector carries an **"Add-on required"** badge; prose says it
  *"needs a connection add-on."* (The internal `twist.premium` code flag is
  unchanged and never surfaced.)

## The pricing model (decisions locked in brainstorming)

### Plans: Free / Pro / Team (Core dropped)

| | Free | Pro | Team |
|---|---|---|---|
| Price | $0 | $25/mo ($20 annual) | $124/mo ($99 annual) **per 50 connections** |
| Connections | 2 included | Unlimited | 50 shared per block |
| Extra connections | $5/mo each | included | add a 50-block |
| Automation capacity | 1 | 10 | 10 per 50-block |
| Built-in assistant | included | included | included |
| Initial import | 1 week | 1 year | 1 year |
| Collaboration | free | free | free (**headline benefit**) |

**Why drop Core:** both Core and Pro were single-person plans differing only by
volume, and the gap was thin ($10/mo for 5→unlimited connections, 30-day→1-year
history). The new à-la-carte connection add-on fills the Free→Pro ladder
(below), so a cheap middle tier is no longer needed; the pricing nudges users to
Pro on its own.

### Connections — à-la-carte, per account

- A connection is **one account** linked to Plot. Connecting a **personal Google
  and a work Google account counts as two connections.**
- **Composite connectors count once per account:** one **Google** connection
  covers Gmail, Calendar, and Tasks; one **Outlook** connection covers mail and
  calendar. These are never shown or counted as separate connections.
- Each plan includes a base number; **every connection beyond that is a flat
  $5/mo connection add-on.** This mainly matters on **Free** (Pro is unlimited;
  Team adds 50-blocks).
- **A few connectors always require a connection add-on**, on every plan, because
  they have real per-account costs to operate: **LinkedIn, Instagram, WhatsApp**.
  These never draw from the included pool and carry an "Add-on required" badge.
- **The ladder self-caps.** On Free, 5 add-ons = $25 = Pro, so once you need ~5
  extra connections, Pro is the obvious choice. No hard cap on Free add-ons; the
  page nudges to Pro at the break-even.

> **Two reasons an add-on applies — keep them distinct on the page.**
> (1) *Capacity*: you've used your plan's included connections (optional —
> upgrade instead). (2) *Required*: this specific connector always needs an
> add-on (LinkedIn/Instagram/WhatsApp). The page presents one concept ("extra
> connections are $5/mo each") plus a clearly-labeled "Add-on required" callout
> for the always-required connectors, and a per-connector badge wherever
> connections are listed.

### Automations (twists) — weighted capacity, AI included

- Each plan includes an **automation capacity** measured in slots:
  **Free 1 · Pro 10 · Team 10 per 50-connection block.**
- An automation can be **heavier than one slot**: a 2× automation uses 2 of your
  capacity, a 10× automation uses 10. Capacity is **active capacity** — it counts
  what you have enabled at once; disable one to free its slots. No monthly reset,
  no metering.
- **AI usage is bundled into the slot weight.** Heavier/AI-intensive automations
  simply have a higher multiplier — there is no separate per-token AI bill.
- **Need more capacity? +20 slots for $10/mo.**
- **The built-in Plot assistant is included on every plan and costs 0 slots.** It
  has **no separate usage limit** on any plan, and it's the general-purpose
  helper rather than an installed automation.

### AI — simplified away

Removed from the page (and the product, per Spec B): separate AI/token pricing,
bring-your-own-API-key, choose-your-AI-model, and the per-feature monthly AI
limits on Free. **No AI usage limits are communicated** — AI that powers
organization, prioritization, the built-in assistant, and automations is simply
part of what you're already paying for.

## Page structure & draft copy

> All copy below is **draft** for the structure review. Final wording is a
> follow-up messaging pass. Sentence case throughout (project convention).

### 1. Hero

- **Title:** *"Everything you need to bring your work together."*
- **Subtitle:** *"Plot is free to use, forever. Pay only to extend with extra
  connections and automations."*
- Remove the old "No per-seat fees" gradient title and its subtext.
- Update page `meta` title/description to match (drop "no per-seat fees").

### 2. Billing toggle

Keep the monthly/annual `SegmentedControl` and "Save 20%" badge. Applies to Pro
and Team (Free unaffected).

### 3. Plan cards — Free / Pro / Team

Three cards (down from four). Pro stays highlighted. Each card's connection line
carries the à-la-carte note; a shared footnote covers the always-required
connectors. Cards use "automations" (the term "twist" is introduced later, in
the explainer).

**Free — $0, "Free forever"**
- Best for: *"Getting all your work into one place"*
- Description: *"The whole Plot platform, free forever."*
- Features:
  - Up to 2 connections — *$5/mo each beyond*
  - Built-in Plot assistant
  - 1 automation
  - Automatic organization and prioritization
  - Unlimited history and full search of everything in Plot
  - Collaborate free with anyone on Plot
  - Import 1 week of history from your connections
- CTA: "Get started" → `/start`

**Pro — $25/mo ($20 annual), highlighted**
- Best for: *"Living across many tools at once"*
- Description: *"Unlimited connections and more automation."*
- Features:
  - Unlimited connections
  - Built-in Plot assistant
  - 10 automations
  - No-code automation builder
  - Import 1 year of history from your connections
  - Everything in Free
- CTA: "Get started" → `/upgrade?plan=pro&billing=…`

**Team — $124/mo ($99 annual), "per 50 connections"**
- Best for: *"Doing your team's best work together"*
- Description: *"Shared connections and automation for your whole team."*
- Features:
  - 50 connections shared across your team (add 50-blocks anytime)
  - **Unlimited members — collaborate free**
  - Built-in Plot assistant
  - 10 automations per 50 connections
  - No-code automation builder
  - Import 1 year of history from your connections
  - Team-level controls
  - Everything in Pro
- CTA: "Get started" → `/upgrade?plan=team&billing=…`

**Shared footnote under the cards:**
*"A few connectors — LinkedIn, Instagram, and WhatsApp — always need a $5/mo
connection add-on, on any plan. They don't count toward your included
connections."*

`plans.ts` changes: remove the `core` entry; remove the per-plan
`Connection add-ons $5/mo each` feature line (now framed as the à-la-carte note
on the connection line + the footnote); drop the Free "limitations apply" AI
framing (no AI limits now); update twist lines to the new capacity numbers and
"automation" wording; keep `ADDON_PRICE`.

### 4. "What's a connection?" — both angles

Keep the section; rework content for the new model.

- **Definition (prose):** *"A connection is one account you link to Plot — one
  Google account, one Slack workspace, one Linear org. Each account is one
  connection, and one connection brings in everything in that account."*
- **Individual angle (paragraph, no table):** make the per-account point
  explicit. Draft: *"Connections are per account, not per app. If you link your
  personal Google and your work Google, that's two connections. And because Plot
  groups an account's tools together, one Google connection covers Gmail,
  Calendar, and Tasks; one Outlook connection covers mail and calendar."*
- **Team angle (keep a table for estimation):** B2B buyers use it to size their
  team. **Fix the table for composite connectors** — collapse the separate
  "Gmail" and "Google Calendar" rows into a single **"Google"** row (and Outlook
  likewise), which also corrects the previously inflated total. Keep the
  closing line about a team's connection count scaling with the tools each
  person connects.

### 5. "What's an automation?" — capacity + AI explainer

Rework the existing "What's a twist?" section. **This is where the term "twist"
is introduced.**

- Intro: *"Automations — we call them twists — add new capabilities to Plot:
  agents, and custom workflows that act on your behalf. Install ones published by
  others, or build your own. They all run securely within Plot."*
- Capacity: *"Your plan includes automation capacity — Free includes 1, Pro
  includes 10. A heavier automation uses more: a 2× automation takes 2 of your
  capacity. Turn one off to free up room, or add 20 more for $10/mo."*
- AI bundled: *"When an automation uses AI, that cost is already included in its
  capacity — there's no separate AI bill, no API keys to bring, and nothing to
  configure."*
- Built-in assistant: *"The built-in Plot assistant is included on every plan and
  never uses your automation capacity — it's the general-purpose helper, included
  on Free too."*
- Remove the "AI billed at cost / bring your own API keys / set budgets"
  paragraphs.

### 6. FAQ — rewritten

Replace the FAQ array. Proposed Q&A (draft answers):

1. **How does Plot's pricing work?** — The whole platform is free to use,
   forever. You pay only for the things you add on top: extra **connections**
   (the accounts you link) and **automations**. Most people start free and add
   connections as they grow.
2. **What counts as a connection?** — One account you link to Plot. Each account
   is one connection and brings in everything inside it. Linking your personal
   and work Google accounts is two connections. Composite connectors count once:
   one Google connection covers Gmail, Calendar, and Tasks; one Outlook
   connection covers mail and calendar.
3. **What's a connection add-on?** — Every plan includes some connections; each
   connection beyond that is a $5/mo add-on. On Free you start with 2 and can add
   more at $5/mo each; once you'd need about five extra, Pro (unlimited) is the
   better deal.
4. **Which connectors always need an add-on?** — LinkedIn, Instagram, and
   WhatsApp. They're provided through a third party with real per-account costs,
   so they always need a $5/mo connection add-on — on any plan, including Free —
   and they don't count toward your included connections.
5. **What happens when I reach my connection limit?** — On Free, add connections
   for $5/mo each, or upgrade to Pro for unlimited. On Team, add another block of
   50 connections anytime; on annual billing, added blocks are prorated.
6. **What's an automation?** — An automation (we also call them twists) adds a
   capability to Plot — an agent or a custom workflow that acts for you. Install
   ones others publish, or build your own with the no-code builder. They all run
   securely inside Plot.
7. **How does automation capacity work?** — Your plan includes a number of
   automation slots (1 on Free, 10 on Pro). Most automations use one slot; heavier
   ones use more (a 2× automation uses two). It's based on what you have turned
   on, so you can free up room by turning one off — or add 20 slots for $10/mo.
8. **How does AI work, and what does it cost?** — AI is built in. The Plot
   assistant is included on every plan, and when an automation uses AI the cost is
   already included in its capacity — no token bills, no API keys, nothing to
   configure.
9. **Is collaboration really free?** — Yes. Inviting people to work together in
   Plot is free on every plan, including Free. The Team plan adds a shared pool
   of connections, unlimited members, and team-level controls for businesses.
10. **How far back does Plot import from my connected services?** — Plot imports
    recent items when you connect: 1 week on Free, 1 year on Pro and Team. After
    that, everything syncs in real time, and everything already in Plot stays
    forever.
11. **Do annual plans auto-renew?** — Yes. You can cancel anytime before renewal
    and keep access through the end of your billing period.
12. **Is there an enterprise plan?** — Not yet, but it's on our roadmap. If you
    need SSO, advanced security controls, or custom terms, reach out.

**Removed FAQs:** "Why no per-seat pricing?", the old AI-pricing/BYOK answer,
the old "what's a connection add-on?" (counts-as-a-connection), and the
standalone "How do I add more connections on a Team plan?" (folded into #5).

### 7. Final CTA

Keep "Get started for free" → `/start`.

## Affected files (this spec)

- `apps/site/app/routes/pricing.tsx` — hero, plan card rendering (3 cards),
  connection section (prose + fixed table), automations section, FAQ array, meta.
- `apps/site/app/lib/plans.ts` — drop `core`; update Free/Pro/Team feature lines,
  twist→automation wording and capacity numbers, connection à-la-carte note; keep
  `ADDON_PRICE`; update the header note pointing at the API mirror.
- `apps/site/app/routes/pricing.module.css` — only if the 3-card grid or new
  footnote/badge needs layout adjustment (4→3 columns).

## Out of scope → tracked in Spec B

Everything the backend must do to make these promises real:

- **Capacity connection add-ons for *any* connector** (a $5/mo add-on that
  extends the included pool), distinct from the add-on-required connectors in the
  add-ons design doc.
- **Weighted automation-capacity system**: per-automation multiplier, capacity
  accounting, the +20-slot ($10/mo) pack, and folding AI cost into the weight.
- **Built-in assistant entitlement**: included on all plans, 0 slots, no usage
  limit; removing the per-feature `FREE_AI_LIMITS` patchwork.
- **AI cleanup**: remove token billing, BYOK, model choice, per-feature limits.
- **Drop Core**: `PLAN_LIMITS`, the `plan` enum/value, and migration/grandfather
  of any existing `core` subscribers.
- **Rest of the add-ons build's Plan 4**: the `apps/plot` purchase UX and
  `apps/site/app/routes/upgrade.tsx` checkout/account changes.

## Open questions

- **Connector "Add-on required" label** — confirm the badge text ("Add-on
  required") and that we don't want a coined noun. Current recommendation: badge
  + prose, no new term.
- **"Everything in Free/Pro" cumulative lines** — confirmed; keep.
