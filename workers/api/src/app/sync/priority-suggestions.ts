import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { Hono } from "hono";
import { type Kysely, sql } from "kysely";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import type { DB } from "../../db-types";
import { withUserDb } from "../../db";
import type { Bindings } from "../../env";

const suggestions = new Hono<{ Bindings: Bindings }>();

// Per-channel guarantee. SQL takes up to this many random threads per channel,
// so every channel with at least one candidate thread surfaces in the sample —
// a low-volume calendar with three events all year still contributes. Channels
// are the strongest source of per-priority signal so per-channel coverage is
// the primary axis; mirrors channel-router's sampling so the LLM sees a long-
// run character sketch instead of whatever happened to be recent.
const TITLES_PER_CHANNEL = 8;
// Embedding-diversity picks drawn from the diversity pool. Captures cross-
// channel themes (e.g. all the "tax" threads that span Gmail + Drive +
// Calendar) that per-channel sampling misses.
const DIVERSITY_SAMPLE_SIZE = 40;
// Size of the secondary random pool the diversity pick chooses from. Pulled
// in the same SQL pass as the per-channel rows; bounds wire size and the
// O(N × K × D) cost of the farthest-point loop in TS. 384-dim halfvec × 800
// rows ≈ 3-4 MB serialized text, comfortably under a second of pick time.
const DIVERSITY_CANDIDATE_CAP = 800;

// Permissive on purpose. The 1-3 path-length rule is enforced in TS after
// validation (truncate >3, drop empty) so a single off-by-one suggestion
// doesn't cause AI_NoObjectGeneratedError to throw away the whole batch.
// Mirrors the channel-router approach (workers/api/src/state/channel-router.ts).
const SuggestionsSchema = z.object({
  suggestions: z.array(
    z.object({
      path: z.array(z.string()),
      rationale: z.string().nullable().optional(),
    })
  ),
});

const SUGGEST_ERROR_CODES = [
  // AI Gateway env not configured (dev / test envs).
  "llm_unavailable",
  // Model returned output that didn't match the schema after one retry.
  // UI can prompt "try again" — usually transient.
  "llm_schema_failure",
  // Other LLM-side failure (network, rate limit, gateway error). Retried once
  // before surfacing.
  "llm_error",
] as const;
type SuggestErrorCode = (typeof SUGGEST_ERROR_CODES)[number];

type SampleRow = {
  thread_id: string;
  title: string;
  embedding: string | null;
  channel_pk: number | null;
  current_priority_path: string | null;
  // True iff SQL picked this row as part of its per-channel guarantee
  // (top TITLES_PER_CHANNEL random rows for the row's channel). Rows can be
  // both per-channel and in the diversity pool; we always treat per-channel
  // as the primary classification.
  is_per_channel: boolean;
};

type ChannelRow = {
  pk: number;
  connector: string;
  connector_description: string | null;
  account_label: string | null;
  channel_title: string;
  link_types: unknown;
};

type ConnectionRow = {
  twist_instance_id: string;
  connector: string;
  connector_description: string | null;
  account_label: string | null;
  channel_count: number;
};

type PriorityRow = {
  id: string;
  path: string;
  title: string;
  description: string | null;
};

// POST /sync/priorities/suggest
//
// Body: { since?: ISO timestamp, max_suggestions?: number }
//
// Returns a set of suggested priorities (1-3 levels deep) covering the user's
// connection link content since `since`. Existing priorities are passed to
// the LLM as context so suggestions extend the tree rather than duplicating it.
//
// This endpoint does NOT persist anything — the caller (UI, onboarding flow)
// reviews the suggestions before any priority is created.
suggestions.post("/sync/priorities/suggest", async (c) => {
  const userId = c.var.user.id;
  const body = await c.req.json<{
    since?: string;
    max_suggestions?: number;
  }>().catch(() => ({}) as { since?: string; max_suggestions?: number });

  const since = body.since ? new Date(body.since) : null;
  if (since && Number.isNaN(since.getTime())) {
    return c.json({ error: "invalid `since` timestamp" }, 400);
  }

  const result = await runSuggestPriorities(c.env, c.var.db, userId, {
    since,
    maxSuggestions: body.max_suggestions,
  });
  return c.json(result);
});

export type SuggestOptions = {
  since: Date | null;
  maxSuggestions?: number;
};

export type SuggestResult = {
  existing_priorities: PriorityRow[];
  suggestions: z.infer<typeof SuggestionsSchema>["suggestions"];
  sample_count: number;
  sampled_thread_count: number;
  error?: SuggestErrorCode;
};

export async function runSuggestPriorities(
  env: Bindings,
  db: Kysely<DB>,
  userId: string,
  options: SuggestOptions
): Promise<SuggestResult> {
  const logger = createLogger({
    component: "priority-suggestions",
    user_id: userId,
  });
  const since = options.since;
  const maxSuggestions = Math.min(
    Math.max(Math.trunc(options.maxSuggestions ?? 12), 1),
    30
  );

  const { priorities, connections, channels, samples } = await withUserDb(
    db,
    userId,
    async (trx) => {
      const p = await sql<PriorityRow>`
        SELECT p.id, p.path::text AS path, p.title, p.description
        FROM public.priority p
        WHERE p.user_id = ${userId}::uuid
          AND p.archived_at IS NULL
        ORDER BY p.path
        LIMIT 200
      `.execute(trx);

      const conn = await sql<ConnectionRow>`
        SELECT
          ti.id AS twist_instance_id,
          COALESCE(tw.name, 'connector') AS connector,
          tw.description AS connector_description,
          ti.account_label,
          COUNT(ch.id)::int AS channel_count
        FROM public.twist_instance ti
        JOIN public.twist tw ON tw.id = ti.twist_id
        LEFT JOIN public.channel ch ON ch.twist_instance_id = ti.id
        WHERE ti.owner_id = ${userId}::uuid
          AND ti.archived_at IS NULL
          AND ti.draft = FALSE
          AND tw.is_source = TRUE
        GROUP BY ti.id, tw.name, tw.description, ti.account_label
        ORDER BY tw.name, ti.account_label NULLS LAST
        LIMIT 60
      `.execute(trx);

      const ch = await sql<ChannelRow>`
        SELECT
          c.id AS pk,
          COALESCE(tw.name, 'connector') AS connector,
          tw.description AS connector_description,
          ti.account_label,
          c.title AS channel_title,
          c.link_types
        FROM public.channel c
        JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
        JOIN public.twist tw ON tw.id = ti.twist_id
        WHERE ti.owner_id = ${userId}::uuid
          AND ti.archived_at IS NULL
          AND c.enabled = TRUE
        ORDER BY c.id
        LIMIT 200
      `.execute(trx);

      // Pull candidate threads via the link table. Filter by link.created_at
      // so the caller's `since` cutoff applies to *connection link arrival*
      // (the spec) rather than thread creation, which can lag for cross-
      // connector merged threads.
      //
      // DISTINCT ON (t.id) collapses the join — a thread may have many links
      // (Gmail + Calendar bundling, etc.); we just want one row per thread.
      //
      // The window pass tags each candidate with a per-channel rank
      // (rn_channel) and a global rank (rn_global), both random-ordered.
      // We then keep any row that's in the top TITLES_PER_CHANNEL of its
      // channel OR in the global random pool. The per-channel guarantee is
      // what ensures a low-volume channel (a single calendar with three
      // events all year) still surfaces — without it the global random pool
      // is volume-proportional and that channel would lose its lottery.
      const sinceClause = since
        ? sql`AND date_trunc('milliseconds', l.created_at) >= ${since.toISOString()}::timestamptz`
        : sql``;

      const s = await sql<SampleRow>`
        WITH candidate AS (
          SELECT DISTINCT ON (t.id)
            t.id AS thread_id,
            t.title,
            t.embedding::text AS embedding,
            CASE
              WHEN t.topic LIKE 'channel:%'
              THEN (substring(t.topic FROM 9))::bigint
              ELSE NULL
            END AS channel_pk,
            p.path::text AS current_priority_path
          FROM public.link l
          JOIN public.thread t ON t.id = l.thread_id
          JOIN public.thread_priority tp
            ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
          LEFT JOIN public.priority p ON p.id = tp.priority_id
          WHERE t.archived_at IS NULL
            AND t.title IS NOT NULL
            AND length(trim(t.title)) > 0
            AND t.contacts && "user".user_contact_ids(${userId}::uuid)
            ${sinceClause}
        ),
        ranked AS (
          SELECT
            thread_id, title, embedding, channel_pk, current_priority_path,
            ROW_NUMBER() OVER (
              PARTITION BY COALESCE(channel_pk::text, '_no_channel')
              ORDER BY random()
            ) AS rn_channel,
            ROW_NUMBER() OVER (ORDER BY random()) AS rn_global
          FROM candidate
        )
        SELECT
          thread_id, title, embedding, channel_pk, current_priority_path,
          (rn_channel <= ${TITLES_PER_CHANNEL}) AS is_per_channel
        FROM ranked
        WHERE rn_channel <= ${TITLES_PER_CHANNEL}
           OR rn_global <= ${DIVERSITY_CANDIDATE_CAP}
      `.execute(trx);

      return {
        priorities: p.rows,
        connections: conn.rows,
        channels: ch.rows,
        samples: s.rows,
      };
    }
  );

  if (connections.length === 0 && samples.length === 0) {
    logger.info("No connections or sampled threads; returning empty");
    return {
      existing_priorities: priorities,
      suggestions: [],
      sample_count: 0,
      sampled_thread_count: 0,
    };
  }

  // The per-channel guarantee is enforced in SQL (rn_channel <= N), so every
  // channel with at least one candidate thread contributes here. The diversity
  // pool is the rest of the rows — we run greedy farthest-point on their
  // embeddings to surface cross-channel themes (a project that lives in Gmail
  // + Linear + Drive) that the per-channel slice would miss.
  const perChannel = samples.filter((r) => r.is_per_channel);
  const diversityPool = samples.filter((r) => !r.is_per_channel);
  const diversity = pickByEmbeddingDiversity(diversityPool, DIVERSITY_SAMPLE_SIZE);
  const sampledThreads = [...perChannel, ...diversity];

  const llmStart = Date.now();
  const llmResult = await callLlm(
    env,
    priorities,
    connections,
    channels,
    sampledThreads,
    samples.length,
    maxSuggestions,
    logger
  );

  if (!llmResult.ok) {
    return {
      existing_priorities: priorities,
      suggestions: [],
      sample_count: samples.length,
      sampled_thread_count: sampledThreads.length,
      error: llmResult.error,
    };
  }

  // Drop any suggestion whose path collides (case-insensitive) with an
  // existing priority path. Also enforce the 1-3 path-length rule the schema
  // no longer carries: trim segments, drop empties, truncate >3 (better than
  // dropping a 4-level suggestion outright — the first 3 levels are usually
  // still useful).
  const existingPaths = new Set(
    priorities.map((p) => p.path.toLowerCase())
  );
  const filtered = llmResult.value.suggestions
    .map((s) => ({
      path: s.path
        .map((seg) => seg.trim())
        .filter((seg) => seg.length > 0)
        .slice(0, 3),
      rationale: s.rationale ?? null,
    }))
    .filter((s) => s.path.length >= 1)
    .filter((s) => {
      const dotted = s.path.map((seg) => seg.toLowerCase()).join(".");
      return !existingPaths.has(dotted);
    });

  logger.info("priority suggestions generated", {
    user_id: userId,
    candidates: samples.length,
    sampled: sampledThreads.length,
    suggestions: filtered.length,
    llm_duration_ms: Date.now() - llmStart,
  });

  return {
    existing_priorities: priorities,
    suggestions: filtered,
    sample_count: samples.length,
    sampled_thread_count: sampledThreads.length,
  };
}

// -- sampling helpers --------------------------------------------------------

/**
 * Greedy farthest-point sampling over halfvec embeddings. Picks `count` rows
 * that maximize minimum cosine distance to anything previously picked, so the
 * sample spans the user's semantic space rather than clustering on whatever's
 * dominant.
 *
 * Skips rows missing an embedding (newly-created threads pre-embedding) and
 * just returns those at the end as filler if we ran short.
 */
function pickByEmbeddingDiversity(rows: SampleRow[], count: number): SampleRow[] {
  if (rows.length <= count) return rows;

  const withEmbed: { row: SampleRow; vec: Float32Array }[] = [];
  const withoutEmbed: SampleRow[] = [];
  for (const r of rows) {
    const vec = parseEmbedding(r.embedding);
    if (vec) withEmbed.push({ row: r, vec });
    else withoutEmbed.push(r);
  }

  if (withEmbed.length === 0) return rows.slice(0, count);

  // Pre-normalize so cosine similarity is just a dot product.
  for (const e of withEmbed) normalizeInPlace(e.vec);

  const picked: typeof withEmbed = [];
  const minSim = new Float32Array(withEmbed.length).fill(-Infinity);

  // Seed with a random pick.
  const seedIdx = Math.floor(Math.random() * withEmbed.length);
  picked.push(withEmbed[seedIdx]);
  for (let i = 0; i < withEmbed.length; i++) {
    if (i === seedIdx) continue;
    minSim[i] = dot(withEmbed[i].vec, withEmbed[seedIdx].vec);
  }
  minSim[seedIdx] = Infinity; // mark as taken

  while (picked.length < count) {
    // Find row with smallest max-similarity (= largest min-distance) to picks.
    let bestIdx = -1;
    let bestSim = Infinity;
    for (let i = 0; i < withEmbed.length; i++) {
      if (minSim[i] === Infinity) continue;
      if (minSim[i] < bestSim) {
        bestSim = minSim[i];
        bestIdx = i;
      }
    }
    if (bestIdx < 0) break;
    picked.push(withEmbed[bestIdx]);
    const newVec = withEmbed[bestIdx].vec;
    minSim[bestIdx] = Infinity;
    for (let i = 0; i < withEmbed.length; i++) {
      if (minSim[i] === Infinity) continue;
      const s = dot(withEmbed[i].vec, newVec);
      if (s > minSim[i]) minSim[i] = s;
    }
  }

  const out = picked.map((p) => p.row);
  // Fill any remaining slots with embedding-less rows so a brand-new account
  // (where most threads haven't been embedded yet) still gets coverage.
  if (out.length < count && withoutEmbed.length > 0) {
    out.push(...withoutEmbed.slice(0, count - out.length));
  }
  return out;
}

function parseEmbedding(s: string | null): Float32Array | null {
  if (!s) return null;
  // pgvector serializes halfvec as "[0.1,-0.2,...]"
  try {
    const parsed = JSON.parse(s);
    if (!Array.isArray(parsed)) return null;
    const out = new Float32Array(parsed.length);
    for (let i = 0; i < parsed.length; i++) {
      const v = Number(parsed[i]);
      if (!Number.isFinite(v)) return null;
      out[i] = v;
    }
    return out;
  } catch {
    return null;
  }
}

function normalizeInPlace(v: Float32Array): void {
  let norm = 0;
  for (let i = 0; i < v.length; i++) norm += v[i] * v[i];
  norm = Math.sqrt(norm);
  if (norm === 0) return;
  for (let i = 0; i < v.length; i++) v[i] /= norm;
}

function dot(a: Float32Array, b: Float32Array): number {
  let s = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

// -- LLM call ---------------------------------------------------------------

type LlmCallResult =
  | { ok: true; value: z.infer<typeof SuggestionsSchema> }
  | { ok: false; error: SuggestErrorCode };

async function callLlm(
  env: Bindings,
  priorities: PriorityRow[],
  connections: ConnectionRow[],
  channels: ChannelRow[],
  samples: SampleRow[],
  totalCandidates: number,
  maxSuggestions: number,
  logger: ReturnType<typeof createLogger>
): Promise<LlmCallResult> {
  if (
    !env.AI_GATEWAY_ACCOUNT_ID ||
    !env.AI_GATEWAY_ID ||
    !env.AI_GATEWAY_TOKEN
  ) {
    return { ok: false, error: "llm_unavailable" };
  }

  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const anthropic = createAnthropic({
    baseURL: `${gatewayBaseUrl}/anthropic`,
    apiKey: env.ANTHROPIC_API_KEY,
    headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
  });

  const systemPrompt = `You suggest a starter set of Plot priorities for a user based on the content flowing in from their connected accounts.

A "priority" is Plot's name for a project / folder / area-of-life. Priorities are nested as ltree paths, up to 3 levels deep:

  Level 1: a *role* — typically the name of an organization the user works at, "Personal", or a specific volunteer/hobby identity ("Food Bank Board", "Ultimate Frisbee"). Prefer the actual organization name when one is obvious from connection account labels (workspace name, email domain). Fall back to "Work" only when no organization name is identifiable.
  Level 2: a *focus or function* within that role — e.g. "Engineering", "Sales", "Marketing", "Finances", "Hiring", "Family", "Fitness".
  Level 3: a *specific project, client, or goal* — e.g. "Q3 Launch", "Acme Corp account", "Renovation".

Only go to level 3 when the evidence supports a specific project — do NOT invent level-3 entries to bulk up the suggestions. Many users will be best served by 4-8 priorities at levels 1-2.

How to use the inputs:
- **Connections** anchor level 1. A Slack workspace named "Acme" → suggests an "Acme" priority. A Gmail account "kris@bigco.com" → suggests "BigCo". A personal Gmail with no org signal → "Personal".
- **Channels** add level-2 detail. A "#design" Slack channel under Acme → "Acme > Design". A "Family" calendar → "Personal > Family".
- **Sample thread titles** are evidence for whether a level-2 or level-3 deserves to exist. Look for repeating themes (a recurring client name, a recurring project codename, a recurring topic). Single-mention themes are not enough.
- **Existing priorities** are the user's current tree. NEVER suggest a path that already exists. Suggestions should *extend* the tree (deeper levels under existing parents) or fill in gaps the tree doesn't yet cover. When an existing priority has a "description" field, it explains what belongs in that focus — use it to understand the tree's intent and avoid suggesting something already covered.

Output a flat list of paths. Each path is an array of 1-3 strings (root → leaf). When suggesting a deeper priority under an existing top-level priority, use the existing priority's title verbatim as the first element of the path.

Title style: capitalized phrase, 1-4 words, no leading articles. Match the style of any existing priorities the user already has. Use the org's actual name where known; do not generic-ify it.

Be conservative. Prefer fewer high-quality suggestions over many speculative ones. Suggest at most ${maxSuggestions} paths.

Each suggestion's rationale must cite the concrete signal used (a connection name, a channel title, a recurring sample title). Rationales are shown to the user during onboarding so they can decide which to accept.`;

  const userPrompt = renderUserPrompt(
    priorities,
    connections,
    channels,
    samples,
    totalCandidates
  );

  const model: any = anthropic("claude-sonnet-4-6");

  // Single retry on schema-mismatch failures. AI_NoObjectGeneratedError is
  // typically transient: the model returned text or a slightly malformed
  // object, and a second attempt usually succeeds. Other errors (network,
  // gateway, rate limit) also get one retry — cheap insurance for an
  // explicit user-triggered call.
  let lastSchemaFailure = false;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const result = await generateObject({
        model,
        schema: SuggestionsSchema,
        schemaName: "PrioritySuggestions",
        schemaDescription:
          'An object with a `suggestions` array. Each suggestion has `path` (an array of 1 to 3 strings going from root to leaf) and a `rationale` string. Example: { "suggestions": [{ "path": ["Acme Corp", "Engineering"], "rationale": "Linear workspace + #eng-onboarding Slack channel" }, { "path": ["Personal", "Family"], "rationale": "Family Calendar channel + family-related thread titles" }] }',
        maxOutputTokens: 4_000,
        messages: [
          {
            role: "system",
            content: systemPrompt,
            providerOptions: {
              anthropic: { cacheControl: { type: "ephemeral" } },
            },
          },
          { role: "user", content: userPrompt },
        ],
      });
      return { ok: true, value: result.object };
    } catch (error) {
      const isSchemaFailure = isLlmSchemaFailure(error);
      lastSchemaFailure = isSchemaFailure;
      const raw = (error as { text?: unknown })?.text;
      const logFields = {
        attempt,
        schema_failure: isSchemaFailure,
        error: (error as Error).message,
        raw_sample:
          typeof raw === "string" ? raw.slice(0, 2000) : undefined,
        sample_count: samples.length,
      };
      if (attempt < 2) {
        logger.warn("priority-suggestions LLM attempt failed; retrying", logFields);
        continue;
      }
      logger.warn("priority-suggestions LLM call failed", logFields);
    }
  }
  return {
    ok: false,
    error: lastSchemaFailure ? "llm_schema_failure" : "llm_error",
  };
}

function isLlmSchemaFailure(error: unknown): boolean {
  const name = (error as { name?: string })?.name;
  if (name === "AI_NoObjectGeneratedError" || name === "NoObjectGeneratedError") {
    return true;
  }
  const message = (error as { message?: string })?.message ?? "";
  // AI SDK wraps Zod validation failures and structured-output mismatches in
  // messages that include "No object generated" or "did not match schema".
  return /no object generated|did not match schema/i.test(message);
}

function renderUserPrompt(
  priorities: PriorityRow[],
  connections: ConnectionRow[],
  channels: ChannelRow[],
  samples: SampleRow[],
  totalCandidates: number
): string {
  const prioritiesBlock = priorities.length
    ? priorities
        .map((p) => `  - path=${p.path} title=${JSON.stringify(p.title)}${p.description ? ` description=${JSON.stringify(p.description)}` : ""}`)
        .join("\n")
    : "  (none — this is a fresh tree)";

  const connectionsBlock = connections
    .map((c) => {
      const desc = c.connector_description
        ? ` (${c.connector_description})`
        : "";
      return `  - connector=${JSON.stringify(c.connector)}${desc} account=${JSON.stringify(
        c.account_label ?? ""
      )} channels=${c.channel_count}`;
    })
    .join("\n");

  const channelsBlock = channels
    .map((c) => {
      const types =
        c.link_types && typeof c.link_types === "object"
          ? Object.keys(c.link_types as Record<string, unknown>).join(",")
          : "";
      return `  - connector=${JSON.stringify(c.connector)} account=${JSON.stringify(
        c.account_label ?? ""
      )} channelTitle=${JSON.stringify(c.channel_title)}${
        types ? ` linkTypes=${JSON.stringify(types)}` : ""
      }`;
    })
    .join("\n");

  // Group sample titles by current_priority_path so the LLM can see which
  // chunks of the existing tree are over- or under-covered.
  const samplesByBucket = new Map<string, string[]>();
  for (const s of samples) {
    const bucket = s.current_priority_path ?? "(unfiled)";
    const list = samplesByBucket.get(bucket) ?? [];
    list.push(s.title);
    samplesByBucket.set(bucket, list);
  }
  const samplesBlock = [...samplesByBucket.entries()]
    .map(
      ([bucket, titles]) =>
        `  - currently_filed_under=${bucket}\n    titles: ${JSON.stringify(titles)}`
    )
    .join("\n");

  return `Existing priorities:
${prioritiesBlock}

Connections (one row per connected account):
${connectionsBlock || "  (none)"}

Channels (one row per enabled channel; channels are sub-streams of a connection):
${channelsBlock || "  (none)"}

Sampled thread titles (${samples.length} of ${totalCandidates} candidate threads, grouped by current filing — "(unfiled)" means filed at the user's root priority):
${samplesBlock || "  (none)"}

Suggest priorities that should be added to this user's tree, based on the content above. Output paths only — the user will pick which to accept.`;
}

export default suggestions;
