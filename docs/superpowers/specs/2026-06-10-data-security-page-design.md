# Data & Security Page — Design

**Date:** 2026-06-10
**Status:** Approved by Kris (full scope)

## Goal

Publish a public Data & Security page at `plot.day/security` that is calm, simple,
and confident — no puffery, no corporate boilerplate — and make the code changes
required so every claim on it is true. Reassure individuals and businesses
evaluating Plot.

## Approved decisions

- **Scope:** Full — page + all hardening items (A–E below).
- **Security contact:** `security@plot.day` (alias exists).
- **Candor line:** Yes — say plainly that we have no SOC 2 report yet.
- **CASA:** Plot passes the annual independent CASA security assessment required
  by Google for Gmail (restricted-scope) access. Claim it on the page.
- **Backups:** Automated Cloud SQL backups confirmed by Kris. Claim
  "backed up automatically every day."
- **Workspace:** Worktree `data-security-page` (DB port 54331).

## Verified facts the page is built on

| Claim | Evidence |
|---|---|
| Local-first; device copy, server sync | architecture; AGENTS.md |
| Prod Postgres = Google Cloud SQL, Toronto (`plot-core:northamerica-northeast2:plot-prod`) | `libs/db/package.json` prod-db-connect |
| API on Cloudflare Workers; Hyperdrive to DB | `workers/api/wrangler.jsonc` |
| Auth via Clerk (JWT verified in-worker); Plot never stores passwords | `workers/api/src/utils/auth.ts` |
| Per-user DB views enforce visibility on every query; team firewall; drafts private | `libs/db/schema/90-user-schema/` |
| Connections use OAuth only; scoped permissions; sandboxed connector runtime with declared capabilities | `workers/api/src/twist/permissions.ts`, containers config |
| Disconnect removes the connection's tokens | `integrations.ts removeAuth` (~:3321) |
| Webhooks signature-verified (Slack HMAC, Clerk/Svix, Google Pub/Sub, Apple JWS) + replay protection; rate limiting everywhere | `workers/api/src/webhook.ts`, `middleware/rate-limit.ts` |
| AI keys + twist secrets AES-256-GCM encrypted | `workers/api/src/utils/encryption.ts`, `secure-options.ts` |
| AI opt-out per user | `user_settings.ai_enabled`; terms |
| AI providers: Anthropic, Google, OpenAI, Cloudflare Workers AI (via AI Gateway); API data not used for training | `workers/api/src/utils/ai-provider.ts`; existing privacy-policy commitment |
| Google Limited Use disclosure already on privacy page | `apps/site/app/routes/privacy.tsx:239-284` |
| Gmail scope = `gmail.modify` (restricted) → Limited Use + CASA apply | `public/connectors/gmail/src/gmail.ts:190` |
| Account deletion: `DELETE /account` cancels Stripe, revokes Apple tokens, 14-day Clerk ban; Clerk `user.deleted` webhook cascades DB delete | `workers/api/src/app/account.ts:810`, `webhook.ts:192` |
| Stripe for payments; card data never on Plot servers | `workers/api` Stripe usage |
| Subprocessors: Cloudflare, Google Cloud, Clerk, Stripe, PostHog, Resend, Anthropic/Google/OpenAI, Unipile (LinkedIn/WhatsApp/Instagram), FCM/APNs | dependency + config inventory |
| Atlassian Personal Data Reporting implemented | `workers/api/src/state/privacy-reporting.ts` |

**Known gaps the page must NOT claim:** 2FA, SOC 2/ISO, self-serve export,
on-device DB encryption (rely on device/OS encryption — say so honestly),
end-to-end encryption.

**Pre-existing baseline failure (not ours):** `workers/api
src/app/sync/thread-unread.test.ts` "read_at record marks the thread read"
fails on a fresh replayed DB (worktree 54331) but passes on the main repo DB.
Environment-dependent, unrelated to this work.

## Hardening changes (each unlocks a page claim)

### A. Vulnerability disclosure channel (small)
- `apps/site/public/.well-known/security.txt` (RFC 9116: `Contact:
  mailto:security@plot.day`, `Expires:` +1y, `Canonical:`, `Policy:
  https://plot.day/security`, `Preferred-Languages: en`).
- "If you find a security issue" section on the page.

### B. Dependency vulnerability monitoring (small)
- `.github/dependabot.yml`: npm (pnpm workspace root), pub (`/apps/plot`),
  github-actions. Weekly, grouped, low PR limit to stay calm.
- Go-live (Kris): enable Dependabot alerts + security updates in repo settings.

### C. Remove vestigial Supabase env (small)
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` appear in `.env.production` (and possibly
  other env templates / `scripts/sync-github-secrets`) but no source code uses
  them. Remove so the published subprocessor list is exactly true.
- Sweep: env templates, `workers/*/package.json` deploy-var lists, `env.ts`
  types, `sync-github-secrets`.

### D. Encrypt connection tokens at rest (moderate)
- Today: OAuth tokens stored plaintext (SuperJSON) in Durable Object storage,
  keyed `auth_token:{provider}:{actorId}` via the integrations tool's Store.
  Cloudflare encrypts DO storage at the infrastructure level; we add an
  application layer.
- Approach: encrypt/decrypt at the **integrations.ts token read/write
  boundary** (helper wrapping `store.set`/`get`/`list` for `auth_token:` keys),
  using the existing AES-256-GCM helpers in `utils/encryption.ts`.
- Envelope format distinguishable from legacy data (e.g. `{ __enc: 1, iv,
  data }`). Read path: envelope → decrypt; legacy plaintext → accept as-is.
  Write path: always encrypt. Legacy tokens become encrypted at next token
  refresh/write. No bulk migration.
- New secret `TOKEN_ENCRYPTION_KEY` (32-byte hex): add to `env.ts` types,
  `.dev.vars` (dev value), `.env.production` (`op://` reference), deploy-var
  list. Go-live (Kris): create 1Password entry + set the Cloudflare secret
  before deploy. **Fallback if unset:** behave as today (plaintext) and log a
  warning — never brick auth on a missing secret. Page copy ships with the
  claim because deploy includes the key.
- Exact call-site inventory happens in the implementation plan (one file,
  ~20 sites).

### E. Automated permanent account deletion (moderate)
- Today: `DELETE /account` ends with an email asking the team to finish
  deletion manually within 14 days.
- Changes:
  1. Migration: `user.deletion_requested_at timestamptz` (nullable). Standard
     workflow (`pnpm gen-migration`, worktree DB, types regen committed).
  2. `DELETE /account` sets it (keeps all existing steps; email copy changes
     from "please complete manual deletion" to "automatic deletion scheduled").
  3. New scheduled task `purge-deleted-accounts` (piggyback existing cron in
     `workers/api`): users with `deletion_requested_at < now() - interval '14
     days'` →
     a. best-effort cleanup of connector access: remove stored auth tokens
        (DO storage for the user's twist instances) and Unipile hosted
        accounts (reuse existing cleanup paths);
     b. delete R2 file objects belonging to the user (inventory exact keying
        during planning);
     c. delete the Clerk user (`clerk.users.deleteUser`) — existing webhook
        cascades the DB delete; if the Clerk user is already gone, delete the
        DB `user` row directly (same cascade).
     d. idempotent + captureException on unexpected errors.
  4. Recovery inside the window stays support-driven (unban + clear flag).
- Page claim unlocked: "after a 14-day recovery window, everything is
  permanently and automatically erased."

## The page

### Plumbing
- New route `apps/site/app/routes/security.tsx`; register in
  `apps/site/app/routes.ts` (public layout, next to privacy/terms).
- Pattern: `Container` + `Title` + `TypographyStylesProvider` (same as
  privacy/terms). "Last updated" line.
- Footer in `apps/site/app/components/public-layout.tsx`: add "Security"
  beside Terms/Privacy.
- `docs/updates.md`: one plain-language bullet at top.

### Voice
Match the site: short sentences, second person, concrete nouns, no
superlatives, one idea per section. Basecamp-style candor; Tailscale-style
"explain the architecture, don't assert trust."

### Sections (draft copy direction — final copy written in execution)
1. **Intro** — Plot connects to the tools where your work happens, so we hold
   data worth protecting. Plainly: where it lives, who can see it, how we keep
   it safe.
2. **Where your data lives** — Local-first: a copy on your device (works
   offline; protected by your device's built-in encryption). Synced to our
   database on Google Cloud SQL in **Toronto, Canada**, backed up automatically
   every day. API on Cloudflare.
3. **Encryption** — TLS for everything in transit. Encrypted at rest by our
   infrastructure providers. Connection tokens and AI keys additionally
   encrypted by us with AES-256 (post-D).
4. **Your connected accounts** — OAuth only; never your passwords. Each
   connection asks only for what it needs; disconnect anytime and its tokens
   are removed. Connectors run sandboxed with declared capabilities. Google
   Limited Use statement (linked) + annual independent CASA assessment.
5. **AI** — Powers only features you can see. Providers (Anthropic, Google,
   OpenAI) don't train on your data; neither do we. Turn it off entirely in
   settings.
6. **Who can see your work** — Only people you've shared with (direct, group,
   or team). Drafts stay yours. Enforced in the database on every query. Plot
   staff don't read your data; the narrow exceptions match the privacy policy.
7. **Deleting your data** — Self-serve from settings; 14-day recovery window;
   then permanent, automatic erasure (post-E).
8. **Payments** — Stripe; card details never touch our servers.
9. **The services we rely on** — Short named subprocessor list with purpose
   (from verified inventory; no Supabase post-C).
10. **If you find a security issue** — security@plot.day + security.txt.
11. **The honest part** (candor) — No SOC 2 report yet; small team; the
    controls above + annual CASA assessment + local-first architecture. Ask us
    anything: security@plot.day.

## Out of scope
- 2FA exposure, SSO/SAML, self-serve data export, on-device DB encryption,
  SOC 2 — not claimed; candor section covers posture.
- Rewriting the privacy policy or terms (link to them instead).
- `docs/features.md` (concurrent uncommitted rewrite in main checkout).

## Go-live checklist for Kris (after merge)
1. Create `op://Production/…/TOKEN_ENCRYPTION_KEY` and set the Cloudflare
   secret for workers/api before deploying D.
2. Enable Dependabot alerts + security updates in GitHub repo settings.
3. Deploy migration (E) with normal expand flow.
4. Confirm security@plot.day deliverability (alias already created).

## Verification
- `pnpm lint` in apps/site, workers/api; repo `db:lint` after migration.
- workers/api vitest suite (baseline: 428 pass, 1 pre-existing env-dependent
  failure noted above).
- New tests: token-encryption round-trip + legacy fallback; purge job
  (eligible/ineligible users, Clerk-already-deleted path); `DELETE /account`
  sets the flag.
- Site: build + visually verify `/security`, footer link, and
  `/.well-known/security.txt` locally.
