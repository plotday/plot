# Connector access copy — design

**Date:** 2026-06-14
**Status:** Design (awaiting review)

## Problem

When a user authorizes a connection, we should tell them — in plain language —
what access they are granting the external service. Today this copy exists only
for OAuth connectors, via `ScopeConfig.description` (a bullet list rendered above
the Connect button), and only **google-calendar** actually populates it. Every
other connector shows no explanation:

- 14 OAuth connectors declare `scopes` as a flat `string[]` with no copy.
- Slack uses a `ScopeConfig` but only describes its one optional emoji toggle —
  the required scopes have no copy.
- 5 credential connectors (API key / CalDAV) have no scope screen at all; their
  `Options` fields carry per-field `helpText` ("where to get the key") but no
  "what Plot accesses" summary.
- 3 private Unipile connectors (linkedin, instagram, whatsapp) have neither
  scopes nor an Options screen.

The mechanism (OAuth, API key, Unipile) is irrelevant to the user — in every
case Plot is reaching into an external account and they deserve to know what it
can read and write.

## Goal

A single, mechanism-agnostic way for a connector to declare "what access you're
granting", shown consistently on every connect screen, with accurate copy for
all connectors (excluding the supporting `google-contacts` connector and the
not-yet-implemented `notion`).

## Decisions (from brainstorming)

1. **Coverage:** every connector that touches an external service — OAuth,
   credential, and Unipile.
2. **One SDK field, named `access`:** `readonly access?: string[]` on the
   `Connector` base. Not per-mechanism (`Options.description` was rejected — the
   field must read the same regardless of auth type).
3. **Copy describes the granted scope,** not just what Plot does today. Where an
   OAuth scope (or API key) grants two-way access we intend to use, the copy
   says so (e.g. Asana's full scope → "Creates and updates tasks…"), even if a
   given write-back path isn't shipped yet. The bullets are **justifications for
   what Plot accesses** (and, for OAuth, a preview of what the next consent
   screen will request) — they need not map one-to-one onto scope strings. Where
   a scope is broader than what Plot uses because the provider offers nothing
   narrower (e.g. Drive has no comments-only scope), the copy says so plainly and
   names the limited use, rather than enumerating the scope's full capability.
4. **Skip `google-contacts`:** it is a supporting connector whose scopes are
   merged into Gmail/Drive/Calendar via `Integrations.MergeScopes`. Those
   connectors describe the contact access in their own bullets, so a standalone
   `access` block would be redundant.
5. **Skip `notion`:** no source in this checkout (compiled `dist/` only).

## SDK change

In `public/twister/src/connector.ts`:

- Add `readonly access?: string[]` to the `Connector` base class.
- **Remove `ScopeConfig.description`.** Only google-calendar used it; its bullets
  move to `connector.access`. `ScopeConfig` keeps `required` (scope strings) and
  `optional` (toggle groups with their own labels/descriptions) — the genuinely
  OAuth-specific parts.
- Changeset: `minor` (adds `Connector.access`, removes `ScopeConfig.description`).

## Rendering — two paths, one concept

`access` is declared once on the connector. Internally it reaches the two
existing connect-screen variants through the two data paths the codebase already
has. The user sees the same bullet list either way.

### Path A — provider-based connectors (all OAuth + the 3 Unipile)

These already flow: connector → `twist/factory.ts` `ProviderDeclaration` →
`/auth` + `getIntegrationData` → GET `/integrations` → Flutter `TwistProvider`.

- The factory reads `connector.access` (instead of the removed
  `scopeConfig.description`) into the provider declaration.
- Flutter `TwistProvider` exposes `access` and renders it where it renders the
  current `description` bullets.
- Unipile connectors declare a `provider` (with empty scopes), so they ride this
  path for free.

**Backwards compatibility:** the GET `/integrations` payload currently carries
`description` for this list. The server will emit `access` **and keep emitting
`description`** for a transition; Flutter prefers `access` and falls back to
`description`. (Only google-calendar populates either today, so risk is low, but
this keeps old native clients working against a new server — per the finalize
backwards-compat rule.) Exact dual-emit details belong in the implementation
plan.

### Path B — credential connectors (attio, apple-calendar, fellow, granola, posthog)

These have no `provider`; they surface to the client via `optionsSchema` /
`optionsConfig` / `keyOption` on the connection model (the no-provider connect
sheet). `connector.access` is plumbed onto that same model (alongside
`optionsSchema`) and rendered as a bullet list above the credential fields. This
is a new field, so there's no backwards-compat concern on this path.

## Copy

Bullets follow google-calendar's established voice: second person, present tense,
"Reads/Writes your X to do Y". Granted-scope framing per decision 3.

### OAuth connectors

**gmail** (`gmail.modify` + contacts)
- Reads your email so Plot can turn messages into threads and tasks
- Sends replies, creates drafts, and updates labels and read state from Plot
- Reads your contacts to recognise senders by name and photo

**google-drive** (`drive` + contacts)
- Reads your files to bring documents into Plot
- Adds the comments and replies you write in Plot. Google has no comments-only permission, so Plot must request full Drive access — but commenting is the only change it makes
- Reads your contacts to show who shared or commented

**google-chat** (spaces read/create, messages, memberships, read-state + contacts)
- Reads messages in the spaces you sync
- Sends messages and replies you write in Plot, and can start new spaces
- Reads your contacts to show who's in each conversation

**google-tasks** (`tasks`)
- Reads and updates your Google Tasks so they stay in sync with Plot
- Creates and completes tasks you change in Plot

**outlook-mail** (`mail.readwrite`, `mail.send` + people/contacts)
- Reads your email so Plot can turn messages into threads and tasks
- Sends replies, creates drafts, and updates messages from Plot
- Reads your contacts to recognise senders by name

**outlook-calendar** (`calendars.readwrite`)
- Reads your events to add them to your agenda
- Writes your event RSVPs

**ms-teams** (channels read, ChannelMessage read/send, Chat read/readwrite/create, ChatMessage send, User read)
- Reads your Teams channels and chats to bring conversations into Plot
- Sends messages and replies you write in Plot, and can start new chats
- Reads your team and user profiles to show who's who

**linear** (`read`, `write`, `admin`)
- Reads your issues, projects, and comments
- Creates and updates issues and posts comments you make in Plot
- Keeps Plot up to date as issues change in Linear

**jira** (`read:jira-work`, `write:jira-work`, `read:jira-user`, `manage:jira-webhook`)
- Reads your issues, projects, and users
- Creates and updates issues and posts comments you make in Plot
- Keeps Plot up to date as issues change in Jira

**asana** (`default` — full read/write)
- Reads your tasks, projects, and comments
- Creates and updates tasks and posts comments you make in Plot
- Keeps Plot up to date as tasks change in Asana

**todoist** (`data:read_write`)
- Reads and updates your tasks and projects so they stay in sync with Plot
- Creates and completes tasks you change in Plot

**airtable** (schema read, records read/write, webhook manage, email read)
- Reads your bases and their records
- Updates records you change in Plot
- Keeps Plot up to date as records change in Airtable

**github** (`repo`)
- Reads your repositories' issues and pull requests
- Posts comments and updates you make in Plot
- Keeps Plot up to date as issues and pull requests change in GitHub

**slack** (`ScopeConfig` — add `access`; keep the existing optional emoji toggle)
- Reads messages in the channels and DMs you sync
- Sends messages and replies you write in Plot
- Adds and removes emoji reactions you make in Plot

**google-calendar** (migrate `ScopeConfig.description` → `access`; keep optional toggles)
- Reads your events to add them to your agenda
- Writes your event RSVPs

### Unipile connectors (private)

**linkedin**
- Reads your LinkedIn messages and conversations
- Sends messages and replies you write in Plot

**instagram**
- Reads your Instagram direct messages
- Sends replies you write in Plot

**whatsapp**
- Reads your WhatsApp messages
- Sends replies you write in Plot

### Credential connectors

**attio** (access token)
- Reads your records — people, companies, and deals
- Updates records and adds notes you make in Plot

**apple-calendar** (Apple ID + app-specific password; CalDAV read + RSVP write)
- Reads your iCloud calendar events to add them to your agenda
- Writes your event RSVPs

**fellow** (API key)
- Reads your meeting notes to attach them to the right events in Plot

**granola** (API key)
- Reads your meeting notes and transcripts to attach them to the right events in Plot

**posthog** (API key + project)
- Reads the people from the project you connect

## Testing

- Twister builds clean; changeset validates (`cd public && pnpm validate-changesets`).
- `pnpm lint` in `workers/api` and each touched connector package.
- Flutter `analyze` clean for the touched `twist_api.dart` / connect-screen widgets.
- Manual: connect screen for one OAuth connector, one credential connector, and
  one Unipile connector shows the `access` bullets. (Run-app verification, noting
  OAuth consent screens need a real account.)

## Finalization

- Public submodule PR (twister `Connector.access` + `ScopeConfig.description`
  removal + all `public/connectors/*` copy) with a changeset; merge before the
  core pointer bump.
- Private connectors (`connectors/linkedin|instagram|whatsapp`) and core wiring
  (`workers/api`, `apps/plot`) in the core repo.
- `docs/updates.md`: a short user-facing note that connect screens now explain
  what access each connection grants.

## Out of scope

- `google-contacts` standalone copy (decision 4).
- `notion` (decision 5; no source).
- Reworking the optional-scope toggle mechanism — `ScopeConfig.optional` is
  unchanged.
- Incremental authorization / per-scope consent flows.
