import { type Kysely, sql } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
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
      .select(["title", "contacts", "groups"])
      .where("id", "=", threadId)
      .executeTakeFirst(),
  ]);

  if (!note?.content || !note.author_id) return null;
  if (!thread) return null;

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
      // Thread members: every user who can see this thread — linked to any
      // thread contact, OR a member of any thread group (via their linked
      // contacts). Resolved to each user's primary contact record.
      (async () => {
        const contacts = (thread.contacts ?? []) as string[];
        const groups = (thread.groups ?? []) as string[];
        if (contacts.length === 0 && groups.length === 0) return [];

        const userRows = await sql<{ user_id: string }>`
          SELECT DISTINCT uc.user_id
          FROM user_contact uc
          WHERE uc.linked = TRUE
            AND uc.archived_at IS NULL
            AND (
              ${contacts.length > 0 ? sql`uc.contact_id = ANY(${contacts}::uuid[])` : sql`FALSE`}
              OR EXISTS (
                SELECT 1 FROM group_member gm
                WHERE gm.contact_id = uc.contact_id
                  AND ${groups.length > 0 ? sql`gm.group_id = ANY(${groups}::uuid[])` : sql`FALSE`}
              )
            )
        `.execute(db);

        const userIds: string[] = [
          ...new Set(userRows.rows.map((r) => r.user_id)),
        ];
        if (userIds.length === 0) return [];

        return db
          .selectFrom("contact")
          .select(["id", "name", "user_id as userId"])
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

      // Disabled: auto-add to agenda based on AI urgency was too aggressive.
      // Unread status is still set above so notifications/badges work; we just
      // no longer create an "unread" schedule entry. May be tuned and re-enabled later.
      // if (urgency === "passive") continue;
      // await createSchedule(db, member.userId, threadId, "unread");
    } catch (error) {
      console.error(
        `[note-analysis] Failed to apply unread status for user ${member.userId}:`,
        error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
      postHog.captureException(error as Error, member.userId, { context: "note-analysis:applyUnreadStatus", thread_id: threadId });
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
  _env: Bindings,
  _noteId: string,
  _threadId: string,
  _userId: string,
  _twistInstanceId: string
): Promise<void> {
  // Disabled: auto-task creation was too aggressive. May be tuned and re-enabled later.
  return;
}
