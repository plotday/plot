import { describe, it, expect } from "vitest";
import {
  isScopedNote,
  noteVisibleUserIds,
  resolveAccessContactsForSend,
  resolveAccessGroupsForSend,
  withForwardSnapshot,
} from "./notes";

/**
 * Build a Kysely-like stub whose raw `sql`...`.execute(db)` resolves to the
 * given rows. Mirrors the executor stub used in
 * src/twist/tools/plot/note-link-scoping.test.ts so we don't need a real DB:
 * the visibility predicate's group/contact overlap is owned and covered by the
 * DB layer (pgTAP 42-scoped-note-bump-isolation); here we pin the JS behavior
 * of noteVisibleUserIds — that it maps rows and excludes the caller.
 */
function createRawDbStub(rows: Array<{ user_id: string }>) {
  const executor: any = {
    transformQuery: (node: unknown) => node,
    compileQuery: () => ({ sql: "", parameters: [] }),
    executeQuery: async () => ({ rows }),
  };
  return { db: { getExecutor: () => executor } as any };
}

describe("resolveAccessContactsForSend", () => {
  it("returns body.access_contacts unchanged when sharing model is thread", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "thread",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("returns body.access_contacts unchanged when sharing model is channel", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "channel",
        threadContacts: ["c1", "c2"],
      }),
    ).toBeNull();
  });

  it("falls back to thread.contacts when body is null in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: null,
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1", "c2"]);
  });

  it("preserves explicit body.access_contacts in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: ["c1"],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual(["c1"]);
  });

  it("preserves an explicit empty array (author-only) in message-mode", () => {
    expect(
      resolveAccessContactsForSend({
        bodyAccessContacts: [],
        sharingModel: "message",
        threadContacts: ["c1", "c2"],
      }),
    ).toEqual([]);
  });
});

describe("resolveAccessGroupsForSend", () => {
  it("returns null when body has no access_groups", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: null })).toBeNull();
  });

  it("returns null when body access_groups is undefined", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: undefined })).toBeNull();
  });

  it("returns null when body access_groups is a non-array value", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: "g1" })).toBeNull();
  });

  it("returns the array when body provides access_groups", () => {
    expect(
      resolveAccessGroupsForSend({ bodyAccessGroups: ["g1", "g2"] }),
    ).toEqual(["g1", "g2"]);
  });

  it("returns an explicit empty array unchanged (no group restriction)", () => {
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: [] })).toEqual([]);
  });

  it("does not apply a message-mode invariant (groups are always pass-through)", () => {
    // Groups have no 'never-null-in-message-mode' rule; null stays null
    // regardless of sharing model. This test documents that contract explicitly.
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: null })).toBeNull();
    expect(resolveAccessGroupsForSend({ bodyAccessGroups: ["g1"] })).toEqual(["g1"]);
  });
});

describe("isScopedNote", () => {
  it("is unscoped when both resolved access arrays are null", () => {
    expect(isScopedNote(null, null)).toBe(false);
  });

  it("is scoped when resolved access_contacts is non-null (even if empty)", () => {
    // An explicit empty array (author-only) is still a scope — it must NOT
    // fall through to the broadcast markThreadUnreadForOthers path.
    expect(isScopedNote([], null)).toBe(true);
    expect(isScopedNote(["c1"], null)).toBe(true);
  });

  it("is scoped when resolved access_groups is non-null", () => {
    expect(isScopedNote(null, ["g1"])).toBe(true);
    expect(isScopedNote(null, [])).toBe(true);
  });
});

describe("withForwardSnapshot", () => {
  // Task 8: exactly-one forward-snapshot invariant on a note's actions. The
  // note is client-owned and re-pushed on every edit, so this MUST strip any
  // prior forward action before appending the freshly-derived one — otherwise
  // the server-added snapshot (which echoes back to the client in the next
  // body.actions) would duplicate on every re-push.
  const snap = {
    sourceTitle: "Q3",
    sourceAuthorName: "Alice",
    quotedContent: "> hi",
    sourceThreadId: "t1",
  };
  const expectedAction = { type: "forward", ...snap };

  it("appends a ForwardUserAction snapshot when none exists", () => {
    expect(withForwardSnapshot([], snap)).toEqual([expectedAction]);
  });

  it("treats null/undefined existing actions as empty", () => {
    expect(withForwardSnapshot(null, snap)).toEqual([expectedAction]);
    expect(withForwardSnapshot(undefined, snap)).toEqual([expectedAction]);
  });

  it("REPLACES an existing forward action instead of duplicating it (idempotence)", () => {
    const stale = {
      type: "forward",
      sourceTitle: "Old",
      sourceAuthorName: "Bob",
      quotedContent: "> old",
      sourceThreadId: "t0",
    };
    const actions = withForwardSnapshot([stale], snap);
    expect(actions).toHaveLength(1);
    expect(actions).toEqual([expectedAction]);
  });

  it("preserves other (non-forward) actions untouched, replacing only the forward one", () => {
    const external = { type: "external", title: "x", url: "https://x" };
    const stale = {
      type: "forward",
      sourceTitle: "Old",
      sourceAuthorName: "Bob",
      quotedContent: "> old",
      sourceThreadId: "t0",
    };
    const actions = withForwardSnapshot([external, stale], snap);
    expect(actions).toHaveLength(2);
    expect(actions).toEqual([external, expectedAction]);
  });
});

describe("noteVisibleUserIds", () => {
  // This is the Task-4 helper that bounds a SCOPED note's push/unread fan-out
  // to the users who can actually SEE the note: the author, plus anyone whose
  // contacts overlap access_contacts or whose groups overlap access_groups.
  // The SQL's group/contact overlap is enforced + covered by the DB layer
  // (pgTAP 42-scoped-note-bump-isolation); here we pin the JS behavior:
  // the helper maps rows and excludes the caller.

  it("returns the visible set minus the excluded (author) user", async () => {
    // The SQL returns the author and a Plot Team member as visible; the
    // bystander (announce-only) is NOT returned by the predicate, so it never
    // appears here. The author is then dropped by excludeUserId.
    const { db } = createRawDbStub([
      { user_id: "author-user" },
      { user_id: "team-member-user" },
    ]);

    const ids = await noteVisibleUserIds(
      db,
      "thread-1",
      "author-user", // createdBy
      null, // accessContacts
      ["team-group"], // accessGroups
      "author-user", // excludeUserId
    );

    // The scoped reply must NOT notify the announce-only bystander (it was
    // never in the visible set) and must NOT re-notify the author (excluded).
    expect(ids).not.toContain("bystander-user");
    expect(ids).not.toContain("author-user");
    // A Plot Team member IS in the visible set.
    expect(ids).toEqual(["team-member-user"]);
  });

  it("does not exclude the author when excludeUserId differs", async () => {
    const { db } = createRawDbStub([
      { user_id: "author-user" },
      { user_id: "team-member-user" },
    ]);

    const ids = await noteVisibleUserIds(
      db,
      "thread-1",
      "author-user",
      null,
      ["team-group"],
      "someone-else",
    );

    expect(ids).toEqual(["author-user", "team-member-user"]);
  });

  it("returns an empty array when no users can see the note", async () => {
    const { db } = createRawDbStub([]);
    const ids = await noteVisibleUserIds(
      db,
      "thread-1",
      "author-user",
      ["c1"],
      null,
      "author-user",
    );
    expect(ids).toEqual([]);
  });
});
