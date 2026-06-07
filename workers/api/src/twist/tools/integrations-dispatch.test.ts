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
