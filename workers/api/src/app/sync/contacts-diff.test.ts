import { describe, expect, it } from "vitest";

import {
  computeContactsDiff,
  newlyAddedMemberIds,
  type ContactsSnapshot,
} from "./contacts-diff";

const A = "00000000-0000-0000-0000-00000000000a";
const B = "00000000-0000-0000-0000-00000000000b";
const C = "00000000-0000-0000-0000-00000000000c";

function snap(
  contacts: string[],
  opts: {
    dropped?: string[];
    roles?: Record<string, string>;
  } = {},
): ContactsSnapshot {
  const contactMeta: Record<string, unknown> = {};
  for (const [id, role] of Object.entries(opts.roles ?? {})) {
    contactMeta[id] = { role };
  }
  return {
    contacts,
    droppedContacts: opts.dropped ?? [],
    contactMeta,
  };
}

describe("computeContactsDiff", () => {
  it("reports no changes when membership and roles are identical", () => {
    const s = snap([A, B], { roles: { [A]: "to", [B]: "cc" } });
    const diff = computeContactsDiff(s, s);
    expect(diff).toEqual({ added: [], removed: [], changed: [] });
  });

  it("reports an added contact with a null role when none is set", () => {
    const diff = computeContactsDiff(snap([A]), snap([A, B]));
    expect(diff.added).toEqual([{ contactId: B, role: null }]);
    expect(diff.removed).toEqual([]);
    expect(diff.changed).toEqual([]);
  });

  it("reports an added contact carrying its role from contact_meta", () => {
    const diff = computeContactsDiff(snap([A]), snap([A, B], { roles: { [B]: "cc" } }));
    expect(diff.added).toEqual([{ contactId: B, role: "cc" }]);
  });

  it("reports a removed contact with the role it had before removal", () => {
    const diff = computeContactsDiff(snap([A, B], { roles: { [B]: "bcc" } }), snap([A]));
    expect(diff.removed).toEqual([{ contactId: B, role: "bcc" }]);
    expect(diff.added).toEqual([]);
    expect(diff.changed).toEqual([]);
  });

  it("treats a message-mode drop (still in contacts, now dropped) as a removal", () => {
    const prev = snap([A, B], { roles: { [B]: "to" } });
    const next = snap([A, B], { dropped: [B], roles: { [B]: "to" } });
    const diff = computeContactsDiff(prev, next);
    expect(diff.removed).toEqual([{ contactId: B, role: "to" }]);
    expect(diff.added).toEqual([]);
  });

  it("treats an undrop (was dropped, now active) as an addition", () => {
    const prev = snap([A, B], { dropped: [B] });
    const next = snap([A, B]);
    const diff = computeContactsDiff(prev, next);
    expect(diff.added).toEqual([{ contactId: B, role: null }]);
    expect(diff.removed).toEqual([]);
  });

  it("reports a role change as a from/to transition without add/remove", () => {
    const prev = snap([A, B], { roles: { [B]: "to" } });
    const next = snap([A, B], { roles: { [B]: "cc" } });
    const diff = computeContactsDiff(prev, next);
    expect(diff.changed).toEqual([{ contactId: B, from: "to", to: "cc" }]);
    expect(diff.added).toEqual([]);
    expect(diff.removed).toEqual([]);
  });

  it("reports gaining a role (null -> value) and losing a role (value -> null) as changes", () => {
    const gain = computeContactsDiff(snap([A]), snap([A], { roles: { [A]: "cc" } }));
    expect(gain.changed).toEqual([{ contactId: A, from: null, to: "cc" }]);

    const lose = computeContactsDiff(snap([A], { roles: { [A]: "cc" } }), snap([A]));
    expect(lose.changed).toEqual([{ contactId: A, from: "cc", to: null }]);
  });

  it("handles simultaneous add, remove, and role change deterministically", () => {
    const prev = snap([A, B], { roles: { [A]: "to", [B]: "to" } });
    const next = snap([A, C], { roles: { [A]: "cc", [C]: "to" } });
    const diff = computeContactsDiff(prev, next);
    expect(diff.added).toEqual([{ contactId: C, role: "to" }]);
    expect(diff.removed).toEqual([{ contactId: B, role: "to" }]);
    expect(diff.changed).toEqual([{ contactId: A, from: "to", to: "cc" }]);
  });

  it("ignores non-object contact_meta entries (role resolves to null)", () => {
    const prev: ContactsSnapshot = { contacts: [A], droppedContacts: [], contactMeta: { [A]: "garbage" } };
    const next: ContactsSnapshot = { contacts: [A, B], droppedContacts: [], contactMeta: { [B]: null } };
    const diff = computeContactsDiff(prev, next);
    expect(diff.added).toEqual([{ contactId: B, role: null }]);
    expect(diff.changed).toEqual([]);
  });
});

describe("newlyAddedMemberIds", () => {
  it("treats a brand-new thread (prev null) as adding all effective members", () => {
    // A new thread doesn't exist server-side before its first sync, so there
    // is no prior snapshot — every contact on it is newly added and is an
    // invitation candidate.
    expect(newlyAddedMemberIds(null, snap([A, B]))).toEqual([A, B]);
  });

  it("excludes dropped contacts from a brand-new thread's added members", () => {
    expect(newlyAddedMemberIds(null, snap([A, B], { dropped: [B] }))).toEqual([A]);
  });

  it("returns nothing when a thread is re-saved with unchanged contacts", () => {
    // The critical regression guard: re-saving (title edit, priority move,
    // marking read) must never re-invite contacts already on the thread.
    const s = snap([A, B], { roles: { [A]: "to", [B]: "cc" } });
    expect(newlyAddedMemberIds(s, s)).toEqual([]);
  });

  it("returns only the newly added contact when one is added to an existing thread", () => {
    expect(newlyAddedMemberIds(snap([A]), snap([A, B]))).toEqual([B]);
  });

  it("returns nothing when contacts are only removed", () => {
    expect(newlyAddedMemberIds(snap([A, B]), snap([A]))).toEqual([]);
  });

  it("treats an undrop (was dropped, now active) as a newly added member", () => {
    expect(newlyAddedMemberIds(snap([A, B], { dropped: [B] }), snap([A, B]))).toEqual([B]);
  });

  it("ignores a role-only change (no membership addition)", () => {
    const prev = snap([A, B], { roles: { [B]: "to" } });
    const next = snap([A, B], { roles: { [B]: "cc" } });
    expect(newlyAddedMemberIds(prev, next)).toEqual([]);
  });
});
