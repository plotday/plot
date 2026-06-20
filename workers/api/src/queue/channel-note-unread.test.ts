import { beforeEach, describe, expect, it, vi } from "vitest";

import { markChannelNoteUnreadFallback } from "./channel-note-unread";

// markThreadUnreadForOthers lives in the (heavy) notes sync module and queries
// the DB before delegating to upsert_thread_state. We only care about HOW the
// channel-note fallback invokes it, so mock the module wholesale and capture
// the arguments. vi.mock is hoisted above the imports, so the helper under test
// binds the mock; the factory references the spy lazily (it isn't initialised
// when the hoisted mock runs).
const markThreadUnreadForOthersMock = vi.fn(async () => [] as string[]);
vi.mock("../app/sync/notes", () => ({
  markThreadUnreadForOthers: (...args: unknown[]) =>
    markThreadUnreadForOthersMock(...(args as [])),
}));

const NOTE_SOURCE_CREATED_AT = "2026-06-18T09:16:30.000Z";

describe("markChannelNoteUnreadFallback", () => {
  beforeEach(() => {
    markThreadUnreadForOthersMock.mockClear();
  });

  it("forwards the note's source_created_at as the unread race guard", async () => {
    // A recipient who already read this thread AFTER the note arrived has a
    // thread_state row with read_at set. Re-dispatching the same incoming note
    // (connector re-sync / seq bump / retry) must NOT clobber that read, so the
    // fallback must pass the note's source time through to upsert_thread_state's
    // race guard. Without it, read_at is nulled unconditionally and the thread
    // re-appears unread on every device.
    const env = {} as any;
    const db = {} as any;
    const note = {
      thread_id: "thread-1",
      source_created_at: NOTE_SOURCE_CREATED_AT,
    };

    await markChannelNoteUnreadFallback(env, db, note, "owner-1", false);

    expect(markThreadUnreadForOthersMock).toHaveBeenCalledTimes(1);
    expect(markThreadUnreadForOthersMock).toHaveBeenCalledWith(
      env,
      db,
      "thread-1",
      "owner-1",
      NOTE_SOURCE_CREATED_AT,
    );
  });

  it("does nothing when AI analysis already handled the unread signal", async () => {
    await markChannelNoteUnreadFallback(
      {} as any,
      {} as any,
      { thread_id: "thread-1", source_created_at: NOTE_SOURCE_CREATED_AT },
      "owner-1",
      true,
    );

    expect(markThreadUnreadForOthersMock).not.toHaveBeenCalled();
  });

  it("does nothing when the note has no thread", async () => {
    await markChannelNoteUnreadFallback(
      {} as any,
      {} as any,
      { thread_id: null, source_created_at: NOTE_SOURCE_CREATED_AT },
      "owner-1",
      false,
    );

    expect(markThreadUnreadForOthersMock).not.toHaveBeenCalled();
  });
});
