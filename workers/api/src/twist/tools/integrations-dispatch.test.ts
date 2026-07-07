import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// Unit tests for Integrations.dispatch's note-reply routing. dispatch only
// touches this.sourceProvider, this.twistInstanceId and this.db (via the
// private buildNoteAndThread helper), so we exercise it against a mock `this`
// rather than constructing a full Integrations instance.

const CONNECTOR = "connector-instance-id";
const USER = "user-id";

/** Minimal chainable Kysely stub whose terminal query returns `linkRow`. */
function mockDb(linkRow: unknown) {
  const chain: any = {
    selectFrom: () => chain,
    select: () => chain,
    where: () => chain,
    executeTakeFirst: async () => linkRow,
  };
  return chain;
}

function makeThis(linkRow: unknown) {
  return {
    sourceProvider: { provider: "slack" },
    twistInstanceId: CONNECTOR,
    db: mockDb(linkRow),
    // buildNoteAndThread is a prototype method; attach it so `this.x` resolves
    // when we invoke dispatch with a plain-object `this`.
    buildNoteAndThread: (Integrations.prototype as any).buildNoteAndThread,
    loadThreadAccessContacts: (Integrations.prototype as any)
      .loadThreadAccessContacts,
    // buildNoteAndThread resolves note.recipients; recipient resolution is
    // covered by integrations-note-recipients.test.ts, so stub it here.
    resolveNoteRecipients: async () => null,
    // dispatch also calls enrichTagActors (hydrates note.tagActors from the DB).
    // These routing tests don't assert enrichment — that's covered by
    // integrations.tagactors.test.ts — so stub it as a no-op.
    enrichTagActors: async () => {},
  } as any;
}

/**
 * Table-aware Kysely stub. `executeTakeFirst()` returns `link` for the link
 * lookup and `thread` for the thread roster lookup; `execute()` returns the
 * `contacts` rows for the contact lookup. Lets us exercise the
 * thread.accessContacts resolution path inside buildNoteAndThread.
 */
function mockDbByTable(tables: {
  link?: unknown;
  thread?: unknown;
  contact?: unknown[];
  note?: unknown;
}) {
  function chain(table?: string): any {
    return {
      selectFrom: (t: string) => chain(t),
      select: () => chain(table),
      where: () => chain(table),
      executeTakeFirst: async () =>
        table === "link"
          ? tables.link
          : table === "thread"
          ? tables.thread
          : table === "note"
          ? tables.note
          : undefined,
      execute: async () => (table === "contact" ? tables.contact ?? [] : []),
    };
  }
  return chain();
}

function makeThisMulti(tables: Parameters<typeof mockDbByTable>[0]) {
  return {
    sourceProvider: { provider: "slack" },
    twistInstanceId: CONNECTOR,
    db: mockDbByTable(tables),
    buildNoteAndThread: (Integrations.prototype as any).buildNoteAndThread,
    loadThreadAccessContacts: (Integrations.prototype as any)
      .loadThreadAccessContacts,
    // See makeThis: recipient resolution is covered separately; stub it.
    resolveNoteRecipients: async () => null,
    // See makeThis: dispatch calls enrichTagActors; not asserted here.
    enrichTagActors: async () => {},
  } as any;
}

const dispatch = (self: any, dispatchItem: any) =>
  (Integrations.prototype as any).dispatch.call(self, dispatchItem);

describe("Integrations.dispatch — note reply routing", () => {
  it("dispatches onNoteCreated for a reply on a Plot-initiated thread (thread created by user, connector owns the link)", async () => {
    // Regression: a thread started in Plot and composed to Slack is created_by
    // the user, while the Slack connector only created the link via onCreateLink.
    // The reply mentions the connector but threadCreatedByThis is false.
    const self = makeThis({
      meta: { threadTs: "1780782501.200199" },
      channel_id: "C0AUU2E1Z28",
      source: "slack:channel:C0AUU2E1Z28:ts:1780782501.200199",
    });

    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: USER, // user created the thread, NOT the connector
        created_by: USER,
        author_id: USER,
        mentions: [CONNECTOR],
        content: "Pretty well!",
      },
    });

    expect(result).toHaveLength(1);
    expect(result[0].sourceMethod).toBe("onNoteCreated");
    // meta.channelId resolved from the connector's link → reply can be routed.
    expect(result[0].args[1].meta.channelId).toBe("C0AUU2E1Z28");
  });

  it("dispatches onNoteCreated for a reply on a connector-created (synced) thread", async () => {
    const self = makeThis({
      meta: {},
      channel_id: "C0AUU2E1Z28",
      source: "slack:channel:C0AUU2E1Z28:ts:1.2",
    });

    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: CONNECTOR, // connector synced the thread
        created_by: USER,
        author_id: USER,
        mentions: [CONNECTOR],
        content: "reply",
      },
    });

    expect(result).toHaveLength(1);
    expect(result[0].sourceMethod).toBe("onNoteCreated");
  });

  it("does not dispatch when the connector neither created the thread nor owns a link", async () => {
    const self = makeThis(undefined); // no link owned by this connector
    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: USER,
        created_by: USER,
        author_id: USER,
        mentions: [CONNECTOR],
        content: "reply",
      },
    });
    expect(result).toEqual([]);
  });

  it("does not dispatch onNoteCreated for an archived note (archiving must not re-send)", async () => {
    // Regression: the create view is seq-cursor driven, so archiving a note
    // re-surfaces it as a "new note". Without this guard, archiving a note —
    // possibly one that never sent — re-fires onNoteCreated and sends it.
    const self = makeThis({ meta: {}, channel_id: "C1", source: "s" });
    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: CONNECTOR,
        created_by: USER,
        author_id: USER,
        mentions: [CONNECTOR],
        archived_at: "2026-06-11T19:51:11Z",
        content: "Good idea. I've added a couple of those",
      },
    });
    expect(result).toEqual([]);
  });

  it("does not dispatch when the note does not mention the connector", async () => {
    const self = makeThis({ meta: {}, channel_id: "C1", source: "s" });
    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: USER,
        created_by: USER,
        author_id: USER,
        mentions: [],
        content: "reply",
      },
    });
    expect(result).toEqual([]);
  });

  it("populates thread.accessContacts (id→email) so connectors can resolve a note's accessContacts to outbound addresses", async () => {
    // Regression: the message-mode invariant fills an email reply's
    // access_contacts with the full thread roster. The Gmail connector then
    // resolves those IDs to emails via thread.accessContacts. When the
    // dispatch left thread.accessContacts undefined, the allow-set was empty
    // and every recipient was filtered out ("no outbound recipients").
    const self = makeThisMulti({
      link: { meta: {}, channel_id: "INBOX", source: "gmail:thread:1" },
      thread: { contacts: ["c-self", "c-recipient"] },
      contact: [
        { id: "c-self", email: "me@plot.day", name: "Me" },
        { id: "c-recipient", email: "them@gmail.com", name: "Them" },
      ],
    });

    const result = await dispatch(self, {
      itemType: "note",
      isCreate: true,
      item: {
        id: "note-9",
        thread_id: "thread-1",
        thread_created_by: CONNECTOR,
        created_by: USER,
        author_id: USER,
        mentions: [CONNECTOR],
        access_contacts: ["c-self", "c-recipient"],
        content: "reply to all",
      },
    });

    expect(result).toHaveLength(1);
    expect(result[0].sourceMethod).toBe("onNoteCreated");
    const thread = result[0].args[1];
    expect(thread.accessContacts).toEqual([
      { id: "c-self", email: "me@plot.day", name: "Me" },
      { id: "c-recipient", email: "them@gmail.com", name: "Them" },
    ]);
  });

  it("channel_note path skips notes that mention the connector (handled by mention path; avoids double-post)", async () => {
    const self = makeThis({ meta: {}, channel_id: "C1", source: "s" });
    const result = await dispatch(self, {
      itemType: "channel_note",
      isCreate: true,
      item: {
        id: "note-2",
        thread_id: "thread-1",
        thread_created_by: USER,
        created_by: USER,
        author_id: USER,
        updated_by: 1, // genuine user write
        mentions: [CONNECTOR],
        content: "reply",
      },
    });
    expect(result).toEqual([]);
  });
});
