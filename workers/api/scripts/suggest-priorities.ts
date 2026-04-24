#!/usr/bin/env tsx
/**
 * One-off dev runner for the priority-suggestions endpoint.
 *
 * Inlines the same SQL + LLM call as the route handler in
 * src/app/sync/priority-suggestions.ts so it can run standalone (workspace
 * imports break under tsx ESM resolution).
 *
 * Usage:
 *   pnpm --filter @plotday/api exec tsx scripts/suggest-priorities.ts <user_email> [since-iso]
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import pg from "pg";
import { z } from "zod";

const __dirname = dirname(fileURLToPath(import.meta.url));

const TITLES_PER_CHANNEL = 8;
const DIVERSITY_SAMPLE_SIZE = 40;
const DIVERSITY_CANDIDATE_CAP = 800;

const SuggestionsSchema = z.object({
  suggestions: z.array(
    z.object({
      path: z.array(z.string()),
      rationale: z.string().nullable().optional(),
    })
  ),
});

function loadDotenv(path: string): Record<string, string> {
  const text = readFileSync(path, "utf8");
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[k] = v;
  }
  return out;
}

async function main() {
  const email = process.argv[2];
  const sinceArg = process.argv[3];
  if (!email) {
    console.error("Usage: suggest-priorities.ts <user_email> [since-iso]");
    process.exit(1);
  }

  const apiDir = resolve(__dirname, "..");
  const devVars = loadDotenv(resolve(apiDir, ".dev.vars"));

  const databaseUrl = process.env.DATABASE_URL || devVars.DATABASE_URL;
  if (!databaseUrl) throw new Error("DATABASE_URL not set");

  pg.types.setTypeParser(20, (val: string) => parseInt(val, 10));
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 2 });
  const client = await pool.connect();

  try {
    const userQ = await client.query<{ id: string; email: string }>(
      `SELECT id, email FROM "user" WHERE email = $1 LIMIT 1`,
      [email]
    );
    if (userQ.rows.length === 0) throw new Error(`No user with email ${email}`);
    const userId = userQ.rows[0].id;
    console.error(`User: ${userQ.rows[0].email} (${userId})`);

    const since = sinceArg ? new Date(sinceArg) : null;
    if (since) console.error(`Since: ${since.toISOString()}`);

    // Set the per-user RLS GUC the same way withUserDb does.
    await client.query(`SELECT set_config('plot.user_id', $1, true)`, [userId]);
    await client.query(`BEGIN`);
    await client.query(`SET LOCAL plot.user_id = '${userId}'`);

    const priorities = (
      await client.query<{ id: string; path: string; title: string }>(
        `SELECT p.id, p.path::text AS path, p.title
         FROM public.priority p
         WHERE p.user_id = $1::uuid AND p.archived_at IS NULL
         ORDER BY p.path LIMIT 200`,
        [userId]
      )
    ).rows;

    const connections = (
      await client.query<{
        twist_instance_id: string;
        connector: string;
        connector_description: string | null;
        account_label: string | null;
        channel_count: number;
      }>(
        `SELECT ti.id AS twist_instance_id,
                COALESCE(tw.name, 'connector') AS connector,
                tw.description AS connector_description,
                ti.account_label,
                COUNT(ch.id)::int AS channel_count
         FROM public.twist_instance ti
         JOIN public.twist tw ON tw.id = ti.twist_id
         LEFT JOIN public.channel ch ON ch.twist_instance_id = ti.id
         WHERE ti.owner_id = $1::uuid
           AND ti.archived_at IS NULL
           AND ti.draft = FALSE
           AND tw.is_source = TRUE
         GROUP BY ti.id, tw.name, tw.description, ti.account_label
         ORDER BY tw.name, ti.account_label NULLS LAST
         LIMIT 60`,
        [userId]
      )
    ).rows;

    const channels = (
      await client.query<{
        pk: number;
        connector: string;
        connector_description: string | null;
        account_label: string | null;
        channel_title: string;
        link_types: unknown;
      }>(
        `SELECT c.id AS pk,
                COALESCE(tw.name, 'connector') AS connector,
                tw.description AS connector_description,
                ti.account_label,
                c.title AS channel_title,
                c.link_types
         FROM public.channel c
         JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
         JOIN public.twist tw ON tw.id = ti.twist_id
         WHERE ti.owner_id = $1::uuid
           AND ti.archived_at IS NULL
           AND c.enabled = TRUE
         ORDER BY c.id
         LIMIT 200`,
        [userId]
      )
    ).rows;

    const sinceClauseParts = since
      ? `AND date_trunc('milliseconds', l.created_at) >= $2::timestamptz`
      : ``;
    const sampleParams: any[] = [userId];
    if (since) sampleParams.push(since.toISOString());

    const samples = (
      await client.query<{
        thread_id: string;
        title: string;
        embedding: string | null;
        channel_pk: number | null;
        current_priority_path: string | null;
        is_per_channel: boolean;
      }>(
        `WITH candidate AS (
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
           JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = $1::uuid
           LEFT JOIN public.priority p ON p.id = tp.priority_id
           WHERE t.archived_at IS NULL
             AND t.title IS NOT NULL
             AND length(trim(t.title)) > 0
             AND t.contacts && "user".user_contact_ids($1::uuid)
             ${sinceClauseParts}
         ),
         ranked AS (
           SELECT thread_id, title, embedding, channel_pk, current_priority_path,
             ROW_NUMBER() OVER (PARTITION BY COALESCE(channel_pk::text, '_no_channel') ORDER BY random()) AS rn_channel,
             ROW_NUMBER() OVER (ORDER BY random()) AS rn_global
           FROM candidate
         )
         SELECT thread_id, title, embedding, channel_pk, current_priority_path,
           (rn_channel <= ${TITLES_PER_CHANNEL}) AS is_per_channel
         FROM ranked
         WHERE rn_channel <= ${TITLES_PER_CHANNEL} OR rn_global <= ${DIVERSITY_CANDIDATE_CAP}`,
        sampleParams
      )
    ).rows;

    await client.query(`COMMIT`);

    console.error(
      `Loaded: ${priorities.length} priorities, ${connections.length} connections, ${channels.length} channels, ${samples.length} candidate threads`
    );

    if (samples.length === 0 && connections.length === 0) {
      console.log(JSON.stringify({ existing_priorities: priorities, suggestions: [], sample_count: 0, sampled_thread_count: 0 }, null, 2));
      return;
    }

    // Per-channel guarantee enforced in SQL; diversity pool is the rest.
    const perChannel = samples.filter((r) => r.is_per_channel);
    const diversityPool = samples.filter((r) => !r.is_per_channel);
    const diversity = pickByEmbeddingDiversity(diversityPool, DIVERSITY_SAMPLE_SIZE);
    const sampled = [...perChannel, ...diversity];

    const distinctChannels = new Set(perChannel.map((r) => String(r.channel_pk ?? "_no_channel")));
    console.error(
      `Sampled ${sampled.length} threads (${perChannel.length} per-channel covering ${distinctChannels.size} channels + ${diversity.length} diversity)`
    );

    const llmResult = await callLlm(devVars, priorities, connections, channels, sampled, samples.length);
    if (!llmResult) {
      console.log(JSON.stringify({ error: "llm_unavailable" }, null, 2));
      return;
    }

    const existingPaths = new Set(priorities.map((p) => p.path.toLowerCase()));
    const filtered = llmResult.suggestions.filter((s) => {
      const path = s.path.map((seg) => seg.trim()).filter((seg) => seg.length > 0);
      if (path.length === 0) return false;
      return !existingPaths.has(path.map((seg) => seg.toLowerCase()).join("."));
    });

    console.log(
      JSON.stringify(
        {
          existing_priorities: priorities,
          connections,
          channels: channels.map((c) => ({
            connector: c.connector,
            account_label: c.account_label,
            channel_title: c.channel_title,
          })),
          suggestions: filtered,
          sample_count: samples.length,
          sampled_thread_count: sampled.length,
        },
        null,
        2
      )
    );
  } finally {
    client.release();
    await pool.end();
  }
}

function pickByEmbeddingDiversity<T extends { embedding: string | null }>(rows: T[], count: number): T[] {
  if (rows.length <= count) return rows;
  const withEmbed: { row: T; vec: Float32Array }[] = [];
  const withoutEmbed: T[] = [];
  for (const r of rows) {
    const vec = parseEmbedding(r.embedding);
    if (vec) withEmbed.push({ row: r, vec });
    else withoutEmbed.push(r);
  }
  if (withEmbed.length === 0) return rows.slice(0, count);
  for (const e of withEmbed) normalizeInPlace(e.vec);
  const picked: typeof withEmbed = [];
  const minSim = new Float32Array(withEmbed.length).fill(-Infinity);
  const seedIdx = Math.floor(Math.random() * withEmbed.length);
  picked.push(withEmbed[seedIdx]);
  for (let i = 0; i < withEmbed.length; i++) {
    if (i === seedIdx) continue;
    minSim[i] = dot(withEmbed[i].vec, withEmbed[seedIdx].vec);
  }
  minSim[seedIdx] = Infinity;
  while (picked.length < count) {
    let bestIdx = -1;
    let bestSim = Infinity;
    for (let i = 0; i < withEmbed.length; i++) {
      if (minSim[i] === Infinity) continue;
      if (minSim[i] < bestSim) { bestSim = minSim[i]; bestIdx = i; }
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
  if (out.length < count && withoutEmbed.length > 0) out.push(...withoutEmbed.slice(0, count - out.length));
  return out;
}

function parseEmbedding(s: string | null): Float32Array | null {
  if (!s) return null;
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
  } catch { return null; }
}

function normalizeInPlace(v: Float32Array): void {
  let n = 0;
  for (let i = 0; i < v.length; i++) n += v[i] * v[i];
  n = Math.sqrt(n);
  if (n === 0) return;
  for (let i = 0; i < v.length; i++) v[i] /= n;
}

function dot(a: Float32Array, b: Float32Array): number {
  let s = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

async function callLlm(
  env: Record<string, string>,
  priorities: { id: string; path: string; title: string }[],
  connections: { connector: string; connector_description: string | null; account_label: string | null; channel_count: number }[],
  channels: { connector: string; account_label: string | null; channel_title: string; link_types: unknown }[],
  samples: { title: string; current_priority_path: string | null }[],
  totalCandidates: number
) {
  const acct = env.AI_GATEWAY_ACCOUNT_ID;
  const id = env.AI_GATEWAY_ID;
  const tok = env.AI_GATEWAY_TOKEN;
  const apiKey = env.ANTHROPIC_API_KEY;
  if (!acct || !id || !tok || !apiKey) {
    console.error("AI Gateway env not set; skipping LLM call");
    return null;
  }
  const baseURL = `https://gateway.ai.cloudflare.com/v1/${acct}/${id}/anthropic`;
  const anthropic = createAnthropic({
    baseURL,
    apiKey,
    headers: { "cf-aig-authorization": `Bearer ${tok}` },
  });

  const maxSuggestions = 12;
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
- **Existing priorities** are the user's current tree. NEVER suggest a path that already exists. Suggestions should *extend* the tree (deeper levels under existing parents) or fill in gaps the tree doesn't yet cover.

Output a flat list of paths. Each path is an array of 1-3 strings (root → leaf). When suggesting a deeper priority under an existing top-level priority, use the existing priority's title verbatim as the first element of the path.

Title style: capitalized phrase, 1-4 words, no leading articles. Match the style of any existing priorities the user already has. Use the org's actual name where known; do not generic-ify it.

Be conservative. Prefer fewer high-quality suggestions over many speculative ones. Suggest at most ${maxSuggestions} paths.

Each suggestion's rationale must cite the concrete signal used (a connection name, a channel title, a recurring sample title). Rationales are shown to the user during onboarding so they can decide which to accept.`;

  const prioritiesBlock = priorities.length
    ? priorities.map((p) => `  - path=${p.path} title=${JSON.stringify(p.title)}`).join("\n")
    : "  (none — this is a fresh tree)";
  const connectionsBlock = connections
    .map((c) => {
      const desc = c.connector_description ? ` (${c.connector_description})` : "";
      return `  - connector=${JSON.stringify(c.connector)}${desc} account=${JSON.stringify(c.account_label ?? "")} channels=${c.channel_count}`;
    })
    .join("\n");
  const channelsBlock = channels
    .map((c) => {
      const types = c.link_types && typeof c.link_types === "object"
        ? Object.keys(c.link_types as Record<string, unknown>).join(",") : "";
      return `  - connector=${JSON.stringify(c.connector)} account=${JSON.stringify(c.account_label ?? "")} channelTitle=${JSON.stringify(c.channel_title)}${types ? ` linkTypes=${JSON.stringify(types)}` : ""}`;
    })
    .join("\n");
  const samplesByBucket = new Map<string, string[]>();
  for (const s of samples) {
    const bucket = s.current_priority_path ?? "(unfiled)";
    const list = samplesByBucket.get(bucket) ?? [];
    list.push(s.title);
    samplesByBucket.set(bucket, list);
  }
  const samplesBlock = [...samplesByBucket.entries()]
    .map(([b, t]) => `  - currently_filed_under=${b}\n    titles: ${JSON.stringify(t)}`)
    .join("\n");

  const userPrompt = `Existing priorities:
${prioritiesBlock}

Connections (one row per connected account):
${connectionsBlock || "  (none)"}

Channels (one row per enabled channel; channels are sub-streams of a connection):
${channelsBlock || "  (none)"}

Sampled thread titles (${samples.length} of ${totalCandidates} candidate threads, grouped by current filing — "(unfiled)" means filed at the user's root priority):
${samplesBlock || "  (none)"}

Suggest priorities that should be added to this user's tree, based on the content above. Output paths only — the user will pick which to accept.`;

  const model: any = anthropic("claude-sonnet-4-6");
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const result = await generateObject({
        model,
        schema: SuggestionsSchema,
        schemaName: "PrioritySuggestions",
        schemaDescription: 'An object with a `suggestions` array. Each suggestion has `path` (an array of 1 to 3 strings going from root to leaf) and a `rationale` string. Example: { "suggestions": [{ "path": ["Acme Corp", "Engineering"], "rationale": "Linear workspace + #eng-onboarding Slack channel" }, { "path": ["Personal", "Family"], "rationale": "Family Calendar channel + family-related thread titles" }] }',
        maxOutputTokens: 4_000,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
      });
      if (attempt > 1) console.error(`LLM call succeeded on retry ${attempt}`);
      return result.object;
    } catch (error) {
      const msg = (error as Error).message;
      const isSchema = /no object generated|did not match schema/i.test(msg)
        || (error as { name?: string })?.name === "AI_NoObjectGeneratedError";
      console.error(`LLM call attempt ${attempt} failed (${isSchema ? "schema" : "other"}):`, msg);
      const raw = (error as { text?: unknown })?.text;
      if (typeof raw === "string") console.error("Raw sample:", raw.slice(0, 1000));
      if (attempt < 2) continue;
      return null;
    }
  }
  return null;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
