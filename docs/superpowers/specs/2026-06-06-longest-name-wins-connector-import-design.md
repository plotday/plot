# Longest-name-wins on connector contact imports

**Date:** 2026-06-06
**Status:** Design approved, pending spec review

## Problem

A contact's display name gets degraded when a second connector imports the same
person with a less complete name.

Concrete case: "Beth Round" `<beth@plot.day>` was imported from Gmail. Adding a
Slack connection, where her display name is just "Beth", overwrote the name down
to "Beth".

### Why it happens today

Names are written from the connector import path (`addContacts` in
`workers/api/src/twist/tools/plot/contacts.ts`) at three sites:

1. **Global `contact.name`** via `upsert_contacts` — **first-touch-only**:
   `name = COALESCE(contact.name, EXCLUDED.name)`. Never overwrites, but also
   never *upgrades*: if "Beth" lands first, a later "Beth Round" is ignored.
2. **Per-user `user_contact.name`** via `upsert_user_contact_name` —
   **last-write-wins** for any non-null observation
   (`name = COALESCE(EXCLUDED.name, user_contact.name) WHERE EXCLUDED.name IS NOT NULL ...`).
   This is the path that overwrote "Beth Round" with "Beth": both are non-null
   and distinct, so the shorter Slack name won.
3. **Source-only (no-email) contacts** — a TS branch in `contacts.ts` that does
   a fill-if-null update on `contact.name`.

Neither path implements "enhance with missing info, keep the more complete name".

## Goal

On the **connector import path only**, names should:

- **Fill** when no name is set yet.
- **Upgrade** to a strictly longer name (longest-wins).
- **Never** be replaced by a shorter or equal-length name.
- **Never** clobber a name a user set explicitly (a future explicit-rename API).

A separate future explicit-rename API must be able to set *any* name and have it
stick — connector imports must not undo it. This design only reserves the
mechanism (`source = 'user'`); the rename API itself is out of scope.

## Heuristic

**Longest name wins**, measured by `length()` of the normalized name.

- Strictly longer incoming name replaces the existing one.
- Ties keep the existing value (no write → no `seq` churn → no needless re-sync).
- NULL/empty incoming never overwrites.

Names are already cleaned by `normalizeName` (strips trailing emails,
`" via <group>"` mailing-list suffixes, wrapping quotes, `"Last, First"` →
`"First Last"`, email-like → undefined) before any length comparison, so junk
fragments don't win on length.

## Scope decisions

- **Apply to both the global name and the per-user name.** The global name is
  *not* dead — `user.actor` uses it as the cross-viewer fallback:
  - Primary contacts (`90-user-schema/34-actor.sql:44`): `COALESCE(uc.name, a.name)`
    — a viewer with no `user_contact.name` override (e.g. someone who only sees
    the contact via a shared thread) falls back to the global name. Without it
    they render "Unknown".
  - Alias / non-primary contacts (`34-actor.sql:84`): use `a.name` directly; no
    per-user override is consulted for alias identities.

  So global stays, but switches from first-touch to longest-wins so non-importing
  viewers also benefit from a fuller name. The historical reason global was made
  first-touch-only (Google-Group DMARC From-rewrites churning the shared name for
  everyone) is independently mitigated: the Gmail connector now suppresses
  rewritten From display-names before they ever reach `addContacts`
  (PR plotday/plot#168).

- **Fix-forward only, no backfill.** Already-degraded names self-heal on the next
  connector sync that observes a longer name (e.g. "Beth" → "Beth Round" on the
  next Gmail sync). Prior observations aren't retained, so a migration would have
  little to recompute from.

- **Avatars unchanged.** No length notion; keep fill-if-null.

## Changes

All three write sites live on the connector import path and get the same
longest-wins rule.

### 1. `upsert_contacts` — global `contact.name`
`libs/db/schema/60-functions/contact_upserts.sql`

Replace the first-touch `name` assignment in `ON CONFLICT ... DO UPDATE SET`:

```sql
name = CASE
  WHEN EXCLUDED.name IS NOT NULL
       AND length(EXCLUDED.name) > length(COALESCE(contact.name, ''))
  THEN EXCLUDED.name
  ELSE contact.name
END,
avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url)  -- unchanged
```

Update the leading comment block (currently documents first-touch behavior).

### 2. `upsert_user_contact_name` — per-user `user_contact.name`
`libs/db/schema/60-functions/contact_upserts.sql`

Connector observations keep writing `source = 'observed'`. Add longest-wins and a
sticky-user-rename guard to the conflict clause:

```sql
INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
    VALUES (p_user_id, p_contact_id, false, 'observed', p_name)
ON CONFLICT (user_id, contact_id)
    DO UPDATE SET name = EXCLUDED.name
    WHERE EXCLUDED.name IS NOT NULL
        AND user_contact.linked = false
        AND user_contact.source IS DISTINCT FROM 'user'   -- sticky explicit rename
        AND (user_contact.name IS NULL
             OR length(EXCLUDED.name) > length(user_contact.name));
```

Note: the future explicit-rename API must NOT call this function. It uses a
separate function (e.g. `set_user_contact_name`) that sets any value and writes
`source = 'user'`. That function is out of scope here; this design only ensures
the connector path honors `source = 'user'`.

### 3. Source-only (no-email) contacts — TS branch
`workers/api/src/twist/tools/plot/contacts.ts` (~lines 238–258)

Change the existing-contact `needsUpdate` condition for name from
"existing name is null" to "incoming normalized name is longer than existing":

```ts
const normalizedName = normalizeName(contact.name);
const nameUpgrades =
  !!normalizedName &&
  normalizedName.length > (existingContact.name?.length ?? 0);
const needsUpdate =
  nameUpgrades || (!existingContact.avatar_url && contact.avatar);

if (needsUpdate) {
  await plot.db.updateTable("contact").set({
    ...(nameUpgrades ? { name: normalizedName } : {}),
    ...((!existingContact.avatar_url && contact.avatar)
      ? { avatar_url: contact.avatar } : {}),
  }).where("id", "=", existingContact.id).execute();
}
```

The new-contact insert path (first touch) is unchanged. Avatar remains fill-if-null.

## Backwards compatibility

- Pure behavioral change in two SQL functions (`CREATE OR REPLACE`) and one TS
  branch. No table/column/type changes, no new columns. Single expand migration.
- `source = 'user'` is a new *value* in the existing `user_contact.source` text
  column; no schema change. Existing rows have `source = 'observed'` (or NULL),
  so the `IS DISTINCT FROM 'user'` guard is a no-op for them — current behavior
  for connector-vs-connector is preserved except for the longest-wins upgrade.
- No client/sync changes: `user.actor` already resolves `COALESCE(uc.name, a.name)`
  per-viewer; the `set_user_contact_updated_at` trigger bumps `seq` so upgrades
  re-emit to clients.

## Testing

**pgTAP** (`libs/db/...` test for `contact_upserts`):
- `upsert_contacts`: longer name upgrades the global name; shorter ignored; tie
  is a no-op (no seq bump); NULL never overwrites; first import fills.
- `upsert_user_contact_name`: longer upgrades; shorter/equal ignored; NULL
  ignored; first-fill on NULL works; a row with `source = 'user'` is never
  changed; `linked = true` rows are never changed.

**vitest** (`workers/api` contacts test):
- Source-only contact: a later, longer observed name upgrades the existing
  contact; a shorter one does not.

## Out of scope

- The explicit user-rename API/UI ("coming soon"). This design reserves
  `source = 'user'` for it but does not implement it.
- Backfilling already-degraded names.
- Avatar quality heuristics.
