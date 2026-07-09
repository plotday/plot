# Slack Marketplace — Eligibility Review & Decision Doc

_Review of Plot's Slack integration against the
[Slack Marketplace App Guidelines & Requirements](https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements/),
done before a planned submission (motivation: lift Slack's 1-rpm non-Marketplace
rate limit — see `docs/slack-gaps.md` §7)._

## TL;DR

The **structural** blockers below are not fixable by tidying code — they're a
function of what the integration _is_ today (a per-user, user-token,
read-mostly mirror of Slack with no in-Slack surface). Submitting as-is is very
likely to be rejected. This doc records the blockers so the **Marketplace
strategy** decision can be made deliberately. Separately, the code-addressable
compliance/security gaps found in the same review **have been fixed** (see
"Fixed in this pass"); those were worth doing regardless of the strategy call.

---

## Structural blockers (decision required)

Three items on Slack's **"Apps Unsuitable for Marketplace"** list apply
directly. Our own `docs/slack-gaps.md` opens by calling Plot "a read-mostly
mirror of Slack" and repeatedly frames the work as "Plot as a Slack client" —
which is precisely the shape these rules exclude.

| # | Slack rule (verbatim) | Why Plot triggers it |
|---|---|---|
| 1 | Apps that **"export or backup message data"** | We pull full channel/DM/thread **content** into Plot's store and render it in an external app. |
| 2 | Apps that **"lack functionality within Slack itself"** | We have **no** in-Slack surface: no bot user, Home Tab, slash command, shortcut, or Block Kit UI. Every feature lives in the external Plot app. |
| 3 | Apps that **"replicate Slack client functionality, or are third-party Slack clients"** | We read channels/DMs/threads, reply, react, star, and compose — client behavior. |

**Scope profile compounds this.** We request four `*:history` scopes on **user
tokens** (`channels:history`, `groups:history`, `im:history`, `mpim:history`).
The guidelines say _don't_ use broad `*:history` "without a justified use case"
and _don't_ "use user token scopes unnecessarily." This is the exact profile
Slack rate-limited (May 2025) for non-Marketplace apps — so **Marketplace
approval is unlikely to be the lever that lifts that rate limit** for an app of
this shape. Worth confirming directly with Slack before betting the roadmap on
it.

### Realistic paths (not decided here)

1. **Re-architect for eligibility.** Add genuine in-Slack functionality — a bot
   user with a Home Tab, a slash command, and/or shortcuts, plus Block Kit
   rendering — and reframe away from "client/mirror." The in-Slack pieces are
   the same items `docs/slack-gaps.md` Tier 3 rates as multi-week. This is the
   only path that plausibly makes the app _listable_.
2. **Pursue rate-limit relief off-Marketplace.** If the sole goal is the 1-rpm
   limit, Marketplace is not the only lever and probably doesn't fit this app
   shape — engage Slack developer support about the actual mechanism.
3. **Submit as-is and let review adjudicate.** Fastest to attempt; highest
   rejection risk. The fixes below are prerequisites either way.

---

## Fixed in this pass (code-addressable)

These shipped alongside this doc (connector changes are a separate public-repo
PR; server/site changes are in the main repo).

- **`files:write` scope declared** (`public/connectors/slack/src/slack.ts`).
  Both link types advertise `supportsFileAttachments` and `onNoteCreated`
  uploads via `files.getUploadURLExternal`/`completeUploadExternal`, but the
  scope was undeclared — uploads failed with `missing_scope` and the attachment
  was silently dropped. (`docs/slack-gaps.md` §8, which called upload "unbuilt,"
  is stale.) **Re-auth note:** existing connections must reconnect to grant the
  new scope; the upload path already degrades gracefully until then.
- **Token revocation on disconnect** (`workers/api/src/provider.ts` +
  `twist/tools/integrations.ts`). Satisfies Slack security: "Revoke tokens when
  the app is discontinued." Implemented at the true connection-removal seam
  (`Integrations.removeAuth`, via a new provider-config `revokeToken` →
  `auth.revoke`), **not** per-channel `onChannelDisabled` — a single channel
  toggle fires `onChannelDisabled` but not `removeAuth`, so there are no
  false-positive revocations. Best-effort (a failed upstream revoke logs a warn,
  never blocks disconnect).
- **Slack-side deauthorization handled** (`slack.ts onSlackWebhook` +
  `network.ts`). `app_uninstalled` (admin removes Plot, team-wide) and
  `tokens_revoked` (user revokes, gated on this connection's own
  `authed_user_id` so it never tears down other users on the team) now flag the
  connection for re-auth immediately, instead of only lazily on the next failing
  API call.
- **Scope JSDoc corrected** to match the authoritative `SCOPES` array (it had
  omitted `im:write`, `mpim:write`, `reactions:*`), with a one-line
  justification per scope.
- **Privacy policy** (`apps/site/app/routes/privacy.tsx`) now names Slack: the
  data collected, retention, deletion on disconnect, and an explicit
  no-AI-training assurance covering connection data (previously Google-scoped
  only).
- **AI disclosure** (`apps/site/app/routes/security.tsx`): inaccurate-output
  disclaimer + inference-only / no-training statement, so a reviewer isn't
  misled by the code's "training set" terminology (which means _a user's own
  labeled examples used at inference time_ for personalized classification — not
  model training).

### Already compliant before this pass

Signing-secret request verification with 5-min replay protection
(`webhook.ts`), OAuth `state` CSRF (single-use, 1-hour expiry), TLS ≥1.2 via
Cloudflare, user-attributed actions (user-token model, no bot), inference-only
AI with no training on Slack data.

---

## Per-scope justification

For the Security Review "principle of least privilege" section. Every scope
below backs a shipped, user-visible feature.

| Scope | Token | Feature it backs |
|---|---|---|
| `channels:read` | user | List public channels the user can enable for sync |
| `channels:history` | user | Read messages in synced public channels |
| `groups:read` | user | List private channels the user is in |
| `groups:history` | user | Read messages in synced private channels |
| `im:history` | user | Read the user's direct messages |
| `im:write` | user | Open a DM to compose a new direct message from Plot |
| `mpim:history` | user | Read the user's group direct messages |
| `mpim:write` | user | Open a group DM to compose from Plot |
| `chat:write` | user | Post the replies/messages the user writes in Plot |
| `files:write` | user | Upload file attachments the user adds to a message |
| `users:read` | user | Resolve message authors/reactors to names + avatars |
| `users:read.email` | user | Match Slack users to Plot contacts by email |
| `reactions:read` | user | Read reactions during sync; receive reaction events |
| `reactions:write` | user | Round-trip emoji reactions added/removed in Plot |
| `stars:read` | user | Backfill the user's saved (starred) items as to-dos |
| `stars:write` | user | Add/remove stars when the user completes a to-do |
| `emoji:read` (optional) | user | Render the workspace's custom emoji in reactions |

**The `*:history` scopes are the review risk** (see structural blocker above) —
they read message content and are user-token, exactly what the guidelines
scrutinize. Any re-architecture should minimize them (e.g. a bot-token,
event-driven model) if pursuing a listing.

---

## Remaining follow-ups (not code)

- **Enable Events API subscriptions** for `app_uninstalled` and `tokens_revoked`
  in the Slack app config — the handlers above only fire once Slack delivers
  these events.
- **Direct Install:** the admin `/slack/install` route already 302-redirects to
  a fully-qualified `slack.com/oauth/v2/authorize` URL (meets the listing
  requirement); the per-user in-app connect returns the authorize URL as JSON
  for the native client to open (fine, but not the "Direct Install" field).
- **Public Slack landing page** with an "Add to Slack" button + Slack-context
  screenshots + post-install success + privacy link. Today the install button
  lives only on the admin-install page; the general home page has Slack copy but
  no Slack landing. Needs product screenshots/copy — team-owned.
- **Support:** `help/contact` exists but is mailto-only; the guidelines accept
  email, and require a ≤2-business-day response commitment (operational).
- **Operational gates:** ≥5 active workspaces, ≥1 app collaborator, accept the
  Marketplace/API agreements, app fully tested and out of beta.
