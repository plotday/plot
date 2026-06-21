import { beforeEach, describe, expect, it, vi } from "vitest";

import { analyzeNote, applyThreadState, classifyNote } from "./note-analysis";
import { bandToImportance } from "../state/importance/band";

// analyzeNote opens its own connection and resolves the opt-out via isAiEnabled
// before any LLM work; stub both so the early-return path runs without a DB.
vi.mock("../db", () => ({ createDb: () => ({ destroy: async () => {} }) }));
const isAiEnabledMock = vi.fn(async () => false);
vi.mock("../utils/ai-limits", () => ({
  isAiEnabled: (...args: unknown[]) => isAiEnabledMock(...(args as [])),
}));

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

// The engagement aggregate needs a DB; mock it so classifyNote tests run without
// one. Each test sets the engagement it wants the prompt/scorer to see.
const senderEngagementMock = vi.fn(async () => ({
  priorThreads: 0,
  readRate: null as number | null,
  archivedUnreadRate: null as number | null,
  replyRate: null as number | null,
}));
vi.mock("../state/importance/engagement", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return { ...actual, getSenderEngagement: (...a: unknown[]) => senderEngagementMock(...(a as [])) };
});

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

describe("analyzeNote built-in AI opt-out", () => {
  beforeEach(() => {
    upsertCalls.length = 0;
    isAiEnabledMock.mockClear();
  });

  it("returns false and writes no thread_state when AI is disabled", async () => {
    // Both enqueue paths funnel through analyzeNote; the updates.ts path only
    // checks the free-tier quota, so the opt-out must be enforced here.
    isAiEnabledMock.mockResolvedValueOnce(false);
    const handled = await analyzeNote(
      {} as any,
      "note-1",
      "thread-1",
      "user-1",
    );
    expect(handled).toBe(false);
    expect(upsertCalls).toHaveLength(0);
  });
});

// A minimal AI stub: returns whatever band/json we hand it.
function aiReturning(json: string) {
  return { run: vi.fn(async () => ({ response: json })) };
}

const baseContext = {
  noteId: "n1",
  noteCreatedAt: NOTE_SOURCE_CREATED_AT,
  noteSourceCreatedAt: NOTE_SOURCE_CREATED_AT,
  noteContent: "Big sale this week!",
  noteAuthorId: "c-sender",
  noteAuthorName: "Acme",
  noteAuthorEmail: "no-reply@acme.com",
  senderIsLinkedUser: false,
  threadTitle: "Acme deals",
  facets: { format: "promotion", automation: "automated", reach: "list" },
  links: [],
  members: [{ id: "c-r", name: "R", userId: "user-r" }],
  memberIds: new Set(["c-r"]),
  existingTodos: [],
  clearedTodos: [],
  existingReplies: [],
  recentNotes: [],
  memberEngagement: new Map(),
} as any;

describe("classifyNote suppression", () => {
  it("maps an elevated band to bandToImportance('elevated') > bandToImportance('normal')", async () => {
    const env = { AI: aiReturning('{"state":{"default":{"active":false,"urgent":false,"importance":"elevated","skip":false},"overrides":{}}}') } as any;
    const result = await classifyNote(env, baseContext);
    expect(result.state.default.importance).toBe(bandToImportance("elevated"));
    expect(result.state.default.importance).toBeGreaterThan(bandToImportance("normal"));
  });

  it("maps a suppress band below the gate", async () => {
    const env = { AI: aiReturning('{"state":{"default":{"active":false,"urgent":false,"importance":"suppress","skip":false},"overrides":{}}}') } as any;
    const result = await classifyNote(env, baseContext);
    expect(result.state.default.importance).toBeLessThan(50);
  });

  it("falls back to a sub-gate band on unparseable AI output for automated list mail", async () => {
    const env = { AI: aiReturning("not json at all") } as any;
    const result = await classifyNote(env, baseContext);
    expect(result.state.default.importance).toBeLessThan(50);
  });

  it("falls back to normal (surfaces) for ordinary mail when AI output is unparseable", async () => {
    const env = { AI: aiReturning("not json at all") } as any;
    const result = await classifyNote(env, {
      ...baseContext,
      noteAuthorEmail: "jane@gmail.com",
      facets: { format: "message", automation: "human", reach: "direct" },
    });
    expect(result.state.default.importance).toBeGreaterThanOrEqual(50);
  });
});
