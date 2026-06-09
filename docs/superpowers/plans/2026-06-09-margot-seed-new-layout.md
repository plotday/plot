# Margot Seed for New Layout — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `libs/db/seeds/margot.yaml` and extend `libs/db/seeds/generate-seed.ts` so the seed produces screenshot-quality data for the current product (flat focuses, sectioned feed, NewThreadPage with contacts/groups/channels).

**Architecture:** The generator turns a declarative YAML into one idempotent SQL transaction. We add three capabilities — focus `icon`, a top-level `groups:` section, and per-source `channels:` — by extending `types.ts`, `validate()`, `generateSQL()`, and the entity-processing helpers, then rewrite the YAML to use them. No DB migration: `priority.icon`, `group`/`group_member`/`group_admin`, and `channel` already exist.

**Tech Stack:** TypeScript (tsx), `yaml` parser, raw PostgreSQL string emission, `pnpm gen-seed`.

**Verification commands (used throughout):**
- Generate to stdout: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/db gen-seed libs/db/seeds/margot.yaml > /tmp/margot.sql`
- Type-check the generator: `cd /Users/kris.braun/code/plot/libs/db && pnpm exec tsc --noEmit -p tsconfig.json` (if no tsconfig for seeds, use `pnpm exec tsc --noEmit seeds/generate-seed.ts seeds/types.ts --module nodenext --moduleResolution nodenext --target es2022 --skipLibCheck`)
- Apply locally: `cd /Users/kris.braun/code/plot && pnpm --filter @plotday/db gen-seed --apply libs/db/seeds/margot.yaml`

> The local DB must be running (`pnpm --filter @plotday/db start`) and `$DATABASE_URL` valid. This is the main repo (port 54322), not a worktree.

---

## Reference facts (verified against the codebase)

- **`priority` table** has columns `icon text` (curated `kFocusIcons` key) and `color` (but seed colour is written via `priority_setting` key `'color'`, not the column). Icon is a real column on `priority`.
- **`kFocusIcons` keys** (`apps/plot/lib/widget/icon.dart`): `user, family, briefcase, house, code, receipt, bullhorn, handshake, rocket, building, lightbulb, heart, flask, paintbrush, dumbbell, seedling, balloons, music, plane, mountain, globe, billboard`.
- **`group`**: `id uuid`, `name text`, `type group_type DEFAULT 'private'`, `privacy group_privacy DEFAULT 'open'`, `created_by uuid`. `group_type` ∈ {`public,team,private,announce`}; `group_privacy` ∈ {`open,private`}.
- **`user.group` surfacing**: a `type='private'` group is visible to a user who is its admin (`group_admin`) OR a linked member. We make Margot the admin of every seed group → it surfaces.
- **`group_member(group_id, contact_id)`**, **`group_admin(group_id, user_id)`**. Both `ON DELETE CASCADE` from `group`.
- **`channel`**: `id bigint identity`, `twist_instance_id uuid`, `channel_id text`, `title text`, `enabled bool`, `link_types jsonb` (nullable), `default_priority_id uuid` (nullable). A channel becomes a NewThreadPage compose target only when its `link_types` JSON contains a `compose` block (`connection_targets.dart`).
- **`processSource`** creates the source's `twist_instance` (UUID known before the `DO` block as `twistInstanceId`) and a personal-fallback `twist` with `archived_at = now()`. An archived twist is filtered out of "Available connections". For a channel-bearing source (Slack) we drop the archive so it's a live connection.
- **`processPriority` currently ignores `shared_with`** on priorities (the param is unused). We do NOT rely on priority sharing; collaboration signals come from thread `shared_with` and groups.
- **Reseed cleanup**: the top of `generateSQL()` already DELETEs the user's `thread`/`priority`/`priority_setting` and archives personal twists. We add group + channel cleanup there.

---

## File Structure

- **Modify** `libs/db/seeds/types.ts` — add `icon` to `Priority`; add `SeedGroup`, `SeedChannel`; add `groups` to `SeedData`; add `channels` to `SeedSource`; add `GeneratedGroup`/`GeneratedGroupMember`/`GeneratedGroupAdmin`/`GeneratedChannel`; add `kFocusIcons` constant for soft validation.
- **Modify** `libs/db/seeds/generate-seed.ts` — icon emit in priority insert; group validation + processing + SQL; channel processing + SQL (inside/after `processSource`); cleanup lines; summary counts.
- **Rewrite** `libs/db/seeds/margot.yaml` — flat focuses, groups, channels, sectioned threads.
- **Modify** `libs/db/seeds/spec.md` and `libs/db/seeds/README.md` — document `icon`, `groups`, `channels`.

---

## Part A — Generator changes

### Task A1: Add focus `icon` support

**Files:**
- Modify: `libs/db/seeds/types.ts` (the `Priority` interface ~L56, `GeneratedPriority` ~L229)
- Modify: `libs/db/seeds/generate-seed.ts` (`processPriority` ~L1767, priority INSERT ~L1476)

- [ ] **Step 1: Add `icon` + `kFocusIcons` to types.ts**

In `Priority` interface, after `title: string;` add:
```typescript
  icon?: string; // Curated kFocusIcons key (e.g. "rocket"). Written to priority.icon.
```
In `GeneratedPriority`, after `title: string;` add:
```typescript
  icon: string | null;
```
At the end of the tag-definitions block (after `TAG_IDS`), add the soft-validation list:
```typescript
// Curated focus-icon keys. Mirrors kFocusIcons in
// apps/plot/lib/widget/icon.dart. Used for a soft (warn-only) validation so
// the seed never hard-fails when the app's icon set drifts.
export const FOCUS_ICONS = [
  "user", "family", "briefcase", "house", "code", "receipt", "bullhorn",
  "handshake", "rocket", "building", "lightbulb", "heart", "flask",
  "paintbrush", "dumbbell", "seedling", "balloons", "music", "plane",
  "mountain", "globe", "billboard",
] as const;
```

- [ ] **Step 2: Emit `icon` in processPriority**

In `generate-seed.ts` `processPriority`, change the `outPriorities.push({...})` to include `icon`:
```typescript
  outPriorities.push({
    id,
    created_by: userId,
    title: priority.title,
    icon: priority.icon ?? null,
    path,
    archived_at: priority.archived_at
      ? parseDateOffset(baseDate, priority.archived_at).toISOString()
      : null,
  });
```

- [ ] **Step 3: Add `icon` to the priority INSERT**

In `generateSQL()` priority emit (~L1476), change the column list and the per-row value:
```typescript
    lines.push(
      "INSERT INTO priority (id, created_by, title, icon, path, archived_at, created_at, updated_at)"
    );
    lines.push("VALUES");
    for (let i = 0; i < priorities.length; i++) {
      const p = priorities[i];
      const comma = i < priorities.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(p.id)}, ${sqlString(p.created_by)}, ${sqlString(
          p.title
        )}, ${sqlString(p.icon)}, ${sqlString(p.path)}, ${sqlString(
          p.archived_at
        )}, NOW(), NOW())${comma}`
      );
    }
```

- [ ] **Step 4: Soft-validate icon in validatePriority**

Add the import to the `import { ALL_TAGS, TAG_IDS } from "./types.js";` line → `import { ALL_TAGS, FOCUS_ICONS, TAG_IDS } from "./types.js";`. In `validatePriority`, after the title check add:
```typescript
  if (priority.icon && !FOCUS_ICONS.includes(priority.icon as (typeof FOCUS_ICONS)[number])) {
    console.error(
      `⚠ ${path}.icon: "${priority.icon}" is not a known kFocusIcons key (continuing; the app may render a default).`
    );
  }
```
(This is a warn, not an `addError`, so unknown keys don't fail generation.)

- [ ] **Step 5: Type-check and smoke-generate**

Run: `cd /Users/kris.braun/code/plot/libs/db && pnpm exec tsc --noEmit seeds/generate-seed.ts seeds/types.ts --module nodenext --moduleResolution nodenext --target es2022 --skipLibCheck`
Expected: no errors.
Then temporarily add `icon: rocket` to one priority in the existing `margot.yaml`, run the stdout generate command, and `grep "INSERT INTO priority"` plus the first VALUES row in `/tmp/margot.sql` to confirm the icon column appears. Revert the temp edit.

- [ ] **Step 6: Commit**
```bash
git add libs/db/seeds/types.ts libs/db/seeds/generate-seed.ts
git commit -m "seed: support focus icon on priorities"
```

---

### Task A2: Add `groups:` section

**Files:**
- Modify: `libs/db/seeds/types.ts`
- Modify: `libs/db/seeds/generate-seed.ts`

- [ ] **Step 1: Add group types to types.ts**

Add to `SeedData` after `priority_blocks?:`:
```typescript
  groups?: SeedGroup[];
```
Add new interfaces near the bottom of the "Twists"/"Threads" section group:
```typescript
// ============================================================================
// Groups (reusable contact sets for the new-thread picker)
// ============================================================================

export interface SeedGroup {
  ref: string;
  name: string;
  privacy?: "open" | "private"; // default "open"
  members: string[]; // contact refs (the user is admin automatically)
  admins?: string[]; // extra user refs to make admins (rarely needed)
}

export interface GeneratedGroup {
  id: string; // UUID
  name: string;
  privacy: string;
  created_by: string; // UUID (seed user)
}

export interface GeneratedGroupMember {
  group_id: string;
  contact_id: string;
}

export interface GeneratedGroupAdmin {
  group_id: string;
  user_id: string;
}
```

- [ ] **Step 2: Validate groups in validate()**

In `validate()`, after the threads validation block (before `return errors;`), add:
```typescript
  // Validate groups
  if (data.groups) {
    const groupRefs = new Set<string>();
    for (let i = 0; i < data.groups.length; i++) {
      const group = data.groups[i];
      const path = `groups[${i}]`;
      if (!group.ref) {
        addError(`${path}.ref`, "Missing ref");
      } else if (groupRefs.has(group.ref)) {
        addError(`${path}.ref`, `Duplicate ref: ${group.ref}`);
      } else {
        groupRefs.add(group.ref);
      }
      if (!group.name) addError(`${path}.name`, "Missing name");
      if (!group.members || group.members.length === 0) {
        addError(`${path}.members`, "Group must have at least one member");
      } else {
        for (const ref of group.members) {
          if (ref !== "user" && !contactRefs.has(ref)) {
            addError(`${path}.members`, `Unknown contact ref: ${ref}`);
          }
        }
      }
      if (group.privacy && group.privacy !== "open" && group.privacy !== "private") {
        addError(`${path}.privacy`, `Invalid privacy: ${group.privacy} (open|private)`);
      }
    }
  }
```

- [ ] **Step 3: Add group cleanup to the SQL header**

In `generateSQL()`, in the cleanup block (after the `UPDATE twist ... personal` line, before the empty `lines.push("")`), add:
```typescript
  // Groups created by prior seed runs (cascades group_member/group_admin).
  lines.push(`DELETE FROM "group" WHERE created_by = ${sqlString(userId)};`);
```

- [ ] **Step 4: Process groups into generated arrays**

In `generateSQL()`, add the arrays near the other `Generated*` arrays:
```typescript
  const groups: GeneratedGroup[] = [];
  const groupMembers: GeneratedGroupMember[] = [];
  const groupAdmins: GeneratedGroupAdmin[] = [];
```
Add the import of the new types to the top `import type { ... }` block: `GeneratedGroup, GeneratedGroupMember, GeneratedGroupAdmin`.
After the priority-processing loop (after the `data.priorities` block, ~L1311), add:
```typescript
  // Process groups (reusable contact sets for the new-thread picker)
  if (data.groups) {
    for (const group of data.groups) {
      const groupId = generateUUID();
      groups.push({
        id: groupId,
        name: group.name,
        privacy: group.privacy ?? "open",
        created_by: userId,
      });
      // Seed user is always an admin so user.group surfaces a private group.
      groupAdmins.push({ group_id: groupId, user_id: userId });
      for (const ref of group.members) {
        const cid = contactIdMap[ref];
        if (cid) groupMembers.push({ group_id: groupId, contact_id: cid });
      }
    }
  }
```
> Note: `contactIdMap` is populated by the contacts loop which runs *before* priorities, so member refs resolve here.

- [ ] **Step 5: Emit group SQL**

In `generateSQL()`, after the priority-settings emit block and before the sources emit (`if (sourceSQLLines.length > 0)`), add:
```typescript
  // Groups
  if (groups.length > 0) {
    lines.push("-- Groups");
    lines.push('INSERT INTO "group" (id, name, type, privacy, created_by, created_at, updated_at)');
    lines.push("VALUES");
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const comma = i < groups.length - 1 ? "," : ";";
      lines.push(
        `  (${sqlString(g.id)}, ${sqlString(g.name)}, 'private', ${sqlString(g.privacy)}, ${sqlString(g.created_by)}, NOW(), NOW())${comma}`
      );
    }
    lines.push("");

    if (groupMembers.length > 0) {
      lines.push("-- Group members");
      lines.push("INSERT INTO group_member (group_id, contact_id, created_at, updated_at) VALUES");
      for (let i = 0; i < groupMembers.length; i++) {
        const gm = groupMembers[i];
        const comma = i < groupMembers.length - 1 ? "," : ";";
        lines.push(`  (${sqlString(gm.group_id)}, ${sqlString(gm.contact_id)}, NOW(), NOW())${comma}`);
      }
      lines.push("");
    }

    lines.push("-- Group admins (seed user)");
    lines.push("INSERT INTO group_admin (group_id, user_id, created_at) VALUES");
    for (let i = 0; i < groupAdmins.length; i++) {
      const ga = groupAdmins[i];
      const comma = i < groupAdmins.length - 1 ? "," : ";";
      lines.push(`  (${sqlString(ga.group_id)}, ${sqlString(ga.user_id)}, NOW())${comma}`);
    }
    lines.push("");
  }
```
> `type` is hard-coded `'private'` so admin-based surfacing applies (see Reference facts). `privacy` carries the YAML value (governs roster visibility; Margot is admin so she always sees it).

- [ ] **Step 6: Add group count to the apply summary (optional polish)**

In `applySQL()` summary, after `twistCount`, add:
```typescript
        const groupCount = data.groups?.length || 0;
        if (groupCount > 0) {
          console.error(`  ${groupCount} group(s)`);
        }
```

- [ ] **Step 7: Type-check, generate, inspect**

Add a temporary `groups:` block with one group to `margot.yaml` referencing two existing contacts, run the stdout generate, and `grep -A4 'INSERT INTO "group"'` `/tmp/margot.sql` to confirm group + members + admin rows. Run tsc. Revert temp edit.

- [ ] **Step 8: Commit**
```bash
git add libs/db/seeds/types.ts libs/db/seeds/generate-seed.ts
git commit -m "seed: support groups section (group/group_member/group_admin)"
```

---

### Task A3: Add per-source `channels:`

**Files:**
- Modify: `libs/db/seeds/types.ts`
- Modify: `libs/db/seeds/generate-seed.ts` (`processSource` ~L1804, cleanup block, SeedSource)

- [ ] **Step 1: Add channel types to types.ts**

Add to `SeedSource` (after `link_types: SeedLinkType[];`):
```typescript
  channels?: SeedChannel[]; // Enabled connection channels (e.g. Slack channels)
```
Add new interfaces after `SeedLinkType`:
```typescript
export interface SeedChannel {
  channel_id: string; // Provider channel id (e.g. "C04general")
  title: string; // Display title (e.g. "#general")
  enabled?: boolean; // default true
  link_types?: unknown; // Optional override; defaults to a Slack-style compose link type
}

export interface GeneratedChannel {
  twist_instance_id: string;
  channel_id: string;
  title: string;
  enabled: boolean;
  link_types: string; // JSON string
}
```

- [ ] **Step 2: Channel cleanup in the SQL header**

In `generateSQL()` cleanup block (next to the group DELETE from A2), add:
```typescript
  // Channels from prior seed runs (point at to-be-archived twist_instances).
  lines.push(
    `DELETE FROM channel WHERE twist_instance_id IN (SELECT id FROM twist_instance WHERE owner_id = ${sqlString(userId)});`
  );
```

- [ ] **Step 3: Emit channels + keep channel-bearing source live, in processSource**

In `processSource`, the personal-fallback twist is currently created with `archived_at = now()`. Make a channel-bearing source a live connection by selecting the archive expression conditionally, and emit channel rows after the `DO` block. Replace the `VALUES (gen_random_uuid(), ... now())` personal-insert line and append channel emission. Concretely:

Change the personal-twist INSERT value line from `..., now())` to use a computed archive literal:
```typescript
  const hasChannels = !!(source.channels && source.channels.length > 0);
  const archiveLiteral = hasChannels ? "NULL" : "now()";
  outLines.push(`    INSERT INTO twist (twist_package_id, user_id, environment, name, version, is_source, permissions, logo_url, logo_url_dark, archived_at)`);
  outLines.push(
    `    VALUES (gen_random_uuid(), ${sqlString(userId)}, 'personal', ${sqlString(source.name)}, '0.0.0', true, ${sqlString(permissions)}::jsonb, ${sqlString(source.logo ?? null)}, ${sqlString(source.logo_dark ?? null)}, ${archiveLiteral})`
  );
```
(Leave the rest of the `DO` block unchanged.)

After the `outLines.push(\`END $$;\`);` line, append channel INSERTs:
```typescript
  if (source.channels && source.channels.length > 0) {
    const defaultLinkTypes = JSON.stringify([
      {
        type: "thread",
        label: "Thread",
        noteLabel: "Message",
        sharingModel: "channel",
        logo: source.logo ?? "https://api.iconify.design/logos/slack-icon.svg",
        compose: { targets: "channels" },
      },
    ]);
    outLines.push(
      "  INSERT INTO channel (twist_instance_id, channel_id, title, enabled, link_types, created_at, updated_at) VALUES"
    );
    const rows: string[] = [];
    for (const ch of source.channels) {
      const lt = ch.link_types ? JSON.stringify(ch.link_types) : defaultLinkTypes;
      rows.push(
        `    (${sqlString(twistInstanceId)}, ${sqlString(ch.channel_id)}, ${sqlString(ch.title)}, ${ch.enabled ?? true}, ${sqlString(lt)}::jsonb, NOW(), NOW())`
      );
    }
    outLines.push(rows.join(",\n") + ";");
  }
```
> `twistInstanceId` is in scope (declared at the top of `processSource`). These channel rows reference it directly because the `twist_instance` is inserted with that exact UUID inside the `DO` block above.

Add `GeneratedChannel` to the type import only if you reference the type; the inline emission above does not require it, so it is optional. (Skip the import to avoid an unused-type error.)

- [ ] **Step 4: Type-check, generate, inspect**

Add a temporary `channels:` block to the Slack source in `margot.yaml` and run the stdout generate. Confirm in `/tmp/margot.sql`:
- `grep "DELETE FROM channel"` present.
- `grep -A3 "INSERT INTO channel"` shows the channel rows with `compose` JSON.
- The Slack personal-twist insert ends with `..., NULL)` (not `now()`), i.e. live connection.
Run tsc. Revert temp edit.

- [ ] **Step 5: Commit**
```bash
git add libs/db/seeds/types.ts libs/db/seeds/generate-seed.ts
git commit -m "seed: support per-source channels; keep channel-bearing source live"
```

---

### Task A4: Update spec.md and README.md

**Files:**
- Modify: `libs/db/seeds/spec.md`
- Modify: `libs/db/seeds/README.md`

- [ ] **Step 1: Document `icon` on priorities (spec.md)**

In spec.md "Priorities" → "Settings fields" area, add under the Priorities fields list:
```markdown
- `icon` (optional): A curated focus-icon key (one of: user, family, briefcase, house, code, receipt, bullhorn, handshake, rocket, building, lightbulb, heart, flask, paintbrush, dumbbell, seedling, balloons, music, plane, mountain, globe, billboard). Written to `priority.icon`. Unknown keys warn but don't fail.
```

- [ ] **Step 2: Document `groups` (spec.md)**

Add a new top-level section after "Twists":
```markdown
## Groups

Reusable named sets of contacts, surfaced in the new-thread picker's Groups
section. The seed user is automatically an admin of every group (so it appears
for them).

**Fields:**
- `ref` (required): Unique reference string
- `name` (required): Display name
- `privacy` (optional, default `open`): `open` (members see roster & can address) or `private` (only admins)
- `members` (required): Array of contact refs
- `admins` (optional): Extra user refs to make admins (rarely needed)

```yaml
groups:
  - ref: coaching_staff_grp
    name: Coaching staff
    privacy: open
    members: [wes, murph, eli]
```
```

- [ ] **Step 3: Document `channels` (spec.md)**

In the "Sources" section, add to the Source fields list and an example:
```markdown
- `channels` (optional): Array of enabled connection channels (e.g. Slack channels). Each surfaces in the new-thread picker's Channels section. A channel-bearing source is created as a live (non-archived) connection.

**Channel fields:**
- `channel_id` (required): Provider channel id (e.g. `C04general`)
- `title` (required): Display title (e.g. `#general`)
- `enabled` (optional, default `true`)
- `link_types` (optional): Override the default compose-capable link type

```yaml
sources:
  - ref: slack
    name: Slack
    priority_ref: everything
    logo: "https://api.iconify.design/logos/slack-icon.svg"
    link_types:
      - type: message
        label: Message
        logo: "https://api.iconify.design/logos/slack-icon.svg"
    channels:
      - channel_id: C04general
        title: "#general"
      - channel_id: C04womens
        title: "#womens-team-launch"
```
```

- [ ] **Step 4: Mention the new sections in README.md "Features"**

Add bullets to README.md's Features list:
```markdown
- **Focus icons**: Priorities carry a curated `icon` key
- **Groups**: Reusable contact sets for the new-thread picker
- **Channels**: Enabled connection channels (e.g. Slack) for the new-thread picker
```

- [ ] **Step 5: Commit**
```bash
git add libs/db/seeds/spec.md libs/db/seeds/README.md
git commit -m "seed: document icon, groups, and channels"
```

---

### Task A5: Emit `thread_state` for feed sectioning (gap found during execution)

**Why:** The unified/sectioned feed buckets on the synced `active`/`unread`
booleans, which come from a per-user `thread_state` row (`user.thread.active =
ts.active`; `unread = ts.read_at IS NULL AND ts.user_id IS NOT NULL`). The
generator emits no `thread_state`, so every seeded thread is `active=0,
unread=0` → **Done**. To populate Active / Scheduled / Unread we emit
`thread_state`. A thread with **no** row stays Done (the desired default for the
done tail).

**Section → seed representation:**
- **Active (Doing)**: `state: active` → `thread_state(active=true, read_at set)`, no future schedule.
- **Scheduled**: `state: scheduled` → `thread_state(active=true, read_at set)` + a future `schedule.at`.
- **Unread (Updates cluster)**: `state: unread` → `thread_state(active=true, read_at NULL)`.
- **Done**: omit `state` → no `thread_state` row (active=0, read).

**Files:** Modify `libs/db/seeds/types.ts`, `libs/db/seeds/generate-seed.ts`.

- [ ] **Step 1:** Add `state?: "active" | "scheduled" | "unread" | "done"` to `Thread`; add `GeneratedThreadState { user_id; thread_id; active; read_at; bumped_at; importance }`.
- [ ] **Step 2:** Cleanup line: `DELETE FROM thread_state WHERE user_id = <userId>;`.
- [ ] **Step 3:** In `processThread`, push a `GeneratedThreadState` when `state` is active/scheduled/unread (read_at = thread `created` offset or baseDate; bumped_at = read_at; importance 60; active true; read_at NULL only for `unread`).
- [ ] **Step 4:** Emit `INSERT INTO thread_state (user_id, thread_id, active, read_at, bumped_at, importance, updated_at)`.
- [ ] **Step 5:** Soft-validate `state` value in `validateThread`.
- [ ] **Step 6:** Commit `seed: emit thread_state for feed sectioning (active/scheduled/unread)`.

---

## Part B — Rewrite margot.yaml

### Task B1: Config, contacts, flat focuses, sources (with channels), twists, groups

**Files:**
- Rewrite: `libs/db/seeds/margot.yaml` (this task replaces the top sections; threads come in B2/B3)

- [ ] **Step 1: Keep config + contacts, add 2 board contacts**

Keep `config` (baseDate `2026-05-01`, email, userName) and the existing contacts. Add two board members for the Board group:
```yaml
  - ref: wakeling
    email: j.wakeling@afcmarlow.com
    name: Jonathan Wakeling
  - ref: della
    email: della.fenwick@afcmarlow.com
    name: Della Fenwick
```

- [ ] **Step 2: Replace the nested priorities with six flat focuses**

```yaml
priorities:
  - ref: everything
    title: Everything
    root: true
    children:
      - ref: womens_team
        title: Launch women's team
        icon: rocket
        settings:
          color: 2
      - ref: commercial
        title: Commercial & partnerships
        icon: handshake
        settings:
          color: 2
      - ref: mens_team
        title: Men's team
        icon: dumbbell
        settings:
          color: 1
      - ref: facilities
        title: Facilities
        icon: building
        settings:
          color: 1
      - ref: community
        title: Community & supporters
        icon: bullhorn
        settings:
          color: 6
      - ref: personal
        title: Personal
        icon: heart
        settings:
          color: 4
```

- [ ] **Step 3: Keep sources, add channels to Slack**

Keep `slack, gmail, gcal, notion, whatsapp, sheets` sources (each `priority_ref: everything`). Add to the Slack source:
```yaml
    channels:
      - channel_id: C04general
        title: "#general"
      - channel_id: C04coaching
        title: "#coaching-staff"
      - channel_id: C04womens
        title: "#womens-team-launch"
      - channel_id: C04fans
        title: "#fan-engagement"
```

- [ ] **Step 4: Keep twists (claude, chatgpt) unchanged.**

- [ ] **Step 5: Add the groups section**

```yaml
groups:
  - ref: coaching_staff_grp
    name: Coaching staff
    privacy: open
    members: [wes, murph, eli]
  - ref: board_grp
    name: Board
    privacy: private
    members: [maurice, wakeling, della]
  - ref: womens_taskforce_grp
    name: Women's team taskforce
    privacy: open
    members: [posy, maurice]
```

- [ ] **Step 6: Remove `priority_blocks` entirely** (old gap-agenda mechanism).

- [ ] **Step 7: Validate-generate (threads not yet rewritten will error on unknown priority_ref — expected).** This task's output is verified in B2 once threads are rehomed. Do not commit yet.

---

### Task B2: Thread inventory — the two complete focuses (~30 each)

**Files:**
- Rewrite: `libs/db/seeds/margot.yaml` (`threads:` section)

This task rehomes existing thread content and extends each complete focus to ~30 threads. Use the section partition below. Author the note prose in Margot's established voice (see `margot.md`); keep done-tail threads terse (title + one preview note + one link). Every thread must have at least one link with a `source_ref` (connection logo) and a title.

- [ ] **Step 1: Launch women's team — ~5 active**

`priority_ref: womens_team`, each `tags: { todo: [user] }` or `tags: { goal: [user] }`, no future event, no `done_at`:
1. WOMEN'S TEAM PROPOSAL — Vision and viability (`icon: goal`, `tags: {pinned:[user], goal:[user]}`) — **FULLY NOTED** (keep the long vision doc + the Plot-AI Q&A from the old seed).
2. Board presentation talking points (`twist_ref: claude`) — **FULLY NOTED** (keep the Claude exchange).
3. Marlow Trust pre-brief — women's team announcement (`icon: notes`).
4. Coaching candidate criteria — tighten (`icon: notes`).
5. Founding-partner shortlist (link: sheets).

- [ ] **Step 2: Launch women's team — ~7 scheduled (events)**

Each with `schedule.at` today→+2d, link `source_ref: gcal type: event`:
1. Focus: Launch women's team (`+0d 08:00 / +0d 09:00`, `ref: event_focus`) — keep the morning focus notes.
2. Women's team board strategy w/ Embry (`+0d 11:15 / +0d 12:00`, `ref: event_embry`, `tags:{pinned:[user]}`).
3. FA Women's Championship liaison call (`+0d 14:00 / +0d 14:30`, `ref: event_fa`).
4. Launch sponsorship strategy (`+0d 10:00 / +0d 10:30`, `ref: event_sponsor`) — (commercial-flavored but file under womens_team for feed density) — actually file under `commercial` (see B3). Replace with: Revenue model review block (`+1d 09:00 / +1d 10:00`).
5. Board pre-brief dry run (`+1d 16:00 / +1d 16:30`).
6. Supporters' Trust sit-down (`+2d 10:00 / +2d 11:00`).
7. Scarf supplier sign-off call (`+2d 14:00 / +2d 14:30`).

- [ ] **Step 3: Launch women's team — ~18 done**

Each with `schedule.on: "-Nd"` + `done_at: "-Nd HH:MM"` OR no schedule but a past note, spread `-1d`…`-3w`. Mix of links across gmail/notion/sheets/slack. Include (rehomed from old seed): Women's team exploration research (`icon: idea`), Revenue model assumptions (`twist_ref: chatgpt`, **FULLY NOTED** — keep ChatGPT exchange → this is the 3rd fully-noted thread), Finalize women's team financial model (Embry benchmarking exchange), Potential coaching candidates research, Founding season scarf design (**FULLY NOTED** — keep Posy DM + image action; this is the scarf thread) → NOTE: scarf is *done* and fully-noted. Reflection threads, board dinner sounding, Gus feature inquiry, etc. Pad with terse done items (e.g. "League application fee approved", "Locker-room renovation quote", "Sponsor NDA template", "Year-5 model sign-off", "Founding-season badge artwork", "Schools outreach for launch week", "Press embargo plan", "Ticketing plan for opener", "Volunteer recruitment for launch", "Brand guidelines pack") until the focus has ~30 threads total.

> The fully-noted threads for this focus: **Proposal**, **Board talking points**, **Revenue model (ChatGPT)**, **Scarf**. (Scarf must keep its `actions` file block referencing `wfc-marlow.jpg`, fileId `b7e3f1a2-4d5c-6e8f-9a0b-1c2d3e4f5a6b`.)

- [ ] **Step 4: Men's team — ~5 active**

`priority_ref: mens_team`, `tags: {todo:[user]}`:
1. Review coaching strategy with Wes and Murph (`icon: discussion`).
2. Supporter communication strategy on form (`icon: decision`).
3. Confirm Chelsea travel roster.
4. Approve sports-science block for next cycle.
5. Decide on Eli's role vs Chelsea (idea).

- [ ] **Step 5: Men's team — ~7 scheduled (events)**

1. Chelsea match tactics (`+0d 09:15 / +0d 09:45`, `ref: event_tactics`).
2. Match-day prep review (`+0d 19:00 / +0d 20:00`, `ref: event_review`).
3. Team departs for Stamford Bridge (`+1d 08:30 / +1d 09:00`).
4. Pre-match meal (`+1d 10:45 / +1d 11:30`).
5. Chelsea vs Marlow (`+1d 12:30 / +1d 14:30`).
6. Squad review w/ Wes (`+2d 10:00 / +2d 11:00`).
7. Weekly operations / football block (`+2d 14:00 / +2d 15:00`, recurrence weekly).

- [ ] **Step 6: Men's team — ~18 done**

Rehomed from old seed (drop the `associated_with` event nesting; make them standalone done threads): Match review — Bournemouth loss (`icon: discussion`, perflab email), Training report — confidence exercises (Wes), Upcoming fixture — Chelsea preview (announcement), Wes' formation notes, Eli positioning ideas, Last meeting clips — Chelsea (H), Perflab pack — Chelsea final pass, Pre-match call brief for Wes, Last-6 form summary, plus terse done items ("Injury report — Tuesday", "Set-piece drill plan", "Player load report", "Academy call-ups shortlist", "Opposition scouting — next 3", "Recovery protocol sign-off", "Kit dispatch confirmed", "Travel insurance renewal", "Matchday medical cover"). Reach ~30 total.

- [ ] **Step 7: Generate + apply, sanity-check counts**

Run the stdout generate; expect zero validation errors. Then:
```bash
pnpm --filter @plotday/db gen-seed libs/db/seeds/margot.yaml | grep -c "INSERT INTO thread "  # informational
```
Apply locally and spot-check:
```bash
psql "$DATABASE_URL" -tAc "SELECT p.title, count(*) FROM thread_priority tp JOIN priority p ON p.id=tp.priority_id WHERE tp.user_id=(SELECT id FROM \"user\" WHERE email='margot.whitcombe@afcmarlow.com') GROUP BY p.title ORDER BY 2 DESC;"
```
Expect ~30 each for the two complete focuses.

---

### Task B3: Sidebar focuses (light) + agenda fill + final apply

**Files:**
- Rewrite: `libs/db/seeds/margot.yaml`

- [ ] **Step 1: Add 2–4 threads per sidebar focus, biased to events**

- `commercial`: Lunch with Avenir rep (`+0d 12:30 / +0d 13:30`, `ref: event_lunch`, gcal event) + Launch sponsorship strategy (`+0d 10:00 / +0d 10:30`, gcal) + 1 done (Avenir follow-up).
- `facilities`: Q2 facilities CapEx sign-off (done, sheets) + Training ground spring maintenance (done, notion) + Stadium ops walkthrough (`+2d 09:00 / +2d 09:30`, gcal event).
- `community`: Sky Sports pre-match interview (`+0d 15:00 / +0d 15:30`, `ref: event_sky`, gcal) + Supporter sentiment summary (done, `author_ref: posy`, gmail+slack) + Schools partnership — 4 new requests (done, gmail).
- `personal`: Coffee with Pen (`-2d 10:00 / -2d 11:00`, whatsapp) + Evening walk — think time (`+0d 18:00 / +0d 19:00`, gcal) + Drinks with Posy (`-1d 21:30 / -1d 23:00`, whatsapp).

- [ ] **Step 2: Confirm agenda spread**

Events now exist across `-2d … +2d` from multiple focuses. Verify the densest day is base date and the Chelsea fixture is on `+1d`.

- [ ] **Step 3: Full validate + apply**

```bash
pnpm --filter @plotday/db gen-seed libs/db/seeds/margot.yaml > /tmp/margot.sql   # zero errors
pnpm --filter @plotday/db gen-seed --apply libs/db/seeds/margot.yaml
```
Then verify groups + channels landed:
```bash
psql "$DATABASE_URL" -tAc "SELECT name, privacy FROM \"group\" WHERE created_by=(SELECT id FROM \"user\" WHERE email='margot.whitcombe@afcmarlow.com');"
psql "$DATABASE_URL" -tAc "SELECT title, enabled FROM channel ch JOIN twist_instance ti ON ti.id=ch.twist_instance_id WHERE ti.owner_id=(SELECT id FROM \"user\" WHERE email='margot.whitcombe@afcmarlow.com');"
```
Expect 3 groups and 4 enabled channels.

- [ ] **Step 4: Reproducibility check**

Run the stdout generate twice into two files; the only differences should be UUIDs and the header timestamp (UUIDs are random per run by design — this matches the existing generator). Confirm no structural diff (row counts, column lists identical):
```bash
pnpm --filter @plotday/db gen-seed libs/db/seeds/margot.yaml | grep -E "INSERT INTO|VALUES" | wc -l
```
(Run twice; counts must match.)

- [ ] **Step 5: Commit the YAML**
```bash
git add libs/db/seeds/margot.yaml
git commit -m "seed: rewrite margot.yaml for flat focuses, sectioned feed, groups + channels"
```

---

### Task B4: Run-app verification

- [ ] **Step 1: Launch the app against the seeded user** via the `run-app` skill (isolated agent profile). Sign in / point at the local DB with Margot's user.

- [ ] **Step 2: Verify each acceptance criterion** (from the spec):
  - Sidebar: 6 flat focuses, distinct icons, two blue + two green colour pairs.
  - Select **Launch women's team** and **Men's team**: sectioned feed (active / scheduled / done) long enough to scroll; scarf image renders; Proposal / Board / Revenue threads show full note trees.
  - Agenda: events across −1d→+2d, Chelsea on +1d.
  - NewThreadPage ("Start a thread"): People populated, **Groups** shows 3, **Channels** shows the 4 Slack channels.

- [ ] **Step 3: If Channels do NOT appear**, inspect `apps/plot/lib/widget/connection_targets.dart` and `apps/plot/lib/state/compose_targets.dart` for an extra gate beyond "enabled channel with a `compose` block on a live connection". Likely fixes, in order: (a) confirm the Slack twist is non-archived (Task A3 Step 3); (b) confirm `Channel.watchAllEnabled()` returns the rows (`linkTypes` non-null); (c) adjust the channel `link_types` JSON to match what `LinkTypeConfig.fromJson` + `ComposeConfig.fromJson` expect. Fix, re-apply, re-verify.

- [ ] **Step 4: Finalize** — run `/finalize` (lint affected packages; this seed change is dev-only data + a generator script, so no `docs/updates.md` entry is required, but confirm). No DB migration was created, so `db:lint` is unaffected.

---

## Self-Review

**Spec coverage:**
- Flat focuses w/ icons + colours → B1 Step 2. ✓
- Two complete focuses ~30 threads, mostly done → B2. ✓
- Sectioned feed (active/scheduled/done) → B2 Steps 1–6 partition by tags/schedule/done_at. ✓
- 2–3 fully-noted incl. scarf → B2 (Proposal, Board, Revenue, Scarf). ✓
- Sidebar focuses + agenda → B3. ✓
- Groups (3) → A2 + B1 Step 5. ✓
- Channels (4 Slack) → A3 + B1 Step 3. ✓
- Generator: icon/groups/channels + docs → A1–A4. ✓
- Reproducibility → B3 Step 4. ✓
- Dropped priority_blocks + gap to-dos → B1 Step 6 (+ B2 uses plain done/active, no gap pins). ✓

**Placeholder scan:** No "TBD"/"add error handling"-style gaps; note prose is content authored in B2/B3 (explicitly Margot's voice), not a code placeholder. ✓

**Type consistency:** `SeedGroup.members` (contact refs) used in A2 Step 4; `GeneratedGroup{id,name,privacy,created_by}` matches the emit in A2 Step 5; `SeedChannel{channel_id,title,enabled,link_types}` matches A3 Step 3; `priority.icon` column added in A1 Step 3 matches `GeneratedPriority.icon` in A1 Step 1. ✓

**Known risk carried forward:** channel surfacing in NewThreadPage (B4 Step 3 mitigation). Acceptable — verified at run-app time.
