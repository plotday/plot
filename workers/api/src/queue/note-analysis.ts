import { type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { createSchedule } from "../app/sync/smart-schedule";
import { rpc, rpcUser } from "../rpc";

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

    await applyUnreadStatus(
      env,
      db,
      threadId,
      userId,
      context.members,
      result.unread,
      context.noteSourceCreatedAt
    );

    return true;
  } finally {
    await db.destroy();
  }
}

interface NoteContext {
  noteId: string;
  noteCreatedAt: Date;
  noteSourceCreatedAt: Date;
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
  clearedTodos: Array<{ noteId: string; actorId: string }>;
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
  unread: {
    default: UnreadClassification;
    overrides: Record<string, Partial<UnreadClassification>>;
  };
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
      .select(["id", "created_at", "source_created_at", "content", "author_id", "mentions"])
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
  const [links, members, author, existingTodos, clearedTodos, existingReplies, recentNotes] =
    await Promise.all([
      // Links on this thread
      db
        .selectFrom("link as l")
        .leftJoin("contact as c", "c.id", "l.assignee_id")
        .select(["l.title", "l.status", "l.type", "c.name as assignee_name"])
        .where("l.thread_id", "=", threadId)
        .execute(),
      // Priority members: users with actual access (via priority_user hierarchy),
      // resolved to their primary contact record.
      (async () => {
        const usersData = await rpc(db, "get_users_with_priority_access", {
          target_priority_id: thread.priority_id,
        });
        const userIds = (!usersData ? [] : Array.isArray(usersData) ? usersData : [usersData]) as unknown as string[];
        if (userIds.length === 0) return [];
        return db
          .selectFrom("contact")
          .select([
            "id",
            "name",
            "user_id as userId",
          ])
          .where("user_id", "in", userIds)
          .where("primary", "=", true)
          .execute();
      })(),
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
      // Todos on this thread that were cleared by a human (not by AI client_id=0)
      db
        .selectFrom("note_tag as nt")
        .innerJoin("note as n", "n.id", "nt.note_id")
        .select(["nt.note_id as noteId", "nt.actor_id as actorId"])
        .where("n.thread_id", "=", threadId)
        .where("nt.tag_id", "=", 1) // Tag.Todo
        .where("nt.archived_at", "is not", null)
        .where("nt.updated_by", "!=", 0) // cleared by human, not AI
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
    noteCreatedAt: note.created_at,
    noteSourceCreatedAt: note.source_created_at,
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
    clearedTodos,
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
      content: `You classify notes in a collaborative productivity app to determine notification urgency for each member.

All members are identified by sequential numbers (e.g. member #1).

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
{"unread": {"default": {"urgency": "inform-updates", "importance": 50}, "overrides": {"1": {"urgency": "inform-requests", "importance": 75}}}}

Default {"urgency": "inform-updates", "importance": 50} if no special classification needed.`,
    },
    {
      role: "user" as const,
      content: `Thread: "${context.threadTitle ?? "Untitled"}"
Links: ${linksStr}
Priority members:
${membersStr}
Recent notes:
${recentStr}

New note by ${context.noteAuthorName ?? "Unknown"}${authorNum ? ` (member #${authorNum})` : ""}: ${context.noteContent.slice(0, 1000)}`,
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

  const raw = response.response;
  const text = (typeof raw === "string" ? raw : JSON.stringify(raw))?.trim();
  if (!text) {
    return { unread: { default: defaultClassification, overrides: {} } };
  }

  // Extract JSON object from the response (handle potential markdown wrapping)
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    return { unread: { default: defaultClassification, overrides: {} } };
  }

  try {
    const parsed = JSON.parse(jsonMatch[0]);

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

    return { unread: { default: unreadDefault, overrides } };
  } catch {
    console.error("[note-analysis] Failed to parse AI response:", text);
    return { unread: { default: defaultClassification, overrides: {} } };
  }
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
  unread: AnalysisResult["unread"],
  noteSourceCreatedAt: Date
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
        p_note_created_at: noteSourceCreatedAt.toISOString(),
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
 * Inline task detection for messaging notes with checkForTasks flag.
 * Creates separate Plot-authored reply notes for each detected task.
 * Called synchronously during note creation, not from the async queue.
 */
export async function detectTasks(
  env: Bindings,
  noteId: string,
  threadId: string,
  userId: string,
  priorityTwistId: string
): Promise<void> {
  const db = createDb(env);
  try {
    const context = await gatherContext(db, noteId, threadId);
    if (!context) return;

    const tasks = await classifyTasks(env, context);
    if (tasks.length === 0) return;

    // Guard: reject if too many tasks detected (likely hallucination)
    if (tasks.length > 3) {
      console.warn(
        `[detect-tasks] Rejecting ${tasks.length} tasks for note ${noteId} — too many detected`
      );
      return;
    }

    await createTaskNotes(env, db, tasks, context, threadId, userId, priorityTwistId);
  } finally {
    await db.destroy();
  }
}

interface DetectedTask {
  actorId: string;
  description: string;
}

async function classifyTasks(
  env: Bindings,
  context: NoteContext
): Promise<DetectedTask[]> {
  // Build member number mappings (same pattern as classifyNote)
  const memberNumToId = new Map<number, string>();
  const memberIdToNum = new Map<string, number>();
  context.members.forEach((m, i) => {
    const num = i + 1;
    memberNumToId.set(num, m.id);
    memberIdToNum.set(m.id, num);
  });

  const membersStr = context.members
    .map((m) => `- #${memberIdToNum.get(m.id)}: ${m.name ?? "Unknown"}`)
    .join("\n");

  const todosStr =
    context.existingTodos.length > 0
      ? context.existingTodos
          .map((t) => {
            const name =
              context.members.find((m) => m.id === t.actorId)?.name ?? "Unknown";
            return `- ${name} (member #${memberIdToNum.get(t.actorId) ?? "?"}): assigned a task`;
          })
          .join("\n")
      : "None";

  const clearedTodosStr =
    context.clearedTodos.length > 0
      ? context.clearedTodos
          .map((t) => {
            const name =
              context.members.find((m) => m.id === t.actorId)?.name ?? "Unknown";
            return `- ${name} (member #${memberIdToNum.get(t.actorId) ?? "?"}): had a task that was cleared`;
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
      content: `You detect actionable tasks in messaging conversations (email, chat). Analyze the new message and determine if it contains clear tasks for specific people.

A task exists when:
1. Someone asks someone specific to do something ("Can you update the docs?")
2. Someone commits to doing something in the future ("I'll send the report tomorrow")
3. Someone asks a specific person a question that needs a response
4. Something clearly demands a reply or action from a specific person

Rules:
- Only assign tasks to members in the priority members list (use member numbers).
- If no specific person is identifiable as the assignee, do not create a task.
- The note author cannot be assigned a task they are giving to themselves (self-commitments ARE tasks — assign to the author).
- Do not duplicate tasks already covered by existing todos.
- NEVER re-create tasks that were manually cleared by a user. "Cleared tasks" lists assignments that a user intentionally removed.
- Write each task description as a standalone imperative statement (e.g. "Update the API documentation" not "Alice asked Bob to update the docs").
- Keep descriptions concise — one sentence, under 100 characters when possible.
- When in doubt, do not create a task. False negatives are far less disruptive than false positives.

Respond with JSON only. No explanation.

Output schema:
{"tasks": [{"member": 1, "description": "Update the API documentation"}]}

Empty tasks array if no clear tasks detected.`,
    },
    {
      role: "user" as const,
      content: `Thread: "${context.threadTitle ?? "Untitled"}"
Priority members:
${membersStr}
Existing tasks:
${todosStr}
Cleared tasks (manually removed by user — do NOT re-create):
${clearedTodosStr}
Recent messages:
${recentStr}

New message by ${context.noteAuthorName ?? "Unknown"}${authorNum ? ` (member #${authorNum})` : ""}: ${context.noteContent.slice(0, 1000)}`,
    },
  ];

  const response = await env.AI.run(
    "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
    { messages, max_tokens: 512 }
  );

  if (response instanceof ReadableStream) {
    throw new Error("Unexpected stream response from AI");
  }

  const raw = response.response;
  const text = (typeof raw === "string" ? raw : JSON.stringify(raw))?.trim();
  if (!text) return [];

  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) return [];

  try {
    const parsed = JSON.parse(jsonMatch[0]);
    if (!Array.isArray(parsed.tasks)) return [];

    return parsed.tasks
      .filter(
        (t: any) =>
          typeof t.member === "number" &&
          typeof t.description === "string" &&
          t.description.trim().length > 0
      )
      .map((t: any) => ({
        actorId: memberNumToId.get(t.member),
        description: t.description.trim(),
      }))
      .filter((t: DetectedTask): t is DetectedTask => t.actorId !== undefined)
      // Filter out assignments to people not in the member list
      .filter((t: DetectedTask) => context.memberIds.has(t.actorId))
      // Filter out tasks that duplicate existing active todos for the same person
      .filter(
        (t: DetectedTask) =>
          !context.existingTodos.some((et) => et.actorId === t.actorId)
      )
      // Filter out tasks for people whose todos were manually cleared
      .filter(
        (t: DetectedTask) =>
          !context.clearedTodos.some((ct) => ct.actorId === t.actorId)
      );
  } catch {
    console.error("[detect-tasks] Failed to parse AI response:", text);
    return [];
  }
}

async function createTaskNotes(
  env: Bindings,
  db: Kysely<DB>,
  tasks: DetectedTask[],
  context: NoteContext,
  threadId: string,
  userId: string,
  priorityTwistId: string
): Promise<void> {
  for (const task of tasks) {
    try {
      // Create a Plot-authored reply note with the task description
      const noteResult = await db
        .insertInto("note")
        .values({
          author_id: priorityTwistId,
          created_by: priorityTwistId,
          thread_id: threadId,
          content: task.description,
          re_note_id: context.noteId,
          access_contacts: null,
          draft: false,
          updated_by: 0, // AI-generated
        })
        .returning("id")
        .executeTakeFirstOrThrow();

      // Apply the todo tag to the new task note for the assigned person
      await rpcUser(db, "update_note_tags", {
        user_id: userId,
        p_note_id: noteResult.id,
        p_actor_id: userId,
        p_client_id: 0,
        p_tag_updates: { [`1:${task.actorId}`]: true }, // Tag.Todo = 1
      });

      // Create task schedule for the assignee
      const contact = await db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", task.actorId)
        .executeTakeFirst();
      if (contact?.user_id) {
        await createSchedule(db, contact.user_id, threadId, "task");
      }
    } catch (error) {
      console.error(
        `[detect-tasks] Failed to create task note for actor ${task.actorId}:`,
        error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(error as Error, undefined, {
        context: "detect-tasks:createTaskNotes",
        note_id: context.noteId,
        actor_id: task.actorId,
      });
      await postHog.shutdown();
    }
  }
}
