/**
 * Guard against silently dropping a published /sync/* endpoint.
 *
 * WHY THIS EXISTS
 * ---------------
 * Plot is local-first and ships independently on web/desktop/mobile, so at any
 * moment there are deployed clients running OLD code against the CURRENT server.
 * Every path below is part of the sync wire contract those clients depend on.
 * Removing or renaming one (without leaving a backwards-compatible shim at the
 * old path) silently breaks the clients that still call it — exactly what
 * happened when commit 3ff3bffa renamed thread_unread → thread_state and deleted
 * POST /sync/thread-unread, stranding read-state sync for every not-yet-upgraded
 * client behind a 404.
 *
 * This test fails if any STABLE path stops being registered, forcing a
 * deliberate choice instead of a silent regression:
 *   1. Keep the old path as a compatibility shim that translates to the new
 *      handler (see ./thread-unread.ts for the canonical example), OR
 *   2. Only remove the entry here once you are certain no deployed client calls
 *      it anymore — and document that decision in the PR.
 *
 * Adding NEW endpoints needs no change here (the assertion is "stable ⊆
 * registered"); but adding the new path to this list is encouraged so the next
 * person inherits the same protection.
 */

import { describe, it, expect } from "vitest";

import sync from "./index";

/**
 * The published, client-facing sync surface. NEVER delete an entry without
 * either shipping a shim at the same path or confirming no old client depends
 * on it. Treat removals as a breaking API change.
 */
const STABLE_SYNC_PATHS: readonly string[] = [
  "/sync/actors",
  "/sync/capture",
  "/sync/channels",
  "/sync/custom-emoji",
  "/sync/groups",
  "/sync/links",
  "/sync/note-reactions",
  "/sync/note-reactions/update",
  "/sync/note-tags",
  "/sync/note-tags/update",
  "/sync/notes",
  "/sync/priorities",
  "/sync/priorities/find-matching-threads",
  "/sync/priorities/negatives",
  "/sync/priorities/suggest",
  "/sync/priority-attention",
  "/sync/priority-blocks",
  "/sync/priority-moves",
  "/sync/schedule/status",
  "/sync/schedules",
  "/sync/sessions",
  "/sync/team-users",
  "/sync/thread-associations",
  "/sync/thread-reactions",
  "/sync/thread-reactions/update",
  "/sync/thread-read",
  "/sync/thread-state",
  "/sync/thread-tags",
  "/sync/thread-tags/update",
  // Backwards-compat shim for the thread_unread → thread_state rename. Required
  // while pre-rename clients exist. See ./thread-unread.ts.
  "/sync/thread-unread",
  "/sync/threads",
  "/sync/threads/by-ids",
  "/sync/threads/search",
  "/sync/topics",
  "/sync/twist-connections",
  "/sync/twist-instances",
  "/sync/user-settings",
];

describe("stable /sync/* route manifest", () => {
  const registeredPaths = new Set(sync.routes.map((r) => r.path));

  it("registers every stable sync path (none silently dropped)", () => {
    const missing = STABLE_SYNC_PATHS.filter((p) => !registeredPaths.has(p));
    expect(
      missing,
      `These published /sync/* endpoints are no longer registered. Deployed ` +
        `clients still call them. Restore the route or add a compatibility ` +
        `shim at the same path before removing it from STABLE_SYNC_PATHS:\n` +
        missing.map((p) => `  - ${p}`).join("\n"),
    ).toEqual([]);
  });

  it("keeps the legacy /sync/thread-unread shim registered", () => {
    // Pinned out explicitly because this is the exact route whose removal
    // motivated the manifest — make its regression unmistakable.
    expect(registeredPaths.has("/sync/thread-unread")).toBe(true);
  });
});
