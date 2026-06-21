import { type Kysely, sql } from "kysely";
import { PostHog } from "posthog-node";

import type { DB } from "../db";
import { createDb } from "../db";
import type { Bindings } from "../env";
import { rpcUser } from "../rpc";
import {
  bandToImportance,
  fallbackBand,
  type FallbackSignals,
  IMPORTANCE_RUBRIC,
  parseBand,
} from "../state/importance/band";
import {
  getSenderEngagement,
  type SenderEngagement,
} from "../state/importance/engagement";
import {
  formatImportanceFeatureBlock,
  isAutomatedSenderEmail,
  type MemberFeature,
  type ThreadFacetsLike,
} from "../state/importance/features";
import { isAiEnabled } from "../utils/ai-limits";

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
    // Built-in-AI opt-out chokepoint: both enqueue paths (sync/notes and
    // queue/updates) reach the LLM through here, and the updates path gates
    // only on the free-tier quota — so enforce the opt-out here too. Returning
    // false ⇒ "unread not handled by AI", the same path a quota miss takes, so
    // the thread still marks unread normally without an importance score.
    if (!(await isAiEnabled(db, userId))) return false;

    const context = await gatherContext(env, db, noteId, threadId);
    if (!context) return false;

    const result = await classifyNote(env, context);

    await applyThreadState(
      env,
      db,
      threadId,
      userId,
      context.members,
      result.state,
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
  noteAuthorEmail: string | null;
  senderIsLinkedUser: boolean;
  facets: ThreadFacetsLike;
  memberEngagement: Map<string, SenderEngagement>; // keyed by member.id
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

interface ThreadStateClassification {
  // The AI sets `active` with high confidence; the user can flip it
  // themselves afterward.
  active: boolean;
  urgent: boolean;
  importance: number; // 0-100
  // When true the caller should NOT create a thread_state row for this
  // member — clearly passive material (receipts, confirmations, system
  // acks) the recipient doesn't need to process.
  skip: boolean;
}

interface AnalysisResult {
  state: {
    default: ThreadStateClassification;
    overrides: Record<string, Partial<ThreadStateClassification>>;
  };
}

async function gatherContext(
  env: Bindings,
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
      .select(["title", "contacts", "groups", "facets"])
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
      // Note author name and email
      db
        .selectFrom("contact")
        .select(["name", "email"])
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

  // Is the sender a real, linked person in the system (vs a synthetic source)?
  const senderLinked = await db
    .selectFrom("user_contact")
    .select("contact_id")
    .where("contact_id", "=", note.author_id)
    .where("linked", "=", true)
    .where("archived_at", "is", null)
    .executeTakeFirst();
  const senderIsLinkedUser = !!senderLinked;

  // How each recipient has historically treated this sender. Best-effort;
  // getSenderEngagement degrades to zero-history on failure. One cache for the
  // call dedupes repeated (recipient, sender) lookups.
  const engagementCache = new Map<string, Promise<SenderEngagement>>();
  const memberEngagement = new Map<string, SenderEngagement>();
  await Promise.all(
    members
      .filter((m) => m.userId && m.userId !== note.author_id)
      .map(async (m) => {
        const eng = await getSenderEngagement(
          db,
          m.userId as string,
          note.author_id as string,
          threadId,
          env,
          engagementCache,
        );
        memberEngagement.set(m.id, eng);
      }),
  );

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
    noteAuthorEmail: author?.email ?? null,
    senderIsLinkedUser,
    facets: (thread.facets as ThreadFacetsLike) ?? null,
    memberEngagement,
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

export async function classifyNote(
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

  const importanceFeatures = formatImportanceFeatureBlock({
    facets: context.facets,
    senderEmailAutomated: isAutomatedSenderEmail(context.noteAuthorEmail),
    senderIsLinkedUser: context.senderIsLinkedUser,
    members: context.members
      .map((m): MemberFeature | null => {
        const num = memberIdToNum.get(m.id);
        const engagement = context.memberEngagement.get(m.id);
        return num && engagement ? { memberNum: num, engagement } : null;
      })
      .filter((x): x is MemberFeature => x !== null),
  });

  const messages = [
    {
      role: "system" as const,
      content: `You classify notes in a collaborative productivity app to decide where each member should see this thread, how important it is to them, and whether it warrants immediate notification.

All members are identified by sequential numbers (e.g. member #1).

For each member, return four fields:
- active — does the recipient need to act on this NOW? (Doing section.)
- urgent — should we notify BEFORE their next scheduled response window?
- importance — an importance band (suppress/low/normal/elevated); drives whether the thread surfaces proactively at all.
- skip — clearly passive material no thread_state row should be created for.

Return a "default" plus per-member "overrides" where needed (use member numbers as keys). NEVER include the note author (skip=true for them; they are added automatically).

ONLY flag active with HIGH confidence; default it to false. The user can also flip it themselves.

active = true (be conservative — the user can set this themselves):
- the recipient is being asked a direct question that needs their answer
- the recipient has been explicitly asked to do something with a time pressure or response window
- they are personally on the hook for the next step
A short FYI, a status update, an @mention with no ask, an unsolicited pitch — none of these are active.

skip = true:
- clearly passive records the recipient doesn't need to process — confirmation emails, account sign-in notifications, receipts, automated system acknowledgements
- No thread_state row is created when skip=true.

urgent (boolean): true only when the recipient should be notified BEFORE their next scheduled response window — time-sensitive items or messages clearly requiring a quick response. Most notes are not urgent.

${IMPORTANCE_RUBRIC}

Respond with JSON only. No explanation.

Output schema:
{"state": {"default": {"active": false, "urgent": false, "importance": "normal", "skip": false}, "overrides": {"1": {"active": true, "urgent": false, "importance": "elevated"}}}}`,
    },
    {
      role: "user" as const,
      content: `Thread: "${context.threadTitle ?? "Untitled"}"
Links: ${linksStr}
Priority members:
${membersStr}
Recent notes:
${recentStr}
${importanceFeatures}

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

  const fallback: FallbackSignals = {
    facetAutomation: context.facets?.automation ?? null,
    facetReach: context.facets?.reach ?? null,
    facetFormat: context.facets?.format ?? null,
    senderEmailAutomated: isAutomatedSenderEmail(context.noteAuthorEmail),
    // "known" at the thread level = any recipient has prior history. Used only
    // when the model failed; a conservative OR keeps a sender that ANY recipient
    // engages with out of the suppressed bucket.
    senderKnown: [...context.memberEngagement.values()].some((e) => e.priorThreads > 0),
  };
  const defaultBand = fallbackBand(fallback);

  const defaultClassification: ThreadStateClassification = {
    active: false,
    urgent: false,
    importance: bandToImportance(defaultBand),
    skip: false,
  };

  const raw =
    typeof response === "string"
      ? response
      : "response" in response
        ? response.response
        : undefined;
  const text = (typeof raw === "string" ? raw : JSON.stringify(raw))?.trim();
  if (!text) {
    return { state: { default: defaultClassification, overrides: {} } };
  }

  // Extract JSON object from the response (handle potential markdown wrapping)
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    return { state: { default: defaultClassification, overrides: {} } };
  }

  try {
    const parsed = JSON.parse(jsonMatch[0]);

    const stateDefault = parseClassification(parsed.state?.default, defaultClassification);
    const overrides: Record<string, Partial<ThreadStateClassification>> = {};
    if (parsed.state?.overrides && typeof parsed.state.overrides === "object") {
      for (const [key, value] of Object.entries(parsed.state.overrides)) {
        // Resolve member number to real ID
        const memberId = memberNumToId.get(Number(key));
        if (!memberId) continue;
        const override = parseClassificationOverride(value);
        if (override) {
          overrides[memberId] = override;
        }
      }
    }

    return { state: { default: stateDefault, overrides } };
  } catch {
    console.error("[note-analysis] Failed to parse AI response:", text);
    return { state: { default: defaultClassification, overrides: {} } };
  }
}

function parseClassification(
  raw: any,
  fallback: ThreadStateClassification
): ThreadStateClassification {
  if (!raw || typeof raw !== "object") return fallback;
  return {
    active: typeof raw.active === "boolean" ? raw.active : fallback.active,
    urgent: typeof raw.urgent === "boolean" ? raw.urgent : fallback.urgent,
    importance: ((): number => {
      const band = parseBand(raw.importance);
      return band ? bandToImportance(band) : fallback.importance;
    })(),
    skip: typeof raw.skip === "boolean" ? raw.skip : fallback.skip,
  };
}

function parseClassificationOverride(
  raw: any
): Partial<ThreadStateClassification> | null {
  if (!raw || typeof raw !== "object") return null;
  const result: Partial<ThreadStateClassification> = {};
  if (typeof raw.active === "boolean") result.active = raw.active;
  if (typeof raw.urgent === "boolean") result.urgent = raw.urgent;
  const band = parseBand(raw.importance);
  if (band) result.importance = bandToImportance(band);
  if (typeof raw.skip === "boolean") result.skip = raw.skip;
  return Object.keys(result).length > 0 ? result : null;
}

export async function applyThreadState(
  env: Bindings,
  db: Kysely<DB>,
  threadId: string,
  noteAuthorUserId: string,
  members: Array<{ id: string; name: string | null; userId: string | null }>,
  state: AnalysisResult["state"],
  noteSourceCreatedAt: Date
): Promise<void> {
  for (const member of members) {
    if (!member.userId) continue;
    if (member.userId === noteAuthorUserId) continue; // Author is never in the inbox

    const override = state.overrides[member.id];
    const active = override?.active ?? state.default.active;
    const urgent = override?.urgent ?? state.default.urgent;
    const importance = override?.importance ?? state.default.importance;
    const skip = override?.skip ?? state.default.skip;
    if (skip) continue; // No thread_state row for passive material

    try {
      await rpcUser(db, "upsert_thread_state", {
        user_id: member.userId,
        p_thread_id: threadId,
        p_active: active,
        p_urgent: urgent,
        p_importance: importance,
        p_note_created_at: noteSourceCreatedAt.toISOString(),
        p_set_active: true,
        p_set_urgent: true,
        p_set_importance: true,
        // Mark the recipient unread. notes.ts treats analyzeNote()'s success
        // as "unread handled" and skips the fallback markThreadUnreadForOthers,
        // so the AI path MUST write the unread signal itself. p_read_at is left
        // unset (→ NULL = unread); p_note_created_at above makes the DB-side
        // race guard preserve read_at for a recipient who already read past
        // this note. Without this, a reply on a previously-read thread never
        // re-surfaces in Updates and never pushes (read_at stays non-NULL on
        // the existing thread_state row).
        p_set_read_at: true,
      });
    } catch (error) {
      console.error(
        `[note-analysis] Failed to apply thread state for user ${member.userId}:`,
        error
      );
      const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
      postHog.captureException(error as Error, member.userId, { context: "note-analysis:applyThreadState", thread_id: threadId });
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
