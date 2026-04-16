import { Hono } from "hono";

import { sql, withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { rpc, rpcUser } from "../../rpc";
import { checkAiLimit, recordAiUsage } from "../../utils/ai-limits";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../../utils/ai-provider";
import { cleanTitle } from "../../twist/tools/plot/thread";
import { titleFromContent, createPreviewFromMarkdown } from "../../twist/tools/plot/thread-helpers";
import { summarize } from "../summary";
import { parseReadParams, updatedSinceCursor } from "./helpers";
import { createLogger } from "@plotday/worker-util";
import { sendInvitation } from "../invitation";
import { notifySync } from "./notify";

const threads = new Hono<{ Bindings: Bindings }>();

// GET /sync/threads
threads.get("/sync/threads", async (c) => {
  const userId = c.var.user.id;
  const {
    updatedSince,
    cursorId,
    archived,
    limit,
    priorityId,
    priorityPath,
    rangeStart,
    rangeEnd,
    initial,
    id,
    sortBy,
    sortDir,
  } = parseReadParams(c);

  const rows = await withUserDb(c.var.db, userId, async (trx) => {
    let query = trx
      .selectFrom("user.thread")
      .selectAll()
      .where("user_id", "=", userId);

    // Apply sort: use custom sort when not doing cursor pagination
    if (updatedSince) {
      query = query.orderBy("updated_at", "asc").orderBy("id", "asc");
    } else {
      // When sorting by agenda_at (a tstzrange), sort by its lower bound
      const sortExpr = sortBy === 'agenda_at' ? sql`lower(agenda_at)` : sql.ref(sortBy);
      query = query.orderBy(sortExpr, sortDir).orderBy("id", sortDir);
    }

    // Don't apply limit for initial pulls
    if (!initial) {
      query = query.limit(limit);
    }

    // Single-row fetch by ID
    if (id) {
      query = query.where("id", "=", id);
    }

    // Cursor pagination (uses date_trunc to match JS Date millisecond precision)
    if (updatedSince) {
      query = query.where(updatedSinceCursor(updatedSince, cursorId));
    }

    // Initial pull: fetch unread non-archived threads
    if (initial && archived !== true) {
      query = query.where(
        sql<boolean>`(archived_at IS NULL AND draft = false AND unread = true)`
      );
    } else {
      // Archived filter (only when not initial)
      if (archived === true) {
        query = query.where("archived_at", "is not", null);
      } else if (archived === false) {
        query = query.where("archived_at", "is", null);
      }
    }

    // Priority filter: prefer ID-based lookup, fall back to path for backward compatibility
    if (priorityId) {
      query = query.where(
        sql<boolean>`priority_id IN (SELECT child_id FROM priority_child WHERE priority_id = ${priorityId}::uuid)`
      );
    } else if (priorityPath) {
      query = query.where(
        sql<boolean>`priority_path <@ ${priorityPath}::ltree`
      );
    }

    // Range filtering (for pullTo pagination by sortBy column)
    if (sortBy === 'agenda_at') {
      // agenda_at is a tstzrange — use overlap (&&) operator
      if (rangeStart && rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, ${rangeEnd}::timestamptz)`);
      } else if (rangeStart) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(${rangeStart}::timestamptz, NULL)`);
      } else if (rangeEnd) {
        query = query.where(sql<boolean>`agenda_at && tstzrange(NULL, ${rangeEnd}::timestamptz)`);
      }
    } else {
      // Scalar comparison for activity_at, created_at, updated_at
      if (rangeStart) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} > ${rangeStart}::timestamptz`);
      }
      if (rangeEnd) {
        query = query.where(sql<boolean>`${sql.ref(sortBy)} < ${rangeEnd}::timestamptz`);
      }
    }

    return query.execute();
  });

  // Version-gated serialization: apiVersion < 3 clients expect a `topics`
  // array (the legacy name for what is now `groups`). Map groups → topics
  // and drop the new `topic` / `groups` fields for those clients.
  const apiVersion = c.var.apiVersion ?? 0;
  if (apiVersion < 3) {
    const legacyRows = rows.map((row: any) => {
      const { groups, topic: _topic, ...rest } = row;
      return { ...rest, topics: groups ?? [] };
    });
    return c.json(legacyRows as any);
  }

  return c.json(rows as any);
});

// POST /sync/threads - Upsert via upsert_thread() RPC
threads.post("/sync/threads", async (c) => {
  const body = await c.req.json();

  const threadData = body.thread || body;

  if (threadData.title && typeof threadData.title === "string") {
    threadData.title = cleanTitle(threadData.title);
  }

  // Generate AI title when client sends title=null with preview content
  if (
    !threadData.title &&
    threadData.preview &&
    typeof threadData.preview === "string" &&
    threadData.draft !== true
  ) {
    try {
      const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");
      if (aiAllowed.allowed) {
        const providerConfig = await loadBuiltinProviderConfig(c.var.db, c.var.user.id, c.env);
        let aiTitle: string | null = null;

        if (providerConfig) {
          aiTitle = await summarizeWithProvider(providerConfig, threadData.preview);
        }
        if (!aiTitle) {
          const result = await summarize(c.env.AI, threadData.preview);
          aiTitle = result.title;
        }

        if (aiTitle) {
          recordAiUsage(c.env, c.var.user.id, "note_processing");
          threadData.title = aiTitle;
        }
      }
    } catch (error) {
      console.error("[sync/threads] AI title generation failed:", error);
      c.var.tracker.captureException(error as Error);
    }

    // Fallback: derive title from content if AI didn't produce one
    if (!threadData.title) {
      threadData.title = titleFromContent(threadData.preview) ?? "Untitled";
    }

    // Truncate preview for storage now that title is set
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  // Always truncate oversized preview (e.g. client set title via /summary but preview is still full content)
  if (threadData.preview && typeof threadData.preview === "string" && threadData.preview.length > 200) {
    threadData.preview = createPreviewFromMarkdown(threadData.preview);
  }

  // Extract invite_emails before passing to upsert_thread (not a DB column)
  const inviteEmails: string[] = Array.isArray(threadData.invite_emails)
    ? threadData.invite_emails
    : [];
  delete threadData.invite_emails;

  // Strip server-side-only fields. twist_id is set by the twist runtime and
  // must not be settable via the user-facing sync endpoint — otherwise a
  // caller could dedupe their thread into someone else's twist-owned thread
  // and gain unintended visibility. pending_contacts is managed internally
  // by upsert_thread and the peer-promotion logic.
  delete threadData.twist_id;
  delete threadData.pending_contacts;

  // Translate legacy `topics` field (apiVersion < 3) to `groups` so
  // upsert_thread sees the new shape. If both are present, `groups` wins.
  if (threadData.topics !== undefined && threadData.groups === undefined) {
    threadData.groups = threadData.topics;
  }
  delete threadData.topics;

  const userId = c.var.user.id;

  const result = await withUserDb(c.var.db, userId, async (trx) => {
    const upsertResult = await rpcUser(trx, "upsert_thread", {
      user_id: userId,
      p_thread: threadData as any,
      p_defaults: (body.defaults || {}) as any,
    });

    // Auto-classify: when the client signals auto_file, use classify_thread_for_user
    // to re-file the thread based on user-defined priority rules.
    if (body.auto_file && !threadData.draft && upsertResult) {
      try {
        const textToEmbed = threadData.title || threadData.preview;
        let queryEmbedding: string | undefined;
        if (textToEmbed) {
          const response = (await c.env.AI.run("@cf/baai/bge-small-en-v1.5", {
            text: textToEmbed,
          })) as { data: number[][] };
          queryEmbedding = JSON.stringify(response.data[0]);

          // Store embedding on the thread for future rule matching
          await sql`UPDATE thread SET embedding = ${sql.val(queryEmbedding!)}::halfvec
                    WHERE id = ${sql.val(upsertResult.id)}`.execute(trx);
        }
        const matched = await rpc(trx, "classify_thread_for_user", {
          p_user_id: userId,
          p_thread_id: upsertResult.id,
          p_embedding: queryEmbedding ?? null,
        });
        if (matched && matched !== threadData.priority_id) {
          await sql`UPDATE thread_priority SET priority_id = ${sql.val(matched)}
                    WHERE thread_id = ${sql.val(upsertResult.id)} AND user_id = ${sql.val(userId)}`.execute(trx);
        }
      } catch (error) {
        // Auto-classification is non-critical — log but don't fail the thread save
        console.error("[sync/threads] Auto-classification failed:", error);
        c.var.tracker.captureException(error as Error);
      }
    }

    return upsertResult;
  });

  // Process pending email invitations: resolve emails → contacts, add to
  // thread.contacts via share_thread, send invitation emails.
  if (inviteEmails.length > 0 && result) {
    const logger = createLogger({ component: "sync-threads-invite" });
    try {
      // Resolve emails to contact UUIDs
      const contacts = await rpc(c.var.db, "upsert_contacts", {
        contacts: JSON.stringify(inviteEmails.map((email: string) => ({ email: email.toLowerCase() }))),
      });
      const contactRows = Array.isArray(contacts) ? contacts : [contacts];
      const contactIds = contactRows.map((row: { id: string }) => row.id);

      if (contactIds.length > 0) {
        // Add resolved contacts to thread via share_thread (handles
        // thread_unread creation and returns needs_invitation list)
        const shareResult = await c.var.db.transaction().execute(async (trx) => {
          return rpc(trx, "share_thread", {
            p_user_id: userId,
            p_thread_id: result.id,
            p_add_contact_ids: `{${contactIds.join(",")}}` as any,
            p_remove_contact_ids: "{}" as any,
          });
        }) as unknown as { contacts: string[]; needs_invitation: string[] };

        // Send invitation emails for contacts not linked to a user
        const needsInvitation = shareResult.needs_invitation ?? [];
        for (const contactId of needsInvitation) {
          try {
            await sendInvitation(c.var.db, {
              contactId,
              threadId: result.id,
              inviterUserId: userId,
              mailQueue: c.env.MAIL_QUEUE,
              appRoot: c.env.APP_ROOT,
            });
          } catch (inviteError) {
            logger.error("Invitation email failed", inviteError as Error, {
              contact_id: contactId,
              thread_id: result.id,
            });
            c.var.tracker.captureException(inviteError as Error, {
              contact_id: contactId,
              thread_id: result.id,
              error_context: "sync_thread_invitation_email_failed",
            });
          }
        }
      }
    } catch (error) {
      // Email invitation processing is non-critical — log but don't fail the sync
      console.error("[sync/threads] Email invitation processing failed:", error);
      c.var.tracker.captureException(error as Error);
    }
  }

  notifySync(c, threadData.priority_id);

  return c.json(result as any);
});

export default threads;
