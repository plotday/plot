import type { Kysely } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { createSchedule } from "../app/sync/smart-schedule";
import { rpcUser } from "../rpc";

/**
 * AI-powered note analysis for auto-tagging todos, reply-needed notes,
 * and classifying unread urgency for notification behavior.
 */
export async function analyzeNote(
  env: Bindings,
  noteId: string,
  threadId: string,
  userId: string
): Promise<boolean> {
  const db = createDb(env);
  try {
    const context = await gatherContext(db, noteId, threadId);
    if (!context) return false;

    const result = await classifyNote(env, context);

    if (result.tags.length > 0) {
      await applyTagChanges(env, db, result.tags, context.memberIds, userId);

      // Unarchive thread if actionable tags found and channel uses 'actionable' mode
      const actionableTags = result.tags.filter(t => !t.done);
      if (actionableTags.length > 0) {
        await maybeUnarchiveActionableThread(db, threadId);
      }
    }

    await applyUnreadStatus(
      env,
      db,
      threadId,
      userId,
      context.members,
      result.unread
    );

    return true;
  } finally {
    await db.destroy();
  }
}

interface NoteContext {
  noteId: string;
  noteContent: string;
  noteAuthorId: string;
  noteAuthorName: string | null;
  threadTitle: string | null;
  links: Array<{
    title: string | null;
    assignee_name: string | null;
    status: string | null;
    type: string | null;
  }>;
  members: Array<{ id: string; name: string | null; userId: string | null }>;
  memberIds: Set<string>;
  existingTodos: Array<{ noteId: string; actorId: string }>;
  existingReplies: Array<{ noteId: string; actorId: string }>;
  recentNotes: Array<{
    id: string;
    authorId: string | null;
    authorName: string | null;
    content: string | null;
    mentions: string[] | null;
  }>;
}

type UnreadUrgency = "interrupt" | "inform-requests" | "inform-updates" | "passive" | "ignore";

interface UnreadClassification {
  urgency: UnreadUrgency;
  importance: number; // 0-100
}

interface AnalysisResult {
  tags: TagAction[];
  unread: {
    default: UnreadClassification;
    overrides: Record<string, Partial<UnreadClassification>>;
  };
}

interface TagAction {
  noteId: string;
  actorId: string;
  done: boolean;
  tag: "todo" | "reply";
}

async function gatherContext(
  db: Kysely<DB>,
  noteId: string,
  threadId: string
): Promise<NoteContext | null> {
  // Fetch note and thread in parallel (needed before dependent queries)
  const [note, thread] = await Promise.all([
    db
      .selectFrom("note")
      .select(["id", "content", "author_id", "mentions"])
      .where("id", "=", noteId)
      .executeTakeFirst(),
    db
      .selectFrom("thread")
      .select(["title", "priority_id"])
      .where("id", "=", threadId)
      .executeTakeFirst(),
  ]);

  if (!note?.content || !note.author_id) return null;
  if (!thread?.priority_id) return null;

  // Fetch remaining context in parallel (all depend on note/thread results)
  const [links, members, author, existingTodos, existingReplies, recentNotes] =
    await Promise.all([
      // Links on this thread
      db
        .selectFrom("link as l")
        .leftJoin("contact as c", "c.id", "l.assignee_id")
        .select(["l.title", "l.status", "l.type", "c.name as assignee_name"])
        .where("l.thread_id", "=", threadId)
        .execute(),
      // Priority members with names and user IDs
      db
        .selectFrom("priority_contact as pc")
        .innerJoin("contact as c", "c.id", "pc.contact_id")
        .select([
          "c.id",
          "c.name",
          "c.user_id as userId",
        ])
        .where("pc.priority_id", "=", thread.priority_id)
        .execute(),
      // Note author name
      db
        .selectFrom("contact")
        .select("name")
        .where("id", "=", note.author_id)
        .executeTakeFirst(),
      // Existing active todos on this thread's notes
      db
        .selectFrom("note_tag as nt")
        .innerJoin("note as n", "n.id", "nt.note_id")
        .select(["nt.note_id as noteId", "nt.actor_id as actorId"])
        .where("n.thread_id", "=", threadId)
        .where("nt.tag_id", "=", 1) // Tag.Todo
        .where("nt.archived_at", "is", null)
        .execute(),
      // Existing active reply tags on this thread's notes
      db
        .selectFrom("note_tag as nt")
        .innerJoin("note as n", "n.id", "nt.note_id")
        .select(["nt.note_id as noteId", "nt.actor_id as actorId"])
        .where("n.thread_id", "=", threadId)
        .where("nt.tag_id", "=", 1019) // Tag.Reply
        .where("nt.archived_at", "is", null)
        .execute(),
      // Recent notes on this thread (excluding the current note)
      db
        .selectFrom("note as n")
        .leftJoin("contact as c", "c.id", "n.author_id")
        .select([
          "n.id",
          "n.author_id as authorId",
          "c.name as authorName",
          "n.content",
          "n.mentions",
        ])
        .where("n.thread_id", "=", threadId)
        .where("n.id", "!=", noteId)
        .where("n.draft", "=", false)
        .where("n.archived_at", "is", null)
        .orderBy("n.created_at", "desc")
        .limit(10)
        .execute(),
    ]);

  const memberIds = new Set(members.map((m) => m.id));

  // Build a member name lookup for resolving mentions
  const memberNameMap = new Map(members.map((m) => [m.id, m.name ?? "Unknown"]));

  // Format recent notes with author names and resolved @mentions
  const formattedRecentNotes = recentNotes.reverse().map((n) => {
    let content = n.content;
    // Resolve mention UUIDs to names
    if (content && n.mentions) {
      for (const mentionId of n.mentions as string[]) {
        const name = memberNameMap.get(mentionId);
        if (name) {
          content = content.replace(mentionId, `@${name}`);
        }
      }
    }
    return {
      id: n.id,
      authorId: n.authorId,
      authorName: n.authorName,
      content,
      mentions: n.mentions,
    };
  });

  return {
    noteId,
    noteContent: note.content,
    noteAuthorId: note.author_id,
    noteAuthorName: author?.name ?? null,
    threadTitle: thread.title,
    links,
    members: members.map((m) => ({
      id: m.id,
      name: m.name,
      userId: m.userId,
    })),
    memberIds,
    existingTodos,
    existingReplies,
    recentNotes: formattedRecentNotes,
  };
}

async function classifyNote(
  env: Bindings,
  context: NoteContext
): Promise<AnalysisResult> {
  // Build sequential number mappings so the LLM doesn't need to reproduce UUIDs
  const memberNumToId = new Map<number, string>();
  const memberIdToNum = new Map<string, number>();
  context.members.forEach((m, i) => {
    const num = i + 1;
    memberNumToId.set(num, m.id);
    memberIdToNum.set(m.id, num);
  });

  // Note number 0 = the current note being analyzed
  const noteNumToId = new Map<number, string>();
  noteNumToId.set(0, context.noteId);
  let nextNoteNum = 1;

  // Collect all known note IDs from existing todos/replies
  const allExistingNotes = [...context.existingTodos, ...context.existingReplies];
  for (const t of allExistingNotes) {
    if (!Array.from(noteNumToId.values()).includes(t.noteId)) {
      noteNumToId.set(nextNoteNum, t.noteId);
      nextNoteNum++;
    }
  }
  const noteIdToNum = new Map(Array.from(noteNumToId.entries()).map(([k, v]) => [v, k]));

  const membersStr = context.members
    .map((m) => `- #${memberIdToNum.get(m.id)}: ${m.name ?? "Unknown"}`)
    .join("\n");

  const linksStr =
    context.links.length > 0
      ? context.links
          .map(
            (l) =>
              `- ${l.title ?? "Untitled"} (type: ${l.type ?? "unknown"}, assignee: ${l.assignee_name ?? "none"}, status: ${l.status ?? "none"})`
          )
          .join("\n")
      : "None";

  const todosStr =
    context.existingTodos.length > 0
      ? context.existingTodos
          .map((t) => {
            const name =
              context.members.find((m) => m.id === t.actorId)?.name ?? "Unknown";
            return `- Note #${noteIdToNum.get(t.noteId)} assigned to ${name} (member #${memberIdToNum.get(t.actorId) ?? "?"})`;
          })
          .join("\n")
      : "None";

  const repliesStr =
    context.existingReplies.length > 0
      ? context.existingReplies
          .map((t) => {
            const name =
              context.members.find((m) => m.id === t.actorId)?.name ?? "Unknown";
            return `- Note #${noteIdToNum.get(t.noteId)} flagged for ${name} (member #${memberIdToNum.get(t.actorId) ?? "?"})`;
          })
          .join("\n")
      : "None";

  const recentStr =
    context.recentNotes.length > 0
      ? context.recentNotes
          .map((n) => {
            const memberNum = n.authorId ? memberIdToNum.get(n.authorId) : undefined;
            const authorLabel = memberNum
              ? `${n.authorName ?? "Unknown"} (member #${memberNum})`
              : (n.authorName ?? "Unknown");
            return `- ${authorLabel}: ${(n.content ?? "").slice(0, 300)}`;
          })
          .join("\n")
      : "None";

  const authorNum = memberIdToNum.get(context.noteAuthorId);

  const messages = [
    {
      role: "system" as const,
      content: `You analyze notes in a collaborative productivity app to determine three things:
1. Does this note assign a task to someone? (tag: "todo")
2. Does this note require a reply from someone? (tag: "reply")
3. How urgently should each member be notified? (unread classification)

All members and notes are identified by sequential numbers (e.g. member #1, note #0).
Note #0 is always the new note being analyzed.

Tag rules:
- Only assign tags to members in the priority members list (use member numbers).
- If no specific person is identifiable, do not assign a tag.
- For completions (done=true), reference the note number of the existing todo/reply being completed.
- For new items (done=false), use note number 0 (the current note).
- Todo: Only mark as todo if it clearly requires an action that ISN'T already covered by another task or link in the thread. Exception: clear sub-tasks completable before the parent.
- Reply: Mark as reply if the note clearly requires a response based on thread context and participants. E.g., a direct question in a two-person conversation.
- Be conservative — only tag when intent is clear.

Unread classification rules:
- For each member, classify how urgently and importantly they should be notified.
- Return a "default" with per-member "overrides" where needed (use member numbers as keys).
- The note author should NEVER be included (they are always ignored).
- urgency levels:
  - interrupt: urgent, needs immediate attention
  - inform-requests: someone is waiting on this person (reply needed, question asked, task assigned)
  - inform-updates: general update worth reviewing (status changes, comments, progress)
  - passive: minor update, show as unread but don't push-notify (automated updates, low-relevance changes)
  - ignore: not worth surfacing
- importance: 0-100 numeric scale. 0 = trivial, 50 = normal, 100 = critical. Consider how relevant the note is to each member.

Respond with JSON only. No explanation.

Output schema:
{
  "tags": [{"note": 0, "member": 1, "done": false, "tag": "todo"}],
  "unread": {"default": {"urgency": "inform-updates", "importance": 50}, "overrides": {"1": {"urgency": "inform-requests", "importance": 75}}}
}

Empty tags array and default {"urgency": "inform-updates", "importance": 50} if no special classification needed.`,
    },
    {
      role: "user" as const,
      content: `Thread: "${context.threadTitle ?? "Untitled"}"
Links: ${linksStr}
Priority members:
${membersStr}
Existing tasks:
${todosStr}
Existing reply flags:
${repliesStr}
Recent notes:
${recentStr}

New note #0 by ${context.noteAuthorName ?? "Unknown"}${authorNum ? ` (member #${authorNum})` : ""}: ${context.noteContent.slice(0, 1000)}`,
    },
  ];

  const response = await env.AI.run(
    "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
    { messages, max_tokens: 512 }
  );

  if (response instanceof ReadableStream) {
    throw new Error("Unexpected stream response from AI");
  }

  const defaultClassification: UnreadClassification = { urgency: "inform-updates", importance: 50 };

  const text = response.response?.trim();
  if (!text) {
    return { tags: [], unread: { default: defaultClassification, overrides: {} } };
  }

  // Extract JSON object from the response (handle potential markdown wrapping)
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    // Fallback: try array format for backward compatibility
    const arrayMatch = text.match(/\[[\s\S]*\]/);
    if (arrayMatch) {
      try {
        const parsed = JSON.parse(arrayMatch[0]);
        if (Array.isArray(parsed)) {
          const tags = resolveTagNumbers(parsed, noteNumToId, memberNumToId);
          return { tags, unread: { default: defaultClassification, overrides: {} } };
        }
      } catch {
        // Fall through
      }
    }
    return { tags: [], unread: { default: defaultClassification, overrides: {} } };
  }

  try {
    const parsed = JSON.parse(jsonMatch[0]);

    const tags = resolveTagNumbers(
      Array.isArray(parsed.tags) ? parsed.tags : [],
      noteNumToId,
      memberNumToId
    );

    const validUrgencies = new Set([
      "interrupt",
      "inform-requests",
      "inform-updates",
      "passive",
      "ignore",
    ]);

    const unreadDefault = parseClassification(parsed.unread?.default, validUrgencies, defaultClassification);
    const overrides: Record<string, Partial<UnreadClassification>> = {};
    if (parsed.unread?.overrides && typeof parsed.unread.overrides === "object") {
      for (const [key, value] of Object.entries(parsed.unread.overrides)) {
        // Resolve member number to real ID
        const memberId = memberNumToId.get(Number(key));
        if (!memberId) continue;
        const override = parseClassificationOverride(value, validUrgencies);
        if (override) {
          overrides[memberId] = override;
        }
      }
    }

    return { tags, unread: { default: unreadDefault, overrides } };
  } catch {
    console.error("[note-analysis] Failed to parse AI response:", text);
    return { tags: [], unread: { default: defaultClassification, overrides: {} } };
  }
}

/** Map sequential numbers from AI response back to real UUIDs, dropping invalid entries. */
function resolveTagNumbers(
  raw: any[],
  noteNumToId: Map<number, string>,
  memberNumToId: Map<number, string>
): TagAction[] {
  return raw
    .filter(
      (item: any) =>
        typeof item.note === "number" &&
        typeof item.member === "number" &&
        typeof item.done === "boolean" &&
        (item.tag === "todo" || item.tag === "reply")
    )
    .map((item: any) => ({
      noteId: noteNumToId.get(item.note),
      actorId: memberNumToId.get(item.member),
      done: item.done,
      tag: item.tag as "todo" | "reply",
    }))
    .filter((t): t is TagAction => t.noteId !== undefined && t.actorId !== undefined);
}

function parseClassification(
  raw: any,
  validUrgencies: Set<string>,
  fallback: UnreadClassification
): UnreadClassification {
  if (!raw) return fallback;
  // Handle string format (backward compat: just urgency)
  if (typeof raw === "string") {
    return { urgency: validUrgencies.has(raw) ? raw as UnreadUrgency : fallback.urgency, importance: fallback.importance };
  }
  if (typeof raw !== "object") return fallback;
  return {
    urgency: validUrgencies.has(raw.urgency) ? raw.urgency : fallback.urgency,
    importance: typeof raw.importance === "number" ? Math.max(0, Math.min(100, Math.round(raw.importance))) : fallback.importance,
  };
}

function parseClassificationOverride(
  raw: any,
  validUrgencies: Set<string>
): Partial<UnreadClassification> | null {
  if (!raw) return null;
  // Handle string format (just urgency)
  if (typeof raw === "string") {
    return validUrgencies.has(raw) ? { urgency: raw as UnreadUrgency } : null;
  }
  if (typeof raw !== "object") return null;
  const result: Partial<UnreadClassification> = {};
  if (validUrgencies.has(raw.urgency)) result.urgency = raw.urgency;
  if (typeof raw.importance === "number") result.importance = Math.max(0, Math.min(100, Math.round(raw.importance)));
  return Object.keys(result).length > 0 ? result : null;
}

async function applyUnreadStatus(
  env: Bindings,
  db: Kysely<DB>,
  threadId: string,
  noteAuthorUserId: string,
  members: Array<{ id: string; name: string | null; userId: string | null }>,
  unread: AnalysisResult["unread"]
): Promise<void> {
  for (const member of members) {
    if (!member.userId) continue;
    if (member.userId === noteAuthorUserId) continue; // Author never gets unread

    const override = unread.overrides[member.id];
    const urgency = override?.urgency ?? unread.default.urgency;
    const importance = override?.importance ?? unread.default.importance;
    if (urgency === "ignore") continue; // No row for ignore

    try {
      await rpcUser(db, "upsert_thread_unread", {
        user_id: member.userId,
        p_thread_id: threadId,
        p_urgency: urgency,
        p_importance: importance,
      });

      // passive: unread in app but no push notification
      if (urgency === "passive") continue;

      await createSchedule(db, member.userId, threadId, "unread");
    } catch (error) {
      console.error(
        `[note-analysis] Failed to apply unread status for user ${member.userId}:`,
        error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
      postHog.captureException(error as Error, undefined, { context: "note-analysis:applyUnreadStatus", user_id: member.userId, thread_id: threadId });
      await postHog.shutdown();
    }
  }
}

/**
 * Unarchive a thread if it's archived and linked to a channel with 'actionable' mode.
 * Called when note analysis finds actionable tags (todo/reply).
 */
async function maybeUnarchiveActionableThread(
  db: Kysely<DB>,
  threadId: string
): Promise<void> {
  const result = await db
    .selectFrom("thread as t")
    .innerJoin("link as l", "l.thread_id", "t.id")
    .innerJoin("source_channel as sc", (join) =>
      join
        .onRef("sc.priority_twist_id", "=", "l.created_by")
        .onRef("sc.channel_id", "=", "l.channel_id")
    )
    .select("t.id")
    .where("t.id", "=", threadId)
    .where("t.archived_at", "is not", null)
    .where("sc.create_threads", "=", "actionable")
    .executeTakeFirst();

  if (result) {
    await db
      .updateTable("thread")
      .set({ archived_at: null })
      .where("id", "=", threadId)
      .execute();
  }
}

async function applyTagChanges(
  env: Bindings,
  db: Kysely<DB>,
  actions: TagAction[],
  memberIds: Set<string>,
  userId: string
): Promise<void> {
  for (const { noteId: targetNoteId, actorId, done, tag } of actions) {
    // Validate actorId is in the priority members list
    if (!memberIds.has(actorId)) continue;

    try {
      if (tag === "reply") {
        // Reply is a count tag (1019) — insert directly into note_tag
        // Count tags enforce ownership, but AI runs server-side with direct DB access
        if (done) {
          // Archive the reply tag for this actor
          await db
            .updateTable("note_tag")
            .set({ archived_at: new Date(), updated_at: new Date() })
            .where("note_id", "=", targetNoteId)
            .where("actor_id", "=", actorId)
            .where("tag_id", "=", 1019)
            .where("archived_at", "is", null)
            .execute();
        } else {
          // Insert reply tag for the target actor
          await db
            .insertInto("note_tag")
            .values({
              actor_id: actorId,
              note_id: targetNoteId,
              tag_id: 1019,
              updated_by: 0,
            })
            .onConflict((oc) =>
              oc
                .columns(["actor_id", "note_id", "tag_id"])
                .doUpdateSet({
                  archived_at: null,
                  updated_at: new Date(),
                })
            )
            .execute();
        }
      } else {
        // Todo tag — use RPC + createSchedule (existing logic)
        const tagId = done ? 3 : 1; // Tag.Done or Tag.Todo
        await rpcUser(db, "update_note_tags", {
          user_id: userId,
          p_note_id: targetNoteId,
          p_actor_id: userId,
          p_client_id: 0,
          p_tag_updates: { [`${tagId}:${actorId}`]: true },
        });

        // Create task schedule when AI adds todo tag
        if (!done) {
          const contact = await db
            .selectFrom("contact")
            .select("user_id")
            .where("id", "=", actorId)
            .executeTakeFirst();
          if (contact?.user_id) {
            const note = await db
              .selectFrom("note")
              .select("thread_id")
              .where("id", "=", targetNoteId)
              .executeTakeFirst();
            if (note?.thread_id) {
              await createSchedule(db, contact.user_id, note.thread_id, "task");
            }
          }
        }
      }
    } catch (error) {
      console.error(
        `[note-analysis] Failed to apply ${tag} tag on note ${targetNoteId} for actor ${actorId}:`,
        error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
      postHog.captureException(error as Error, undefined, { context: "note-analysis:applyTagChanges", note_id: targetNoteId, actor_id: actorId, tag });
      await postHog.shutdown();
    }
  }
}
