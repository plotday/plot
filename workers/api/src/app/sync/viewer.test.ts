import { describe, expect, it, vi } from "vitest";

import {
  stripAnnounceContactsFromThreads,
  stripAnnounceTagActors,
} from "./viewer";

type MockTable =
  | { table: "thread"; rows: Array<{ id: string; contacts: string[]; groups: string[] }> }
  | { table: "group"; rows: Array<{ id: string; type: string }> }
  | { table: "group_admin"; rows: Array<{ user_id: string; group_id: string }> }
  | { table: "group_member"; rows: Array<{ group_id: string; contact_id: string }> }
  | { table: "user_contact"; rows: Array<{ user_id: string; contact_id: string; linked: boolean; archived_at: Date | null }> }
  | { table: "note"; rows: Array<{ id: string; thread_id: string }> };

function createMockDb(tables: MockTable[]) {
  const byTable = new Map<string, any[]>();
  for (const t of tables) byTable.set(t.table, t.rows);

  function selectFrom(table: string) {
    let rows = (byTable.get(table) ?? []).slice();
    const filters: Array<(r: any) => boolean> = [];

    const q: any = {};
    q.select = vi.fn(() => q);
    q.where = vi.fn((col: string, op: string, val: any) => {
      filters.push((r) => {
        const v = r[col];
        if (op === "=") return v === val;
        if (op === "in") return Array.isArray(val) && val.includes(v);
        if (op === "is" && val === null) return v === null || v === undefined;
        if (op === "is not" && val === null) return v !== null && v !== undefined;
        return true;
      });
      return q;
    });
    q.execute = vi.fn(async () => rows.filter((r) => filters.every((f) => f(r))));
    return q;
  }

  return { selectFrom };
}

describe("stripAnnounceContactsFromThreads", () => {
  it("hides contacts that are members of an announce group on the thread", async () => {
    const db = createMockDb([
      {
        table: "thread",
        rows: [
          {
            id: "t1",
            contacts: ["c-self", "c-direct", "c-announce-only"],
            groups: ["g-announce"],
          },
        ],
      },
      { table: "group", rows: [{ id: "g-announce", type: "announce" }] },
      { table: "group_admin", rows: [] },
      {
        table: "group_member",
        rows: [
          { group_id: "g-announce", contact_id: "c-announce-only" },
          { group_id: "g-announce", contact_id: "c-other" },
        ],
      },
      {
        table: "user_contact",
        rows: [
          { user_id: "u1", contact_id: "c-self", linked: true, archived_at: null },
        ],
      },
    ]);

    const rows = [
      { id: "t1", contacts: ["c-self", "c-direct", "c-announce-only"], groups: ["g-announce"] },
    ];
    await stripAnnounceContactsFromThreads(db as any, "u1", rows);

    expect(rows[0].contacts).toEqual(["c-self", "c-direct"]);
  });

  it("keeps the user's own contact even when it's an announce group member", async () => {
    const db = createMockDb([
      {
        table: "thread",
        rows: [{ id: "t1", contacts: ["c-self"], groups: ["g-announce"] }],
      },
      { table: "group", rows: [{ id: "g-announce", type: "announce" }] },
      { table: "group_admin", rows: [] },
      { table: "group_member", rows: [{ group_id: "g-announce", contact_id: "c-self" }] },
      {
        table: "user_contact",
        rows: [
          { user_id: "u1", contact_id: "c-self", linked: true, archived_at: null },
        ],
      },
    ]);
    const rows = [{ id: "t1", contacts: ["c-self"], groups: ["g-announce"] }];
    await stripAnnounceContactsFromThreads(db as any, "u1", rows);
    expect(rows[0].contacts).toEqual(["c-self"]);
  });

  it("does not filter when the user is admin of the announce group", async () => {
    const db = createMockDb([
      {
        table: "thread",
        rows: [
          {
            id: "t1",
            contacts: ["c-direct", "c-announce-only"],
            groups: ["g-announce"],
          },
        ],
      },
      { table: "group", rows: [{ id: "g-announce", type: "announce" }] },
      {
        table: "group_admin",
        rows: [{ user_id: "u1", group_id: "g-announce" }],
      },
      {
        table: "group_member",
        rows: [{ group_id: "g-announce", contact_id: "c-announce-only" }],
      },
      { table: "user_contact", rows: [] },
    ]);
    const rows = [
      { id: "t1", contacts: ["c-direct", "c-announce-only"], groups: ["g-announce"] },
    ];
    await stripAnnounceContactsFromThreads(db as any, "u1", rows);
    expect(rows[0].contacts).toEqual(["c-direct", "c-announce-only"]);
  });

  it("does not filter threads with no announce group", async () => {
    const db = createMockDb([
      {
        table: "thread",
        rows: [{ id: "t1", contacts: ["c-a", "c-b"], groups: ["g-public"] }],
      },
      { table: "group", rows: [{ id: "g-public", type: "public" }] },
      { table: "group_admin", rows: [] },
      { table: "group_member", rows: [{ group_id: "g-public", contact_id: "c-extra" }] },
      { table: "user_contact", rows: [] },
    ]);
    const rows = [{ id: "t1", contacts: ["c-a", "c-b"], groups: ["g-public"] }];
    await stripAnnounceContactsFromThreads(db as any, "u1", rows);
    expect(rows[0].contacts).toEqual(["c-a", "c-b"]);
  });

  it("keeps a contact that's also in a non-announce group on the thread", async () => {
    const db = createMockDb([
      {
        table: "thread",
        rows: [
          {
            id: "t1",
            contacts: ["c-shared"],
            groups: ["g-announce", "g-public"],
          },
        ],
      },
      {
        table: "group",
        rows: [
          { id: "g-announce", type: "announce" },
          { id: "g-public", type: "public" },
        ],
      },
      { table: "group_admin", rows: [] },
      {
        table: "group_member",
        rows: [
          { group_id: "g-announce", contact_id: "c-shared" },
          { group_id: "g-public", contact_id: "c-shared" },
        ],
      },
      { table: "user_contact", rows: [] },
    ]);
    const rows = [
      { id: "t1", contacts: ["c-shared"], groups: ["g-announce", "g-public"] },
    ];
    await stripAnnounceContactsFromThreads(db as any, "u1", rows);
    expect(rows[0].contacts).toEqual(["c-shared"]);
  });
});

describe("stripAnnounceTagActors", () => {
  it("filters note tag actors to only contacts visible in thread.contacts", async () => {
    const db = createMockDb([
      {
        table: "note",
        rows: [{ id: "n1", thread_id: "t1" }],
      },
      {
        table: "thread",
        rows: [
          {
            id: "t1",
            contacts: ["c-self", "c-direct", "c-announce-also"],
            groups: ["g-announce"],
          },
        ],
      },
      { table: "group", rows: [{ id: "g-announce", type: "announce" }] },
      { table: "group_admin", rows: [] },
      {
        table: "group_member",
        rows: [
          { group_id: "g-announce", contact_id: "c-announce-also" },
          { group_id: "g-announce", contact_id: "c-leak-1" },
          { group_id: "g-announce", contact_id: "c-leak-2" },
        ],
      },
      {
        table: "user_contact",
        rows: [
          { user_id: "u1", contact_id: "c-self", linked: true, archived_at: null },
        ],
      },
    ]);

    const rows = [
      {
        id: "n1",
        tags: {
          // Todo tag: actors include the announce group leak
          "1": ["c-self", "c-direct", "c-leak-1", "c-leak-2"],
        },
      },
    ];

    await stripAnnounceTagActors(db as any, "u1", rows, "note", 0);

    // c-leak-1 and c-leak-2 are members of an announce group and not in
    // thread.contacts (after filtering), so they must be stripped.
    expect(rows[0].tags).toEqual({ "1": ["c-self", "c-direct"] });
  });

  it("preserves count when apiVersion >= 2", async () => {
    const db = createMockDb([
      { table: "note", rows: [{ id: "n1", thread_id: "t1" }] },
      {
        table: "thread",
        rows: [
          { id: "t1", contacts: ["c-direct"], groups: ["g-announce"] },
        ],
      },
      { table: "group", rows: [{ id: "g-announce", type: "announce" }] },
      { table: "group_admin", rows: [] },
      {
        table: "group_member",
        rows: [{ group_id: "g-announce", contact_id: "c-leak" }],
      },
      { table: "user_contact", rows: [] },
    ]);

    const rows = [
      { id: "n1", tags: { "1": ["c-direct", "c-leak"] } },
    ];
    await stripAnnounceTagActors(db as any, "u1", rows, "note", 2);
    expect(rows[0].tags).toEqual({ "1": { c: 2, a: ["c-direct"] } });
  });
});
