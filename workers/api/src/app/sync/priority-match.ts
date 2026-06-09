import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { Hono } from "hono";
import { sql } from "kysely";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";
import { deriveFacetFilters } from "../../state/derive-facet-filters";

const router = new Hono<{ Bindings: Bindings }>();

// How many nearest-neighbour threads to pull from the vector index before the
// optional LLM re-rank. Bounds both the LLM prompt size and the wire payload.
const CANDIDATE_LIMIT = 60;
// Embedding-only fallback keeps candidates at or above this cosine similarity
// when the LLM is unavailable. Deliberately permissive; the user deselects.
const EMBED_ONLY_THRESHOLD = 0.45;

type VectorRow = { thread_id: string; title: string; similarity: number };
type LexicalRow = { thread_id: string; title: string; rank: number };
// Unified candidate fed to the LLM re-rank. `score` is cosine similarity for
// vector hits and ts_rank for lexical hits — used only to order the list and to
// score the embedding-only fallback; the LLM assigns the real relevance score.
type CandidateRow = {
  thread_id: string;
  title: string;
  score: number;
  source: "vector" | "lexical";
};

// Stopwords stripped from the lexical query so it ORs only meaningful terms.
const LEXICAL_STOPWORDS = new Set([
  "the", "and", "for", "from", "with", "that", "this", "are", "was", "were",
  "all", "any", "your", "our", "their", "its", "into", "out", "about", "over",
  "per", "via", "etc", "related", "stuff", "things", "various",
]);

// Tokenize a focus's title + description into distinct lexical terms for the
// keyword fallback. Lowercased, alphanumeric-only, stopwords and very short
// tokens dropped, deduped, capped.
function lexicalTerms(text: string): string[] {
  const seen = new Set<string>();
  for (const raw of text.toLowerCase().split(/[^a-z0-9]+/)) {
    if (raw.length < 3) continue;
    if (LEXICAL_STOPWORDS.has(raw)) continue;
    seen.add(raw);
    if (seen.size >= 20) break;
  }
  return [...seen];
}

const MatchSchema = z.object({
  matches: z.array(
    z.object({
      // 1-based index into the candidate list shown to the model.
      index: z.number(),
      score: z.number(),
      rationale: z.string().nullable().optional(),
    })
  ),
});

const MATCH_ERROR_CODES = ["llm_unavailable", "llm_schema_failure", "llm_error"] as const;
type MatchErrorCode = (typeof MATCH_ERROR_CODES)[number];

async function embedText(env: Bindings, text: string): Promise<number[]> {
  const res = (await env.AI.run("@cf/baai/bge-small-en-v1.5", { text })) as {
    data: number[][];
  };
  return res.data[0];
}

// POST /sync/priorities/find-matching-threads
//
// Body: { description (required), title?, limit?, exclude_thread_ids?: string[] }
//
// Given a natural-language description of a focus, returns the user's existing
// threads that belong in it, ranked. Embeds the description, vector-prefilters
// against the thread HNSW index, then (when available) LLM-reranks for
// precision. Persists nothing — the caller reviews/deselects before creating.
router.post("/sync/priorities/find-matching-threads", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req
    .json<{
      description?: string;
      title?: string;
      limit?: number;
      exclude_thread_ids?: string[];
    }>()
    .catch(() => ({}) as Record<string, never>);

  const description = (body.description ?? "").trim();
  if (!description) {
    return c.json({ error: "`description` is required" }, 400);
  }
  const title = (body.title ?? "").trim();
  const limit = Math.min(Math.max(Math.trunc(body.limit ?? 25), 1), CANDIDATE_LIMIT);
  const exclude = Array.isArray(body.exclude_thread_ids)
    ? body.exclude_thread_ids.filter((x) => typeof x === "string")
    : [];

  const logger = createLogger({ component: "priority-match", user_id: userId });

  // Derive the focus's intrinsic facet filters so the preview drops items the
  // focus will gate (e.g. notifications out of a Reading focus). Best-effort:
  // null filters → no extra filtering. The per-focus trust filter is omitted
  // here (the focus has no filed threads yet at preview time).
  const derived = await deriveFacetFilters(c.env, title, description);
  const facetFilterJson = derived ? JSON.stringify(derived) : null;

  // Embed the focus's title + description together (title adds a strong signal
  // for short descriptions). Fall back gracefully if embedding is unavailable.
  let queryEmbedding: number[];
  try {
    queryEmbedding = await embedText(c.env, title ? `${title}\n\n${description}` : description);
  } catch (error) {
    logger.warn("focus-match embedding failed", { error: (error as Error).message });
    return c.json({ matches: [], error: "llm_unavailable" as MatchErrorCode });
  }
  const queryJson = JSON.stringify(queryEmbedding);

  const terms = lexicalTerms(`${title} ${description}`);
  const lexicalQuery = terms.join(" OR ");

  // Shared visibility predicate for both candidate queries (both alias thread
  // as `t` and thread_priority as `tp`). Matches the user.thread view's access
  // rules: contacts OR groups, not archived/revoked, own drafts only, onboarding
  // pinned to the Inbox.
  const visible = sql`
        t.archived_at IS NULL
        AND tp.archived_at IS NULL
        AND tp.revoked_at IS NULL
        AND t.title IS NOT NULL
        AND length(trim(t.title)) > 0
        AND t.topic IS DISTINCT FROM 'onboarding'
        AND (t.draft = FALSE OR t.created_by = ${userId}::uuid)
        AND (
          t.contacts && "user".user_contact_ids(${userId}::uuid)
          OR t.groups && "user".user_group_ids(${userId}::uuid)
        )
        ${exclude.length ? sql`AND t.id <> ALL(${sql.val(exclude)}::uuid[])` : sql``}
        ${facetFilterJson ? sql`AND NOT public.intrinsic_facets_violate(t.facets, ${facetFilterJson}::jsonb)` : sql``}`;

  const { vector, lexical } = await withUserDb(c.var.db, userId, async (trx) => {
    // Semantic candidates from the HNSW vector index.
    const vec = await sql<VectorRow>`
      SELECT
        t.id AS thread_id,
        t.title,
        (1 - (t.embedding <=> ${queryJson}::halfvec))::float AS similarity
      FROM public.thread t
      JOIN public.thread_priority tp
        ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
      WHERE t.embedding IS NOT NULL
        AND ${visible}
      ORDER BY t.embedding <=> ${queryJson}::halfvec
      LIMIT ${CANDIDATE_LIMIT}
    `.execute(trx);

    // Lexical candidates from a full-text keyword match. Deliberately does NOT
    // require an embedding, so threads still awaiting backfill (or that never
    // embedded) can still match on title/preview keywords. websearch_to_tsquery
    // never errors on arbitrary input and supports the OR operator.
    let lex: LexicalRow[] = [];
    if (terms.length > 0) {
      const lexResult = await sql<LexicalRow>`
        SELECT
          t.id AS thread_id,
          t.title,
          ts_rank(
            to_tsvector('english', coalesce(t.title, '') || ' ' || coalesce(t.preview, '')),
            websearch_to_tsquery('english', ${lexicalQuery})
          )::float AS rank
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
        WHERE to_tsvector('english', coalesce(t.title, '') || ' ' || coalesce(t.preview, ''))
                @@ websearch_to_tsquery('english', ${lexicalQuery})
          AND ${visible}
        ORDER BY rank DESC
        LIMIT ${CANDIDATE_LIMIT}
      `.execute(trx);
      lex = lexResult.rows;
    }

    return { vector: vec.rows, lexical: lex };
  });

  // Merge: vector hits first (semantic relevance), then lexical hits not already
  // present, capped at CANDIDATE_LIMIT. A Map preserves insertion order.
  const byId = new Map<string, CandidateRow>();
  for (const r of vector) {
    byId.set(r.thread_id, {
      thread_id: r.thread_id,
      title: r.title,
      score: r.similarity,
      source: "vector",
    });
  }
  for (const r of lexical) {
    if (!byId.has(r.thread_id)) {
      byId.set(r.thread_id, {
        thread_id: r.thread_id,
        title: r.title,
        score: r.rank,
        source: "lexical",
      });
    }
  }
  const candidates = [...byId.values()].slice(0, CANDIDATE_LIMIT);

  if (candidates.length === 0) {
    return c.json({ matches: [] });
  }

  const llm = await rerankWithLlm(c.env, description, title, candidates, logger);
  if (!llm.ok) {
    // No-LLM fallback: keep vector hits above the cosine floor, plus any lexical
    // keyword hits (a strong signal on their own). Lexical hits get a nominal
    // mid score since ts_rank isn't comparable to cosine similarity; the user
    // reviews and deselects.
    const matches = candidates
      .filter((c) => (c.source === "vector" ? c.score >= EMBED_ONLY_THRESHOLD : true))
      .slice(0, limit)
      .map((c) => ({
        thread_id: c.thread_id,
        title: c.title,
        score: c.source === "vector" ? c.score : 0.5,
        rationale: null,
      }));
    return c.json({ matches, error: llm.error, llm_used: false });
  }

  const byIndex = new Map(candidates.map((r, i) => [i + 1, r]));
  const matches = llm.value.matches
    .map((m) => ({ cand: byIndex.get(m.index), score: m.score, rationale: m.rationale ?? null }))
    .filter((m): m is { cand: CandidateRow; score: number; rationale: string | null } => Boolean(m.cand))
    .filter((m) => m.score >= 0.5)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((m) => ({ thread_id: m.cand.thread_id, title: m.cand.title, score: m.score, rationale: m.rationale }));

  return c.json({ matches, llm_used: true });
});

// POST /sync/priorities/negatives
//
// Body: { negatives: [{ thread_id, priority_id, source: 'moved_out' | 'deselected' }] }
//
// Records negative categorization signals for the classifier. Used for both
// threads the user moves out of a focus (captured client-side, which knows the
// source focus reliably) and candidates deselected during focus creation.
router.post("/sync/priorities/negatives", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req
    .json<{ negatives?: { thread_id?: string; priority_id?: string; source?: string }[] }>()
    .catch(() => ({}) as { negatives?: never[] });

  const negatives = (body.negatives ?? []).filter(
    (n) =>
      typeof n.thread_id === "string" &&
      typeof n.priority_id === "string" &&
      (n.source === "moved_out" || n.source === "deselected")
  );
  if (negatives.length === 0) {
    return c.json({ inserted: 0 });
  }

  const inserted = await withUserDb(c.var.db, userId, async (trx) => {
    const values = sql.join(
      negatives.map(
        (n) =>
          sql`(${userId}::uuid, ${n.thread_id}::uuid, ${n.priority_id}::uuid, ${n.source}, now())`
      )
    );
    await sql`
      INSERT INTO public.thread_priority_negative (user_id, thread_id, priority_id, source, created_at)
      VALUES ${values}
      ON CONFLICT (user_id, thread_id, priority_id)
        DO UPDATE SET source = EXCLUDED.source, created_at = now()
    `.execute(trx);
    return negatives.length;
  });

  return c.json({ inserted });
});

type RerankResult =
  | { ok: true; value: z.infer<typeof MatchSchema> }
  | { ok: false; error: MatchErrorCode };

async function rerankWithLlm(
  env: Bindings,
  description: string,
  title: string,
  candidates: CandidateRow[],
  logger: ReturnType<typeof createLogger>
): Promise<RerankResult> {
  if (!env.AI_GATEWAY_ACCOUNT_ID || !env.AI_GATEWAY_ID || !env.AI_GATEWAY_TOKEN) {
    return { ok: false, error: "llm_unavailable" };
  }

  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const anthropic = createAnthropic({
    baseURL: `${gatewayBaseUrl}/anthropic`,
    apiKey: env.ANTHROPIC_API_KEY,
    headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
  });

  const systemPrompt = `You decide which of a user's existing threads belong in a new "focus" they are creating.

A focus is a project / area-of-life the user wants to gather related threads under. You are given the focus's title and description, plus a numbered list of candidate threads (pre-filtered by semantic similarity). For each thread that genuinely belongs in the focus, return its number with a confidence score from 0 to 1 and a short rationale. Omit threads that don't belong. Be precise — it's better to omit a borderline thread than to include an irrelevant one. Only include threads with score >= 0.5.`;

  const candidateBlock = candidates
    .map((r, i) => `  ${i + 1}. ${JSON.stringify(r.title)}`)
    .join("\n");
  const userPrompt = `Focus title: ${JSON.stringify(title || "(untitled)")}
Focus description: ${JSON.stringify(description)}

Candidate threads:
${candidateBlock}

Return the threads that belong in this focus.`;

  const model: any = anthropic("claude-sonnet-4-6");
  let lastSchemaFailure = false;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const result = await generateObject({
        model,
        schema: MatchSchema,
        schemaName: "FocusMatches",
        schemaDescription:
          'An object with a `matches` array. Each match has `index` (the 1-based candidate number), `score` (0 to 1), and an optional `rationale` string.',
        maxOutputTokens: 4_000,
        messages: [
          {
            role: "system",
            content: systemPrompt,
            providerOptions: { anthropic: { cacheControl: { type: "ephemeral" } } },
          },
          { role: "user", content: userPrompt },
        ],
      });
      return { ok: true, value: result.object };
    } catch (error) {
      lastSchemaFailure = isLlmSchemaFailure(error);
      const logFields = { attempt, error: (error as Error).message };
      if (attempt < 2) {
        logger.warn("focus-match LLM attempt failed; retrying", logFields);
        continue;
      }
      logger.warn("focus-match LLM call failed", logFields);
    }
  }
  return { ok: false, error: lastSchemaFailure ? "llm_schema_failure" : "llm_error" };
}

function isLlmSchemaFailure(error: unknown): boolean {
  const name = (error as { name?: string })?.name;
  if (name === "AI_NoObjectGeneratedError" || name === "NoObjectGeneratedError") {
    return true;
  }
  const message = (error as { message?: string })?.message ?? "";
  return /no object generated|did not match schema/i.test(message);
}

export default router;
