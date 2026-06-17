import { Hono } from "hono";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { parseReadParams, readSafeHorizon, seqEnvelope, seqSinceCursor } from "./helpers";
import { fetchNoteTagsBySeq } from "./note-tags";
import { fetchNoteReactionsBySeq } from "./note-reactions";

const threadDetail = new Hono<{ Bindings: Bindings }>();

// GET /sync/thread-detail?thread_id=<uuid>
//
// Combined on-demand pull for a single thread's notes, tags, and reactions —
// the data fetched when a thread is opened for the first time. Folds what used
// to be three separate requests (/sync/notes, /sync/note-tags,
// /sync/note-reactions, each `initial=true&thread_id=…`) into ONE request that
// runs all three queries inside a SINGLE transaction.
//
// Why one transaction matters: a transaction is pinned to one backend
// connection. On a cold connection the planner pays a large one-time cost
// building the relcache for the heavily-indexed note/thread tables (~0.5–4 s
// measured on prod); the first query absorbs it and the next two reuse the
// warmed cache (~5 ms). Three separate requests can each land on a different
// cold backend and pay the full planning tax three times — the dominant cause
// of multi-second first-opens. See docs/perf/thread-open-cold-planning.md.
//
// Each entity keeps its own seq envelope (and its own safe horizon, read right
// after its query) so the client's per-entity sync cursors advance with
// exactly the same semantics as the standalone endpoints. The standalone
// endpoints remain for older clients and for the global (non-thread) sync
// paths; this endpoint is purely additive.
threadDetail.get("/sync/thread-detail", async (c) => {
  const userId = c.var.user.id;
  const { threadId, limit } = parseReadParams(c);

  if (!threadId) {
    return c.json({ error: "thread_id is required" }, 400);
  }

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    // 1. Notes — mirrors the seq-cursor initial branch of GET /sync/notes for a
    //    per-thread pull (seq_since=0 ⇒ visible rows only, no redacted stubs).
    const notes = await trx
      .selectFrom("user.note")
      .selectAll()
      .where("user_id", "=", userId)
      .where("thread_id", "=", threadId)
      .where(seqSinceCursor("0", null, null))
      .orderBy("seq", "asc")
      .orderBy("id", "asc")
      .limit(limit)
      .execute();
    const notesHorizon = await readSafeHorizon(trx);

    // 2. Tags — reuse the standalone endpoint's hand-tuned seq query.
    const noteTags = await fetchNoteTagsBySeq(trx, {
      userId,
      seqSince: "0",
      pageSeq: null,
      pageId: null,
      limit,
      archived: undefined,
      priorityId: null,
      priorityPath: null,
      threadId,
      rangeStart: null,
      rangeEnd: null,
      sortBy: "updated_at",
    });
    const noteTagsHorizon = await readSafeHorizon(trx);

    // 3. Reactions — same shape as tags.
    const noteReactions = await fetchNoteReactionsBySeq(trx, {
      userId,
      seqSince: "0",
      pageSeq: null,
      pageId: null,
      limit,
      archived: undefined,
      priorityId: null,
      priorityPath: null,
      threadId,
      rangeStart: null,
      rangeEnd: null,
      sortBy: "updated_at",
    });
    const noteReactionsHorizon = await readSafeHorizon(trx);

    return {
      notes,
      notesHorizon,
      noteTags,
      noteTagsHorizon,
      noteReactions,
      noteReactionsHorizon,
    };
  });

  return c.json({
    notes: seqEnvelope(result.notes as any, limit, result.notesHorizon),
    note_tags: seqEnvelope(result.noteTags as any, limit, result.noteTagsHorizon),
    note_reactions: seqEnvelope(
      result.noteReactions as any,
      limit,
      result.noteReactionsHorizon,
    ),
  } as any);
});

export default threadDetail;
