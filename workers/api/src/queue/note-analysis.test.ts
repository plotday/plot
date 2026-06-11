import { beforeEach, describe, expect, it, vi } from "vitest";

import { applyThreadState } from "./note-analysis";

// Capture every rpcUser call so we can assert what applyThreadState writes to
// thread_state. The DB layer (upsert_thread_state) is covered separately; here
// we pin the API contract: the AI analysis path must mark analyzed recipients
// UNREAD, otherwise notes.ts's `analysisHandledUnread` short-circuit skips the
// fallback markThreadUnreadForOthers and the thread silently stays read.
// vi.mock is hoisted above the import by vitest, so the mock is in place
// before note-analysis.ts binds rpcUser.
const upsertCalls: Array<{ fn: string; args: any }> = [];
vi.mock("../rpc", () => ({
  rpcUser: vi.fn(async (_db: unknown, fn: string, args: unknown) => {
    upsertCalls.push({ fn, args });
    return {};
  }),
}));

const NOTE_SOURCE_CREATED_AT = new Date("2026-06-11T20:11:07.862Z");

function classification(
  partial: Partial<{
    active: boolean;
    urgent: boolean;
    importance: number;
    skip: boolean;
  }>,
) {
  return {
    default: {
      active: false,
      urgent: false,
      importance: 50,
      skip: false,
      ...partial,
    },
    overrides: {},
  };
}

describe("applyThreadState", () => {
  beforeEach(() => {
    upsertCalls.length = 0;
  });

  it("marks the thread unread (read_at -> NULL) for analyzed recipients", async () => {
    // A recipient who previously read this thread already has a thread_state
    // row with read_at set. The AI path must reset read_at to NULL so the new
    // reply re-surfaces in Updates and qualifies for a push.
    await applyThreadState(
      {} as any,
      {} as any,
      "thread-1",
      "user-author",
      [{ id: "contact-recipient", name: "Recipient", userId: "user-recipient" }],
      classification({ importance: 80 }),
      NOTE_SOURCE_CREATED_AT,
    );

    expect(upsertCalls).toHaveLength(1);
    const { fn, args } = upsertCalls[0];
    expect(fn).toBe("upsert_thread_state");
    // Opt in to writing read_at, with read_at NULL = "mark unread".
    expect(args.p_set_read_at).toBe(true);
    expect(args.p_read_at ?? null).toBeNull();
    // The race guard must accompany it so a recipient who has already read
    // PAST this note isn't incorrectly re-marked unread.
    expect(args.p_note_created_at).toBe(NOTE_SOURCE_CREATED_AT.toISOString());
  });

  it("writes no thread_state row for skipped (passive) recipients", async () => {
    await applyThreadState(
      {} as any,
      {} as any,
      "thread-1",
      "user-author",
      [{ id: "contact-recipient", name: null, userId: "user-recipient" }],
      classification({ skip: true }),
      NOTE_SOURCE_CREATED_AT,
    );

    expect(upsertCalls).toHaveLength(0);
  });

  it("never marks the note author unread", async () => {
    await applyThreadState(
      {} as any,
      {} as any,
      "thread-1",
      "user-author",
      [{ id: "contact-author", name: null, userId: "user-author" }],
      classification({ importance: 80 }),
      NOTE_SOURCE_CREATED_AT,
    );

    expect(upsertCalls).toHaveLength(0);
  });
});
