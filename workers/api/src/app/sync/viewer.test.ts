import { describe, expect, it, vi } from "vitest";

import {
  computeHiddenRoleStrip,
  stripAnnounceContactsFromThreads,
  stripAnnounceTagActors,
  stripHiddenRoleContactsFromThreads,
} from "./viewer";

type MockTable =
  | { table: "thread"; rows: Array<{ id: string; contacts: string[]; groups: string[] }> }
  | { table: "group"; rows: Array<{ id: string; type: string }> }
  | { table: "group_admin"; rows: Array<{ user_id: string; group_id: string }> }
  | { table: "group_member"; rows: Array<{ group_id: string; contact_id: string }> }
  | { table: "user_contact"; rows: Array<{ user_id: string; contact_id: string; linked: boolean; archived_at: Date | null }> }
  | { table: "note"; rows: Array<{ id: string; thread_id: string }> }
  | { table: "link"; rows: Array<{ thread_id: string; type: string; channel_id: string | null; created_by: string | null }> }
  | { table: "channel"; rows: Array<{ twist_instance_id: string; channel_id: string; link_types: unknown }> }
  | { table: "twist_instance"; rows: Array<{ id: string; permissions: unknown }> };

function createMockDb(tables: MockTable[]) {
  const byTable = new Map<string, any[]>();
  for (const t of tables) byTable.set(t.table, t.rows);

  function selectFrom(table: string) {
    let rows = (byTable.get(table) ?? []).slice();
    const filters: Array<(r: any) => boolean> = [];

    const q: any = {};
    q.select = vi.fn(() => q);
    // Joins are no-ops: mock tables are pre-joined (rows already carry any
    // columns referenced via `alias`-style selects).
    q.innerJoin = vi.fn(() => q);
    q.where = vi.fn((col: string, op: string, val: any) => {
      // Accept table-qualified columns (e.g. "twist_instance.id").
      const key = col.includes(".") ? col.split(".").pop()! : col;
      filters.push((r) => {
        const v = r[key];
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

/** Build a link_types config carrying a hidden `bcc` role on the email type. */
function emailLinkTypes() {
  return [
    {
      type: "email",
      contactRoles: [
        { id: "to", label: "To", default: true },
        { id: "cc", label: "CC" },
        { id: "bcc", label: "BCC", hidden: true },
      ],
    },
  ];
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

describe("computeHiddenRoleStrip", () => {
  const HIDDEN = new Set(["bcc"]);

  it("hides a BCC contact from an unrelated viewer", () => {
    const res = computeHiddenRoleStrip(
      ["alice", "bob", "carol"],
      {
        alice: { role: "to", addedBy: "sender-user" },
        carol: { role: "bcc", addedBy: "sender-user" },
      },
      HIDDEN,
      new Set(["bob"]), // viewer is Bob (a To/Cc recipient)
      "bob-user",
    );
    expect(res.changed).toBe(true);
    expect(res.contacts).toEqual(["alice", "bob"]);
    expect(res.meta).toEqual({ alice: { role: "to", addedBy: "sender-user" } });
  });

  it("keeps the BCC contact for the BCC recipient themselves", () => {
    const res = computeHiddenRoleStrip(
      ["alice", "carol"],
      {
        alice: { role: "to", addedBy: "sender-user" },
        carol: { role: "bcc", addedBy: "sender-user" },
      },
      HIDDEN,
      new Set(["carol"]), // viewer IS Carol (the BCC'd contact)
      "carol-user",
    );
    expect(res.changed).toBe(false);
    expect(res.contacts).toEqual(["alice", "carol"]);
  });

  it("keeps the BCC contact for the user who added them (sender)", () => {
    const res = computeHiddenRoleStrip(
      ["alice", "carol"],
      { carol: { role: "bcc", addedBy: "sender-user" } },
      HIDDEN,
      new Set(["alice"]), // sender's own linked contact is alice, not carol
      "sender-user", // viewer is the addedBy user
    );
    expect(res.changed).toBe(false);
    expect(res.contacts).toEqual(["alice", "carol"]);
  });

  it("leaves non-hidden roles untouched", () => {
    const res = computeHiddenRoleStrip(
      ["alice", "bob"],
      {
        alice: { role: "to", addedBy: "sender-user" },
        bob: { role: "cc", addedBy: "sender-user" },
      },
      HIDDEN,
      new Set<string>(),
      "viewer-user",
    );
    expect(res.changed).toBe(false);
    expect(res.contacts).toEqual(["alice", "bob"]);
  });

  it("hides multiple BCC contacts at once", () => {
    const res = computeHiddenRoleStrip(
      ["alice", "carol", "dave"],
      {
        alice: { role: "to", addedBy: "sender-user" },
        carol: { role: "bcc", addedBy: "sender-user" },
        dave: { role: "bcc", addedBy: "sender-user" },
      },
      HIDDEN,
      new Set<string>(),
      "viewer-user",
    );
    expect(res.changed).toBe(true);
    expect(res.contacts).toEqual(["alice"]);
    expect(res.meta).toEqual({ alice: { role: "to", addedBy: "sender-user" } });
  });

  it("treats a missing addedBy as not-the-adder (still hidden)", () => {
    const res = computeHiddenRoleStrip(
      ["carol"],
      { carol: { role: "bcc" } },
      HIDDEN,
      new Set<string>(),
      "viewer-user",
    );
    expect(res.changed).toBe(true);
    expect(res.contacts).toEqual([]);
    expect(res.meta).toEqual({});
  });
});

describe("stripHiddenRoleContactsFromThreads", () => {
  it("strips a BCC contact (channel-level config) from an unrelated viewer", async () => {
    const db = createMockDb([
      {
        table: "link",
        rows: [
          { thread_id: "t1", type: "email", channel_id: "INBOX", created_by: "ti1" },
        ],
      },
      {
        table: "channel",
        rows: [
          { twist_instance_id: "ti1", channel_id: "INBOX", link_types: emailLinkTypes() },
        ],
      },
      { table: "twist_instance", rows: [] },
      {
        table: "user_contact",
        rows: [
          { user_id: "u1", contact_id: "bob", linked: true, archived_at: null },
        ],
      },
    ]);

    const rows = [
      {
        id: "t1",
        contacts: ["alice", "bob", "carol"],
        contact_meta: {
          alice: { role: "to", addedBy: "sender-user" },
          carol: { role: "bcc", addedBy: "sender-user" },
        },
      },
    ];
    await stripHiddenRoleContactsFromThreads(db as any, "u1", rows as any);

    expect(rows[0].contacts).toEqual(["alice", "bob"]);
    expect(rows[0].contact_meta).toEqual({
      alice: { role: "to", addedBy: "sender-user" },
    });
  });

  it("keeps the BCC contact for the BCC recipient themselves", async () => {
    const db = createMockDb([
      {
        table: "link",
        rows: [
          { thread_id: "t1", type: "email", channel_id: "INBOX", created_by: "ti1" },
        ],
      },
      {
        table: "channel",
        rows: [
          { twist_instance_id: "ti1", channel_id: "INBOX", link_types: emailLinkTypes() },
        ],
      },
      { table: "twist_instance", rows: [] },
      {
        table: "user_contact",
        rows: [
          { user_id: "u1", contact_id: "carol", linked: true, archived_at: null },
        ],
      },
    ]);

    const rows = [
      {
        id: "t1",
        contacts: ["alice", "carol"],
        contact_meta: {
          alice: { role: "to", addedBy: "sender-user" },
          carol: { role: "bcc", addedBy: "sender-user" },
        },
      },
    ];
    await stripHiddenRoleContactsFromThreads(db as any, "u1", rows as any);

    expect(rows[0].contacts).toEqual(["alice", "carol"]);
  });

  it("resolves hidden roles from twist-level permissions when channel has none", async () => {
    const db = createMockDb([
      {
        table: "link",
        rows: [
          { thread_id: "t1", type: "email", channel_id: null, created_by: "ti1" },
        ],
      },
      { table: "channel", rows: [] },
      {
        table: "twist_instance",
        rows: [
          { id: "ti1", permissions: { _providers: [{ linkTypes: emailLinkTypes() }] } },
        ],
      },
      { table: "user_contact", rows: [] },
    ]);

    const rows = [
      {
        id: "t1",
        contacts: ["alice", "carol"],
        contact_meta: {
          alice: { role: "to", addedBy: "sender-user" },
          carol: { role: "bcc", addedBy: "sender-user" },
        },
      },
    ];
    await stripHiddenRoleContactsFromThreads(db as any, "u1", rows as any);

    expect(rows[0].contacts).toEqual(["alice"]);
    expect(rows[0].contact_meta).toEqual({
      alice: { role: "to", addedBy: "sender-user" },
    });
  });

  it("does nothing for threads with no role-bearing contact_meta", async () => {
    const db = createMockDb([
      { table: "link", rows: [] },
      { table: "channel", rows: [] },
      { table: "twist_instance", rows: [] },
      { table: "user_contact", rows: [] },
    ]);
    const rows = [
      { id: "t1", contacts: ["alice", "bob"], contact_meta: {} },
    ];
    await stripHiddenRoleContactsFromThreads(db as any, "u1", rows as any);
    expect(rows[0].contacts).toEqual(["alice", "bob"]);
    expect(rows[0].contact_meta).toEqual({});
  });
});
