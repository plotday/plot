import type { Kysely } from "kysely";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { rpcUser } from "../rpc";

/**
 * AI-powered note analysis for auto-tagging todos and completions.
 * Analyzes a note's content in context to detect action items and task completions,
 * then applies Tag.Todo (1) or Tag.Done (3) accordingly.
 */
export async function analyzeNote(
  env: Bindings,
  noteId: string,
  threadId: string,
  userId: string
): Promise<void> {
  const db = createDb(env);
  try {
    const context = await gatherContext(db, noteId, threadId);
    if (!context) return;

    const actions = await classifyNote(env, context);
    if (actions.length === 0) return;

    await applyTagChanges(db, actions, context.memberIds, userId);
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
  members: Array<{ id: string; name: string | null }>;
  memberIds: Set<string>;
  existingTodos: Array<{ noteId: string; actorId: string }>;
  recentNotes: Array<{
    id: string;
    authorName: string | null;
    content: string | null;
  }>;
}

interface TagAction {
  noteId: string;
  actorId: string;
  done: boolean;
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
      .select(["id", "content", "author_id"])
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
  const [links, members, author, existingTodos, recentNotes] = await Promise.all([
    // Links on this thread
    db
      .selectFrom("link as l")
      .leftJoin("contact as c", "c.id", "l.assignee_id")
      .select(["l.title", "l.status", "l.type", "c.name as assignee_name"])
      .where("l.thread_id", "=", threadId)
      .execute(),
    // Priority members with names
    db
      .selectFrom("priority_contact as pc")
      .innerJoin("contact as c", "c.id", "pc.contact_id")
      .select(["c.id", "c.name"])
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
    // Recent notes on this thread (excluding the current note)
    db
      .selectFrom("note as n")
      .leftJoin("contact as c", "c.id", "n.author_id")
      .select(["n.id", "c.name as authorName", "n.content"])
      .where("n.thread_id", "=", threadId)
      .where("n.id", "!=", noteId)
      .where("n.draft", "=", false)
      .where("n.archived_at", "is", null)
      .orderBy("n.created_at", "desc")
      .limit(10)
      .execute(),
  ]);

  const memberIds = new Set(members.map((m) => m.id));

  return {
    noteId,
    noteContent: note.content,
    noteAuthorId: note.author_id,
    noteAuthorName: author?.name ?? null,
    threadTitle: thread.title,
    links,
    members,
    memberIds,
    existingTodos,
    recentNotes: recentNotes.reverse(), // chronological order
  };
}

async function classifyNote(
  env: Bindings,
  context: NoteContext
): Promise<TagAction[]> {
  const membersStr = context.members
    .map((m) => `- ${m.id}: ${m.name ?? "Unknown"}`)
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
              context.members.find((m) => m.id === t.actorId)?.name ?? t.actorId;
            return `- Note ${t.noteId} assigned to ${name} (${t.actorId})`;
          })
          .join("\n")
      : "None";

  const recentStr =
    context.recentNotes.length > 0
      ? context.recentNotes
          .map(
            (n) =>
              `- ${n.authorName ?? "Unknown"}: ${(n.content ?? "").slice(0, 300)}`
          )
          .join("\n")
      : "None";

  const messages = [
    {
      role: "system" as const,
      content: `You analyze notes in a collaborative productivity app to determine two things:
1. Does this note require action from someone? (e.g., a question, request, assignment)
2. Does this note indicate that a previously assigned task is now complete?

Rules:
- Only assign tasks to people in the priority members list.
- If no specific person is identifiable, do not assign a task.
- For completions, reference the noteId of the existing todo being completed.
- For new action items, use the current note's ID.
- Be conservative — only tag when intent is clear.
- Respond with a JSON array only. No explanation.

Output schema: [{"noteId": "string", "actorId": "string", "done": boolean}]
Empty array [] means no tag changes needed.`,
    },
    {
      role: "user" as const,
      content: `Thread: "${context.threadTitle ?? "Untitled"}"
Links: ${linksStr}
Priority members:
${membersStr}
Existing tasks:
${todosStr}
Recent notes:
${recentStr}

New note by ${context.noteAuthorName ?? "Unknown"} (${context.noteAuthorId}): ${context.noteContent.slice(0, 1000)}`,
    },
  ];

  const response = await env.AI.run(
    "@cf/meta/llama-3.1-8b-instruct-fp8",
    { messages, max_tokens: 256 }
  );

  if (response instanceof ReadableStream) {
    throw new Error("Unexpected stream response from AI");
  }

  const text = response.response?.trim();
  if (!text) return [];

  // Extract JSON array from the response (handle potential markdown wrapping)
  const jsonMatch = text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) return [];

  try {
    const parsed = JSON.parse(jsonMatch[0]);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (item: any) =>
        typeof item.noteId === "string" &&
        typeof item.actorId === "string" &&
        typeof item.done === "boolean"
    );
  } catch {
    console.error("[note-analysis] Failed to parse AI response:", text);
    return [];
  }
}

async function applyTagChanges(
  db: Kysely<DB>,
  actions: TagAction[],
  memberIds: Set<string>,
  userId: string
): Promise<void> {
  for (const { noteId: targetNoteId, actorId, done } of actions) {
    // Validate actorId is in the priority members list
    if (!memberIds.has(actorId)) continue;

    const tagId = done ? 3 : 1; // Tag.Done or Tag.Todo
    try {
      await rpcUser(db, "update_note_tags", {
        user_id: userId,
        p_note_id: targetNoteId,
        p_actor_id: userId,
        p_client_id: 0,
        p_tag_updates: { [`${tagId}:${actorId}`]: true },
      });
    } catch (error) {
      console.error(
        `[note-analysis] Failed to apply tag ${tagId} on note ${targetNoteId} for actor ${actorId}:`,
        error
      );
    }
  }
}
