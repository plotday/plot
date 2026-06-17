import { createLogger } from "@plotday/worker-util";
import { type Kysely } from "kysely";

import type { DB } from "../../../db-types";
import {
  checkAiLimit,
  isAiEnabled,
  recordAiUsage,
} from "../../../utils/ai-limits";
import type { Plot } from "./index";

/**
 * Sequential auto-threading: at ingest, decide ONCE (globally) whether a
 * connector message starts a new thread or folds — as a note — into the
 * thread of the conversation it continues. The decision is recorded in
 * `conversation_message` keyed by (twist_id, conversation_key, message_source),
 * so every other user's connector and every re-sync reuse it verbatim — no
 * visible thread merge or note move ever happens. See the design spec and
 * `libs/db/schema/50-tables/32-conversation_message.sql`.
 */

export type AutoThreadMode = "sequential" | "fold";

export interface AutoThreadResolveParams {
  /** Connector DEFINITION id (twist.id) — the decision is global per connector. */
  twistId: number;
  /** Conversation grouping (the connector's channel id). */
  conversationKey: string;
  /** This message's canonical source (the link's primary source). */
  messageSource: string;
  /** External creation time (ISO timestamptz) — orders the chain. */
  sourceCreatedAt: string;
  /** Short text snippet for the continuation check; may be null. */
  excerpt: string | null;
  /** "sequential" (channel, LLM-judged) or "fold" (DM, always continue). */
  mode: AutoThreadMode;
}

interface PreviousMessage {
  messageSource: string;
  anchorSource: string;
  excerpt: string | null;
}

/**
 * Cosine floor below which two short messages are treated as a clear topic
 * change — skip the LLM and start a new thread. The LLM is the real gate, so
 * this is only a cheap cost short-circuit; keep it permissive.
 */
const SIMILARITY_FLOOR = 0.45;

/**
 * Core fold-or-new orchestration, pure of AI. The continuation judgment is
 * injected as `decideContinuation` and invoked ONLY for the
 * sequential-mode-with-a-previous-message case, which keeps the branch logic
 * (cache reuse, previous lookup, DM always-fold, persist + conflict
 * convergence) unit-testable without Workers AI.
 *
 * Returns the resolved anchor source. Equal to `messageSource` ⇒ "start a new
 * thread"; any other value ⇒ "fold into the thread keyed by that anchor".
 */
export async function resolveAutoThreadAnchor(
  db: Kysely<DB>,
  params: AutoThreadResolveParams,
  decideContinuation: (previous: PreviousMessage) => Promise<boolean>,
): Promise<string> {
  const {
    twistId,
    conversationKey,
    messageSource,
    sourceCreatedAt,
    excerpt,
    mode,
  } = params;
  // twist_id is a bigint column (kysely Int8 select type is string).
  const twistKey = String(twistId);

  // 1. Decide-once cache: a prior processor (another user's connector, or a
  //    re-sync) already resolved this exact message — reuse it verbatim.
  const cached = await db
    .selectFrom("conversation_message")
    .select("anchor_source")
    .where("twist_id", "=", twistKey)
    .where("conversation_key", "=", conversationKey)
    .where("message_source", "=", messageSource)
    .executeTakeFirst();
  if (cached) return cached.anchor_source;

  // 2. The immediately-preceding ALREADY-ASSIGNED message in this conversation.
  const prevRow = await db
    .selectFrom("conversation_message")
    .select(["message_source", "anchor_source", "excerpt"])
    .where("twist_id", "=", twistKey)
    .where("conversation_key", "=", conversationKey)
    .where("source_created_at", "<", new Date(sourceCreatedAt))
    .orderBy("source_created_at", "desc")
    .orderBy("id", "desc")
    .limit(1)
    .executeTakeFirst();

  // 3. Decide the anchor.
  let anchor: string;
  if (!prevRow) {
    // First message in the chain — or out-of-order, the previous message is
    // not assigned yet. Either way, conservatively start a new thread.
    anchor = messageSource;
  } else if (mode === "fold") {
    // DM / one-to-one surface: always continue the single running thread.
    anchor = prevRow.anchor_source;
  } else {
    const previous: PreviousMessage = {
      messageSource: prevRow.message_source,
      anchorSource: prevRow.anchor_source,
      excerpt: prevRow.excerpt,
    };
    anchor = (await decideContinuation(previous))
      ? prevRow.anchor_source
      : messageSource;
  }

  // 4. Persist once. ON CONFLICT DO NOTHING then re-select so concurrent
  //    first-processors converge on a single stored anchor (the winner's).
  await db
    .insertInto("conversation_message")
    .values({
      twist_id: twistKey,
      conversation_key: conversationKey,
      message_source: messageSource,
      anchor_source: anchor,
      source_created_at: sourceCreatedAt,
      excerpt,
    })
    .onConflict((oc) =>
      oc
        .columns(["twist_id", "conversation_key", "message_source"])
        .doNothing(),
    )
    .execute();

  const stored = await db
    .selectFrom("conversation_message")
    .select("anchor_source")
    .where("twist_id", "=", twistKey)
    .where("conversation_key", "=", conversationKey)
    .where("message_source", "=", messageSource)
    .executeTakeFirst();

  return stored?.anchor_source ?? anchor;
}

/**
 * Production resolver: wires the high-confidence AI continuation check (free
 * embedding pre-filter + fast LLM) into the orchestration. Degrades to "new
 * thread" whenever AI is disabled, budget-exhausted, or errors — the
 * conservative default, since a wrong fold is irreversible.
 */
export async function resolveAutoThreadAnchorWithAi(
  plot: Plot,
  params: AutoThreadResolveParams,
): Promise<string> {
  return resolveAutoThreadAnchor(plot.db, params, (previous) =>
    isContinuation(plot, params, previous),
  );
}

async function isContinuation(
  plot: Plot,
  params: AutoThreadResolveParams,
  previous: PreviousMessage,
): Promise<boolean> {
  const current = (params.excerpt ?? "").trim();
  const prior = (previous.excerpt ?? "").trim();
  // No text to compare ⇒ can't judge a continuation ⇒ new thread.
  if (!current || !prior) return false;

  const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
  try {
    const userId = await plot.getUserId();
    // Honor the user's AI-off switch and the free-tier budget; either way,
    // fall back to a new thread rather than guessing.
    if (!(await isAiEnabled(plot.db, userId))) return false;
    const limit = await checkAiLimit(
      plot.env,
      plot.db,
      userId,
      "note_processing",
    );
    if (!limit.allowed) return false;

    // Free embedding pre-filter: skip the LLM on an obvious topic change.
    const [a, b] = await Promise.all([
      plot.ai.embed(current),
      plot.ai.embed(prior),
    ]);
    if (cosineSimilarity(a, b) < SIMILARITY_FLOOR) return false;

    const response = await plot.ai.prompt({
      model: { speed: "fast", cost: "low" },
      system:
        "You decide whether a new chat message continues the SAME conversation as the previous message " +
        "(a direct reply, a follow-up, or the same topic), or starts a NEW unrelated topic. " +
        "Answer YES only when you are confident it continues the previous conversation; when in doubt, answer NO. " +
        "Respond with exactly YES or NO.",
      prompt: `Previous message:\n${prior}\n\nNew message:\n${current}\n\nDoes the new message continue the previous conversation?`,
    });
    recordAiUsage(plot.env, userId, "note_processing");
    return response.text.trim().toUpperCase().startsWith("YES");
  } catch (error) {
    // AI failure (timeout / model error / budget) is expected and handled —
    // degrade to a new thread. Not captured: a fallback, not a bug.
    logger.warn(
      "auto-thread continuation check failed; starting a new thread",
      {
        conversation_key: params.conversationKey,
        error: error instanceof Error ? error.message : String(error),
      },
    );
    return false;
  }
}

/** Cosine similarity of two equal-length embedding vectors; 0 when undefined. */
function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length === 0 || b.length === 0 || a.length !== b.length) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}
