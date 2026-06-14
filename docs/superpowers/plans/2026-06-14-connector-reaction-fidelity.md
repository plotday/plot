# Connector Reaction Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every chat connector that supports reactions full two-way, per-actor reaction sync by migrating outbound write-back from the legacy connected-user `onNoteUpdated` reconcile to the per-actor `onNoteReactionChanged` hook.

**Architecture:** Inbound reaction sync already works everywhere. This is an outbound migration for Google Chat (multi-reaction, direct create/delete) and LinkedIn/Instagram/WhatsApp (one-reaction-per-user, event + per-user state via a shared, unit-tested helper in `libs/unipile`). Slack and MS Teams already use the target pattern and are untouched.

**Tech Stack:** TypeScript, pnpm workspaces, vitest. Connectors extend `Connector` from `@plotday/twister`. Private connectors share `@plotday/unipile`.

**Spec:** `docs/superpowers/specs/2026-06-14-connector-reaction-fidelity-design.md`

**Workspace:** worktree `.claude/worktrees/feat/connector-reactions`. Core branch on `origin/main`; submodule `public/` on branch `feat/connector-reactions` @ `de1a09c`. All paths below are relative to the worktree root. Google Chat lives in the `public/` submodule (commit there); the three private connectors + the helper live in core (commit on the core branch).

---

### Task 1: `reconcilePerUserReaction` helper (one-reaction-per-user decision logic)

The non-trivial logic for the private connectors. Pure function, TDD'd where a vitest harness already exists.

**Files:**
- Modify: `libs/unipile/src/connector-helpers.ts`
- Test: `libs/unipile/src/connector-helpers.test.ts`
- Verify export: `libs/unipile/src/index.ts`

- [ ] **Step 1: Write the failing tests**

Append to `libs/unipile/src/connector-helpers.test.ts` (it already uses vitest `describe`/`it`/`expect`; add the import name to the existing top-of-file import from `./connector-helpers`):

```typescript
import { reconcilePerUserReaction } from "./connector-helpers";

describe("reconcilePerUserReaction", () => {
  it("sets a newly added emoji when none was pushed", () => {
    expect(reconcilePerUserReaction(null, "👍", true)).toEqual({ action: "set", emoji: "👍" });
  });

  it("replaces the previously pushed emoji when a different one is added", () => {
    expect(reconcilePerUserReaction("👍", "❤️", true)).toEqual({ action: "set", emoji: "❤️" });
  });

  it("no-ops when the added emoji is already the pushed one", () => {
    expect(reconcilePerUserReaction("👍", "👍", true)).toEqual({ action: "none" });
  });

  it("clears when the removed emoji is the one currently pushed", () => {
    expect(reconcilePerUserReaction("👍", "👍", false)).toEqual({ action: "clear" });
  });

  it("no-ops when removing an emoji that is not the one currently pushed", () => {
    expect(reconcilePerUserReaction("❤️", "👍", false)).toEqual({ action: "none" });
  });

  it("no-ops when removing while nothing is pushed", () => {
    expect(reconcilePerUserReaction(null, "👍", false)).toEqual({ action: "none" });
  });

  it("no-ops when adding an emoji outside the allowed set (fixed-set platforms)", () => {
    const allowed = ["👍", "❤️"] as const;
    expect(reconcilePerUserReaction(null, "🎉", true, allowed)).toEqual({ action: "none" });
  });

  it("sets an allowed emoji on a fixed-set platform", () => {
    const allowed = ["👍", "❤️"] as const;
    expect(reconcilePerUserReaction(null, "❤️", true, allowed)).toEqual({ action: "set", emoji: "❤️" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm --filter @plotday/unipile test`
Expected: FAIL — `reconcilePerUserReaction is not a function` (or import error).

- [ ] **Step 3: Implement the helper**

Append to `libs/unipile/src/connector-helpers.ts`:

```typescript
/**
 * The single outbound action for a one-reaction-per-user platform (LinkedIn,
 * Instagram, WhatsApp via Unipile — each member holds at most one reaction per
 * message). `lastSent` is the emoji this connector last pushed for THIS user on
 * THIS message (tracked in per-user connector state); `(emoji, added)` is the
 * incoming transition from `onNoteReactionChanged`. `allowed` (fixed-set
 * platforms like LinkedIn) filters emoji the platform can't represent.
 *
 * Limitation: because the reaction dispatch does not carry the full
 * `note.reactions` map, a single user who stacks multiple emoji on one message
 * is reconciled to last-write-wins; removing the last-pushed emoji clears the
 * user's platform reaction even if another Plot emoji of theirs remains. Plot
 * retains all reactions; the external platform is inherently one-per-user.
 */
export type ReactionWriteback =
  | { action: "set"; emoji: string }
  | { action: "clear" }
  | { action: "none" };

export function reconcilePerUserReaction(
  lastSent: string | null,
  emoji: string,
  added: boolean,
  allowed?: readonly string[],
): ReactionWriteback {
  if (added) {
    if (allowed && !allowed.includes(emoji)) return { action: "none" };
    if (lastSent === emoji) return { action: "none" };
    return { action: "set", emoji };
  }
  if (lastSent === emoji) return { action: "clear" };
  return { action: "none" };
}
```

- [ ] **Step 4: Confirm the package re-exports it**

Run: `grep -n "connector-helpers" libs/unipile/src/index.ts`
Expected: a line like `export * from "./connector-helpers";`. If the index uses named re-exports instead, add `reconcilePerUserReaction` (and `ReactionWriteback`) to that list so `@plotday/unipile` exposes it.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm --filter @plotday/unipile test`
Expected: PASS — all `reconcilePerUserReaction` tests green, existing `pickDesiredReaction` tests still green.

- [ ] **Step 6: Commit**

```bash
git add libs/unipile/src/connector-helpers.ts libs/unipile/src/connector-helpers.test.ts libs/unipile/src/index.ts
git commit -m "feat(unipile): reconcilePerUserReaction helper for per-actor reaction write-back

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Google Chat — per-actor reactions (public submodule)

Multi-reaction platform: each `(emoji, added)` maps directly to `createReaction`/`deleteReaction`. Add `onNoteReactionChanged`; strip the reaction reconcile out of `onNoteUpdated` (keep content-edit sync). No test harness exists for this connector (consistent with the codebase); verify via tsc/build/lint. Lives in the `public/` submodule.

**Files:**
- Modify: `public/connectors/google-chat/src/google-chat.ts` (`onNoteUpdated` ~1180–1291; add `onNoteReactionChanged` after it)

- [ ] **Step 1: Replace the `onNoteUpdated` doc comment + body (drop reactions, keep content)**

Replace the doc comment block and method from line 1182 (`/**`) through the method's closing `}` (line 1291) with:

```typescript
  /**
   * Pushes a Plot-side content edit of a Google Chat message back via
   * `messages.patch`. Reactions are handled separately by
   * `onNoteReactionChanged` so each emoji is attributed to the user who made
   * it (that callback is dispatched on the reacting user's own connector
   * instance via `twist_instance_for_actor`).
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;

    // Extract message name from note key (format: "message-{messageId}")
    const noteKey = note.key;
    if (!noteKey?.startsWith("message-")) return;
    const messageId = noteKey.substring("message-".length);
    const spaceName = meta.spaceName as string;
    if (!spaceName) return;
    const messageName = `${spaceName}/messages/${messageId}`;

    if (note.content === null || note.content === undefined) return;

    const api = await this.getApi(channelId ?? DM_CHANNEL_ID);

    // Content sync is best-effort; only the message author can patch.
    try {
      const updated = await api.updateMessage(messageName, note.content);
      // Mirror sync-in: prefer formattedText + "html", else text + "text".
      const hasFormatted =
        typeof updated.formattedText === "string" && updated.formattedText.length > 0;
      const externalContent = hasFormatted
        ? updated.formattedText!
        : (updated.text ?? note.content);
      return { externalContent };
    } catch (error) {
      console.warn(
        "[google-chat] messages.patch failed; skipping content write-back:",
        error
      );
    }
  }
```

- [ ] **Step 2: Add `onNoteReactionChanged` immediately after `onNoteUpdated`**

```typescript
  /**
   * Pushes a single emoji add/remove back to Google Chat, attributed to the
   * reacting user. Dispatched on that user's own connector instance (routed via
   * `twist_instance_for_actor`), so `getApi` resolves to their token and
   * `auth_google_user` is their identity. Google Chat allows multiple distinct
   * reactions per user, so each transition maps directly to create/delete —
   * no per-user state needed.
   *
   * Custom (workspace) emoji are skipped here, symmetric with sync-in, until
   * the custom-emoji image cache lands (see `reactionCapabilities`).
   */
  async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string | undefined;

    const noteKey = note.key;
    if (!noteKey?.startsWith("message-")) return;
    const messageId = noteKey.substring("message-".length);
    const spaceName = meta.spaceName as string | undefined;
    if (!spaceName) return;
    const messageName = `${spaceName}/messages/${messageId}`;

    // Custom workspace emoji aren't round-tripped yet (symmetric with sync-in).
    if (emoji.includes(":")) return;

    const api = await this.getApi(channelId ?? DM_CHANNEL_ID);

    if (added) {
      try {
        await api.createReaction(messageName, emoji);
      } catch (error) {
        console.warn(`[google-chat] createReaction failed for ${emoji}:`, error);
      }
      return;
    }

    // Removal: find this user's reaction resource for the emoji, then delete it.
    const authUser = await this.get<{ googleUserId: string }>("auth_google_user");
    if (!authUser?.googleUserId) return;
    let currentReactions: EmojiReaction[];
    try {
      currentReactions = await api.listReactions(messageName);
    } catch {
      return; // message may be gone
    }
    const match = currentReactions.find(
      (r) => r.user.name === authUser.googleUserId && r.emoji.unicode === emoji
    );
    if (!match) return;
    try {
      await api.deleteReaction(match.name);
    } catch (error) {
      console.warn("[google-chat] deleteReaction failed:", error);
    }
  }
```

- [ ] **Step 3: Typecheck**

Run: `cd public/connectors/google-chat && pnpm exec tsc --noEmit; cd ../../..`
Expected: exit 0, no output. (`Actor`, `Note`, `Thread`, `EmojiReaction`, `DM_CHANNEL_ID` are already imported/defined; `note.reactions` is no longer referenced.)

- [ ] **Step 4: Lint**

Run: `cd public/connectors/google-chat && pnpm lint; cd ../../..`
Expected: passes (the `plot lint` connector check).

- [ ] **Step 5: Commit (in the submodule, on `feat/connector-reactions`)**

```bash
cd public
git add connectors/google-chat/src/google-chat.ts
git commit -m "feat(google-chat): per-actor reaction write-back via onNoteReactionChanged

Migrate outbound reactions off the connected-user onNoteUpdated reconcile to
the per-actor onNoteReactionChanged hook (Slack/MS-Teams pattern), so each
emoji is attributed to the user who reacted. onNoteUpdated keeps content-edit
sync only. Unicode only; custom workspace emoji remain deferred (symmetric
with sync-in), pending the custom-emoji image cache.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
cd ..
```

---

### Task 3: LinkedIn — per-actor reactions (private, core)

Fixed 7-emoji set, one reaction per user. Add `onNoteReactionChanged` using the Task 1 helper; remove the `onNoteUpdated` override entirely (it only did reactions — LinkedIn can't edit message content). Drop the now-unused `pickDesiredReaction` import (keep `reconcilePerUserReaction`).

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts` (import line 38 area; remove `onNoteUpdated` ~489–550; add `onNoteReactionChanged`)

- [ ] **Step 1: Swap the helper import**

In the `@plotday/unipile` import block (ends line 38), remove `pickDesiredReaction` and add `reconcilePerUserReaction`. Result (names only — keep the other existing imports from that block, e.g. `buildLinkForChat`, `backfillChats`, etc., exactly as they are):

```typescript
import {
  // ...existing names from this block unchanged...
  reconcilePerUserReaction,
} from "@plotday/unipile";
```

- [ ] **Step 2: Remove the `onNoteUpdated` override**

Delete the entire `onNoteUpdated` doc comment + method (the block beginning with the `/** Push reaction changes back to LinkedIn ... */` comment around line 489 through the method's closing `}` around line 550, immediately before `override async onLinkUpdated` at line 551). LinkedIn has no content-edit support, so this reverts to the base-class no-op.

- [ ] **Step 3: Add `onNoteReactionChanged`**

Add this method to the class (e.g. just before `onThreadRead` at line ~589):

```typescript
  /**
   * Pushes a single emoji add/remove the user made in Plot back to LinkedIn,
   * attributed to that user (dispatched on their own connector instance via
   * `twist_instance_for_actor`, so the Unipile call runs under their account).
   *
   * LinkedIn allows each member at most one reaction per message and only the
   * seven `LINKEDIN_REACTIONS`. We track the emoji we last pushed for this
   * user/message in connector state (`reaction_sent:${messageId}`, which is
   * per-user since this runs on the user's instance) and reconcile via
   * `reconcilePerUserReaction`.
   */
  override async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key || !note.key.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;

    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    const decision = reconcilePerUserReaction(lastSent, emoji, added, LINKEDIN_REACTIONS);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.linkedin.setMessageReaction({
          channelId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.linkedin.clearMessageReaction({ channelId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(`LinkedIn reaction write-back failed for message ${messageId}`, error);
    }
  }
```

- [ ] **Step 4: Typecheck**

Run: `cd connectors/linkedin && pnpm exec tsc --noEmit; cd ../..`
Expected: exit 0, no output. If tsc flags `Link` or `NoteWriteBackResult` as unused (they were only used by the removed `onNoteUpdated`), remove them from the imports too; re-run until clean.

- [ ] **Step 5: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): per-actor reaction write-back via onNoteReactionChanged

Replace the connected-user onNoteUpdated reaction reconcile (single emoji for
all reactors) with the per-actor onNoteReactionChanged hook + per-user state,
so each user's reaction is attributed to their own LinkedIn account. Removes
the now-empty onNoteUpdated override (LinkedIn has no message-content edit).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Instagram — per-actor reactions (private, core)

Open-unicode, one reaction per user. Same shape as LinkedIn but no `allowed` set.

**Files:**
- Modify: `connectors/instagram/src/instagram.ts` (import line 29 area; remove `onNoteUpdated` ~362–407; add `onNoteReactionChanged`)

- [ ] **Step 1: Swap the helper import**

In the `@plotday/unipile` import block (ends line 29), remove `pickDesiredReaction`, add `reconcilePerUserReaction`.

- [ ] **Step 2: Remove the `onNoteUpdated` override**

Delete the `onNoteUpdated` doc comment + method (begins with the `/** Push reaction changes back to Instagram ... */` comment ~362 through the method's closing `}` ~407, immediately before `override async onThreadRead` at line 408).

- [ ] **Step 3: Add `onNoteReactionChanged`** (just before `onThreadRead`):

```typescript
  /**
   * Pushes a single emoji add/remove back to Instagram, attributed to the
   * reacting user (dispatched on their own connector instance via
   * `twist_instance_for_actor`). Instagram allows one open-unicode reaction per
   * user per message; we track the last-pushed emoji per user/message in
   * `reaction_sent:${messageId}` and reconcile via `reconcilePerUserReaction`.
   */
  override async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key || !note.key.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;

    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    const decision = reconcilePerUserReaction(lastSent, emoji, added);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.instagram.setMessageReaction({
          channelId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.instagram.clearMessageReaction({ channelId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(`Instagram reaction write-back failed for message ${messageId}`, error);
    }
  }
```

- [ ] **Step 4: Typecheck**

Run: `cd connectors/instagram && pnpm exec tsc --noEmit; cd ../..`
Expected: exit 0, no output. Remove any import (`NoteWriteBackResult`, `Link`) tsc now flags as unused.

- [ ] **Step 5: Commit**

```bash
git add connectors/instagram/src/instagram.ts
git commit -m "feat(instagram): per-actor reaction write-back via onNoteReactionChanged

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: WhatsApp — per-actor reactions (private, core)

Open-unicode, one reaction per user. Identical shape to Instagram.

**Files:**
- Modify: `connectors/whatsapp/src/whatsapp.ts` (import line 27 area; remove `onNoteUpdated` ~256–305; add `onNoteReactionChanged`)

- [ ] **Step 1: Swap the helper import**

In the `@plotday/unipile` import block (ends line 27), remove `pickDesiredReaction`, add `reconcilePerUserReaction`.

- [ ] **Step 2: Remove the `onNoteUpdated` override**

Delete the `onNoteUpdated` doc comment + method (the `/** Push reaction changes back to WhatsApp ... */` comment ~256 through the method's closing `}` ~305, immediately before `override async onThreadRead` at line 306).

- [ ] **Step 3: Add `onNoteReactionChanged`** (just before `onThreadRead`):

```typescript
  /**
   * Pushes a single emoji add/remove back to WhatsApp, attributed to the
   * reacting user (dispatched on their own connector instance via
   * `twist_instance_for_actor`). WhatsApp allows one open-unicode reaction per
   * user per message; we track the last-pushed emoji per user/message in
   * `reaction_sent:${messageId}` and reconcile via `reconcilePerUserReaction`.
   */
  override async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = (thread.meta ?? {}) as Record<string, unknown>;
    const channelId = meta.channelId as string | undefined;
    if (!channelId) return;
    if (!note.key || !note.key.startsWith("message-")) return;
    const messageId = note.key.slice("message-".length);
    if (!messageId) return;

    const stateKey = `reaction_sent:${messageId}`;
    const lastSent = (await this.get<string>(stateKey)) ?? null;
    const decision = reconcilePerUserReaction(lastSent, emoji, added);
    if (decision.action === "none") return;

    try {
      if (decision.action === "set") {
        await this.tools.whatsapp.setMessageReaction({
          channelId,
          messageId,
          reaction: decision.emoji,
        });
        await this.set(stateKey, decision.emoji);
      } else {
        await this.tools.whatsapp.clearMessageReaction({ channelId, messageId });
        await this.clear(stateKey);
      }
    } catch (error) {
      console.warn(`WhatsApp reaction write-back failed for message ${messageId}`, error);
    }
  }
```

- [ ] **Step 4: Typecheck**

Run: `cd connectors/whatsapp && pnpm exec tsc --noEmit; cd ../..`
Expected: exit 0, no output. Remove any newly-unused imports tsc flags.

- [ ] **Step 5: Commit**

```bash
git add connectors/whatsapp/src/whatsapp.ts
git commit -m "feat(whatsapp): per-actor reaction write-back via onNoteReactionChanged

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Docs + full verification + finalize

**Files:**
- Modify: `docs/updates.md`
- Verify: all four connector packages + `@plotday/unipile`

- [ ] **Step 1: Add a user-facing updates entry**

In `docs/updates.md`, under the top `## Next release` heading, add (or extend an existing reaction/messaging section — do not duplicate; if none fits, add `### Reactions` above `### Fixes`):

```markdown
### Reactions

- Emoji reactions you add in Google Chat, LinkedIn, Instagram, and WhatsApp now sync back to the conversation, attributed to you.
```

- [ ] **Step 2: Full typecheck sweep**

Run:
```bash
cd public/connectors/google-chat && pnpm exec tsc --noEmit; cd ../../.. && \
cd connectors/linkedin && pnpm exec tsc --noEmit; cd ../.. && \
cd connectors/instagram && pnpm exec tsc --noEmit; cd ../.. && \
cd connectors/whatsapp && pnpm exec tsc --noEmit; cd ../..
```
Expected: each exits 0 with no output.

- [ ] **Step 3: Builds + helper tests**

Run:
```bash
pnpm --filter @plotday/unipile test && \
cd public/connectors/google-chat && pnpm build && cd ../../.. && \
cd connectors/linkedin && pnpm build && cd ../.. && \
cd connectors/instagram && pnpm build && cd ../.. && \
cd connectors/whatsapp && pnpm build && cd ../..
```
Expected: unipile tests pass; all four `tsc` builds succeed (emit `dist/`).

- [ ] **Step 4: Confirm no stray `pickDesiredReaction` / `onNoteUpdated` reaction usage remains in the three private connectors**

Run: `grep -rn "pickDesiredReaction\|onNoteUpdated" connectors/linkedin/src connectors/instagram/src connectors/whatsapp/src`
Expected: no matches (the private connectors no longer reference either).

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs(updates): reactions sync back on Google Chat, LinkedIn, Instagram, WhatsApp

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Finalization notes (do NOT auto-run; surface to the user)**

- Public PR: the submodule branch `feat/ms-teams-reactions` (PR #200) is renamed to `feat/connector-reactions`; push it and retitle the PR to cover all connectors. No changeset (connector-only; changesets are for `twister/` only).
- Core PR: open a separate core PR for the private-connector + helper commits.
- Submodule pointer bump: after the public PR merges, bump the `public` gitlink in core and include it in the core PR. (Until then, leave `M public` uncommitted.)
- Manual E2E (real multi-account, deferred): two users react in Plot on each platform; confirm each reaction lands under the right account and removal clears only that user's reaction.

---

## Self-Review

**Spec coverage:**
- Google Chat per-actor migration + custom-emoji deferral → Task 2. ✓
- LinkedIn/Instagram/WhatsApp per-actor migration, remove `onNoteUpdated`, one-per-user state → Tasks 3–5 + helper Task 1. ✓
- Inbound untouched (already works) → no task needed. ✓
- `reactionCapabilities` unchanged → no task needed. ✓
- Behavior-change documentation (no-connection reactor; one-per-user last-write-wins) → helper doc comment (Task 1) + connector comments + spec. ✓
- Testing strategy (TDD the helper where a harness exists; tsc/build/lint connectors; manual E2E deferred) → Tasks 1, 2–5, 6. ✓
- Workspace/branch/PR plan → header + Task 6 Step 6. ✓
- `docs/updates.md` → Task 6. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete code; commands have expected output. ✓

**Type consistency:** `reconcilePerUserReaction(lastSent, emoji, added, allowed?)` returning `{action:"set",emoji}|{action:"clear"}|{action:"none"}` is defined in Task 1 and consumed identically in Tasks 3–5 (`decision.action`, `decision.emoji`). Tool methods `setMessageReaction({channelId, messageId, reaction})` / `clearMessageReaction({channelId, messageId})` match `workers/api/src/twist/tools/unipile/messaging.ts`. Google Chat uses existing `createReaction(messageName, emoji)` / `listReactions(messageName)` / `deleteReaction(name)` and `EmojiReaction`. Method signatures match the base-class `onNoteReactionChanged(note, thread, actor, emoji, added)`. ✓
