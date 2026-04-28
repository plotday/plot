import { DurableObject } from "cloudflare:workers";
import { createAnthropic } from "@ai-sdk/anthropic";
import { generateObject } from "ai";
import { sql, type Kysely } from "kysely";
import { PostHog } from "posthog-node";
import { z } from "zod";

import { createLogger } from "@plotday/worker-util";

import type { DB } from "../db-types";
import { withDb, withUserDb } from "../db";
import type { Bindings } from "../env";
import { rpc } from "../rpc";
import { notifyUserSyncByEnv } from "../app/sync/notify";

// Debounce window. Priority edits and channel enables arrive in clusters
// (a user creating several priorities in a row, a connector enabling its
// channels after oauth). Coalescing to one LLM call keeps the token budget
// bounded without making the user wait long for the re-file.
const DEBOUNCE_MS = 5_000;

const MAX_THREAD_TITLE_SAMPLES = 5;
const MAX_CHANNELS_PER_CALL = 60;
const MAX_PRIORITIES = 200;

// Structured output schema. Kept permissive — stricter shape (uuid format,
// integer pk, reason length) is enforced in TypeScript after validation.
// Model providers sometimes return floats or omit optional strings, and a
// brittle schema causes the whole batch to be thrown away with
// AI_NoObjectGeneratedError instead of just dropping the bad row.
const RESULTS_SCHEMA = z.object({
  results: z.array(
    z.object({
      channelPk: z.number(),
      priorityId: z.string().nullable(),
      reason: z.string().nullable().optional(),
    })
  ),
});

type LlmResult = z.infer<typeof RESULTS_SCHEMA>["results"][number];

type ChannelRow = {
  pk: number;
  connector: string;
  connector_description: string | null;
  account_label: string | null;
  title: string;
  link_types: unknown;
  current_default_priority_id: string | null;
};

type PriorityRow = {
  id: string;
  path: string;
  title: string;
};

/**
 * Durable Object that debounces per-user priority/channel change events
 * and runs a single LLM call to assign default routing priorities to
 * the user's connector channels. Triggered from:
 *   - POST /sync/priorities (create / rename / archive)
 *   - channel enable path on connector activation
 *
 * The DO is keyed by user_id. Each enqueue pushes the alarm to now + 5s,
 * so a rapid cluster of events coalesces into one LLM call.
 */
export class ChannelRouter extends DurableObject<Bindings> {
  private userId: string | null = null;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const stored = await ctx.storage.get<string>("userId");
      if (stored) this.userId = stored;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/enqueue" && request.method === "POST") {
      const body = await request.json<{ userId: string }>();
      if (!body.userId) {
        return new Response("Missing userId", { status: 400 });
      }
      if (!this.userId) {
        this.userId = body.userId;
        await this.ctx.storage.put("userId", body.userId);
      }
      await this.ctx.storage.setAlarm(Date.now() + DEBOUNCE_MS);
      return new Response("OK");
    }
    return new Response("Not found", { status: 404 });
  }

  async alarm(): Promise<void> {
    const logger = createLogger({
      component: "channel-router",
      user_id: this.userId ?? undefined,
    });

    if (!this.userId) {
      logger.error("ChannelRouter alarm with no userId");
      return;
    }

    const userId = this.userId;
    try {
      await withDb(this.env, async (db) => {
        await runRouter(this.env, db, userId, logger);
      });
      await notifyUserSyncByEnv(this.env, userId);
    } catch (error) {
      logger.error("ChannelRouter run failed", error as Error, {
        user_id: userId,
      });
      this.captureException(error as Error);
    }
  }

  private captureException(error: Error) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, this.userId ?? undefined, {
      durable_object: "ChannelRouter",
    });
    this.ctx.waitUntil(postHog.shutdown());
  }
}

/**
 * Enqueue a router run for a user. Safe to fire-and-forget via
 * executionCtx.waitUntil — the DO debounces repeated calls.
 */
export async function enqueueChannelRouter(
  env: Bindings,
  userId: string
): Promise<void> {
  const id = env.CHANNEL_ROUTER.idFromName(userId);
  const stub = env.CHANNEL_ROUTER.get(id);
  await stub.fetch(
    new Request("http://do/enqueue", {
      method: "POST",
      body: JSON.stringify({ userId }),
    })
  );
}

async function runRouter(
  env: Bindings,
  db: Kysely<DB>,
  userId: string,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const start = Date.now();

  const { priorities, channels, samplesByChannel } = await withUserDb(
    db,
    userId,
    async (trx) => {
      const p = await sql<PriorityRow>`
        SELECT p.id, p.path::text AS path, p.title
        FROM public.priority p
        WHERE p.user_id = ${userId}::uuid
          AND p.archived_at IS NULL
        ORDER BY p.path
        LIMIT ${MAX_PRIORITIES}
      `.execute(trx);

      const c = await sql<ChannelRow>`
        SELECT
          ch.id AS pk,
          COALESCE(tw.name, 'connector') AS connector,
          tw.description AS connector_description,
          ti.account_label,
          ch.title,
          ch.link_types,
          ch.default_priority_id AS current_default_priority_id
        FROM public.channel ch
        JOIN public.twist_instance ti ON ti.id = ch.twist_instance_id
        JOIN public.twist tw ON tw.id = ti.twist_id
        WHERE ti.owner_id = ${userId}::uuid
          AND ti.archived_at IS NULL
          AND ch.enabled = TRUE
        ORDER BY ch.id
        LIMIT ${MAX_CHANNELS_PER_CALL}
      `.execute(trx);

      const byChannel = new Map<number, string[]>();
      if (c.rows.length > 0) {
        // Random sample of thread titles per channel — not most-recent.
        // Recent-only biases the model toward whatever the user happened
        // to be working on this week (e.g. a run of testing docs in an
        // otherwise-general Drive). Random across history gives a
        // character sketch of the channel's long-run content mix.
        const channelTopics = c.rows.map((ch) => `channel:${ch.pk}`);
        const samples = await sql<{ channel_pk: number; title: string }>`
          WITH channel_threads AS (
            SELECT
              (substring(t.topic FROM 9))::bigint AS channel_pk,
              t.title
            FROM public.thread t
            WHERE t.archived_at IS NULL
              AND t.title IS NOT NULL
              AND length(trim(t.title)) > 0
              AND t.topic = ANY(${channelTopics}::text[])
          ),
          ranked AS (
            SELECT
              channel_pk,
              title,
              ROW_NUMBER() OVER (
                PARTITION BY channel_pk ORDER BY random()
              ) AS rn
            FROM channel_threads
          )
          SELECT channel_pk, title
          FROM ranked
          WHERE rn <= ${MAX_THREAD_TITLE_SAMPLES}
          ORDER BY channel_pk, rn
        `.execute(trx);

        for (const row of samples.rows) {
          const list = byChannel.get(row.channel_pk) ?? [];
          list.push(row.title);
          byChannel.set(row.channel_pk, list);
        }
      }

      return {
        priorities: p.rows,
        channels: c.rows,
        samplesByChannel: byChannel,
      };
    }
  );

  if (channels.length === 0) {
    logger.info("ChannelRouter skipped: no enabled channels", {
      user_id: userId,
    });
    return;
  }
  if (priorities.length === 0) {
    logger.info("ChannelRouter skipped: no priorities", { user_id: userId });
    return;
  }

  const results = await callLlm(
    env,
    priorities,
    channels,
    samplesByChannel,
    logger
  );
  if (!results) return;

  const validPriorityIds = new Set(priorities.map((p) => p.id));
  const currentByPk = new Map(
    channels.map((ch) => [ch.pk, ch.current_default_priority_id])
  );

  // Per-channel transactions: apply_channel_default re-files every candidate
  // thread for one channel and can exceed statement_timeout (30s) for users
  // with many threads on a single channel. Wrapping each channel in its own
  // transaction keeps one slow channel from rolling back every other update.
  let changed = 0;
  let firstError: Error | null = null;
  let failedCount = 0;
  for (const r of results) {
    const channelPk = Math.trunc(r.channelPk);
    if (!Number.isFinite(channelPk) || !currentByPk.has(channelPk)) continue;

    const currentId = currentByPk.get(channelPk) ?? null;
    const nextId =
      r.priorityId && validPriorityIds.has(r.priorityId)
        ? r.priorityId
        : null;
    const reason = (r.reason ?? "").slice(0, 500) || null;
    const priorityChanged = nextId !== currentId;

    try {
      await withUserDb(db, userId, async (trx) => {
        if (!priorityChanged) {
          await sql`
            UPDATE public.channel
            SET default_priority_reason = ${reason}
            WHERE id = ${channelPk}::bigint
              AND (default_priority_reason IS DISTINCT FROM ${reason})
          `.execute(trx);
          return;
        }

        await sql`
          UPDATE public.channel
          SET default_priority_id = ${nextId}::uuid,
              default_priority_reason = ${reason}
          WHERE id = ${channelPk}::bigint
        `.execute(trx);
        await rpc(trx, "apply_channel_default", { p_channel_id: channelPk });
      });
      if (priorityChanged) changed++;
    } catch (error) {
      failedCount++;
      if (!firstError) firstError = error as Error;
      logger.error(
        "ChannelRouter per-channel update failed",
        error as Error,
        { user_id: userId, channel_pk: channelPk }
      );
    }
  }

  logger.info("ChannelRouter run complete", {
    user_id: userId,
    channels_evaluated: channels.length,
    priorities_available: priorities.length,
    channels_changed: changed,
    channels_failed: failedCount,
    duration_ms: Date.now() - start,
  });

  // Surface the first per-channel failure so the alarm catch captures it to
  // PostHog. Other channels' work has already committed.
  if (firstError) throw firstError;
}

async function callLlm(
  env: Bindings,
  priorities: PriorityRow[],
  channels: ChannelRow[],
  samplesByChannel: Map<number, string[]>,
  logger: ReturnType<typeof createLogger>
): Promise<LlmResult[] | null> {
  if (
    !env.AI_GATEWAY_ACCOUNT_ID ||
    !env.AI_GATEWAY_ID ||
    !env.AI_GATEWAY_TOKEN
  ) {
    // Without gateway config (e.g. some test envs), skip the router rather
    // than fail loudly — the classifier still works via scoring + root.
    return null;
  }

  const gatewayBaseUrl = `https://gateway.ai.cloudflare.com/v1/${env.AI_GATEWAY_ACCOUNT_ID}/${env.AI_GATEWAY_ID}`;
  const anthropic = createAnthropic({
    baseURL: `${gatewayBaseUrl}/anthropic`,
    apiKey: env.ANTHROPIC_API_KEY,
    headers: { "cf-aig-authorization": `Bearer ${env.AI_GATEWAY_TOKEN}` },
  });

  const systemPrompt = `You assign a default Plot priority to each of a user's connector channels so new threads route to the right home automatically.

Output one result per input channel. Rules:
- priorityId must be exactly one of the provided priority ids, or null.
- Prefer null over guessing. When nothing clearly aligns, return null. The user will move a thread manually if they want a different home; guesses have a higher cost than nulls.
- reason must cite the concrete signal you used. Reason is stored for operator debugging only.

How to weight signals, in order:
1. **Connector purpose (strongest default).** What the connector is fundamentally for. A product-management / issue tracker (Linear, Jira, Asana) is usually for product/engineering work. A CRM (Salesforce, HubSpot, Attio) is usually for sales / customer relationships. A code host (GitHub, GitLab) is usually engineering. A design tool (Figma) is usually design. These are strong priors even when the channel name is generic. Map the connector to the priority whose label best matches its primary purpose.
2. **Account label.** The email domain or workspace name often locates the channel (e.g. \`kris@bigco.com\` → a 'BigCo' priority; \`Slack workspace "Acme"\` → 'Acme').
3. **Channel title.** Literal matches ("Family Calendar" → 'Personal > Family'). But titles like "general", "Inbox", "My Drive", "IMPORTANT", "All" are CONTAINERS — they mean "everything for this account" and should not be used to pick a sub-priority on their own. For container-style channels, fall back to connector purpose + account label.
4. **Sample titles (weakest).** The samples are a RANDOM draw from the channel's history — they are a character sketch, not a trend. Do not overfit to a few recent-looking titles; if the connector purpose and account already point somewhere, keep that assignment even if samples look off-theme. A general-purpose channel (My Drive, Inbox) will naturally have a long tail of random-looking titles.

Priority hierarchy uses ltree paths (dot-separated labels from root to leaf). Paths closer to the root are broader; deeper paths are more specific. Prefer the most specific priority whose meaning encompasses the channel; fall back to a parent if no specific child fits.`;

  const userPrompt = renderUserPrompt(priorities, channels, samplesByChannel);

  const model: any = anthropic("claude-sonnet-4-6");
  try {
    const result = await generateObject({
      model,
      schema: RESULTS_SCHEMA,
      schemaName: "ChannelDefaults",
      schemaDescription:
        "An object with a `results` array, one entry per input channel, each carrying channelPk (number), priorityId (uuid string or null), and reason (short string).",
      maxOutputTokens: 8_000,
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
    return result.object.results;
  } catch (error) {
    // Surface the raw model text when structured output validation fails
    // so we can see which shape the model produced and tighten the prompt.
    const raw = (error as { text?: unknown })?.text;
    logger.warn("ChannelRouter LLM call failed", {
      error: (error as Error).message,
      raw_sample:
        typeof raw === "string" ? raw.slice(0, 2000) : undefined,
      channel_count: channels.length,
      priority_count: priorities.length,
    });
    return null;
  }
}

function renderUserPrompt(
  priorities: PriorityRow[],
  channels: ChannelRow[],
  samplesByChannel: Map<number, string[]>
): string {
  const prioritiesBlock = priorities
    .map((p) => `  - id=${p.id} path=${p.path} title=${JSON.stringify(p.title)}`)
    .join("\n");

  const channelsBlock = channels
    .map((ch) => {
      const samples = samplesByChannel.get(ch.pk) ?? [];
      const samplesLine = samples.length
        ? `\n      sample_titles (random draw from history, not a trend): ${JSON.stringify(samples)}`
        : "";
      const linkTypes =
        ch.link_types && typeof ch.link_types === "object"
          ? Object.keys(ch.link_types as Record<string, unknown>).join(",")
          : "";
      const connectorLine = ch.connector_description
        ? `${JSON.stringify(ch.connector)} (${ch.connector_description})`
        : JSON.stringify(ch.connector);
      return `  - channelPk=${ch.pk} connector=${connectorLine} account=${JSON.stringify(
        ch.account_label ?? ""
      )} channelTitle=${JSON.stringify(ch.title)}${
        linkTypes ? ` linkTypes=${JSON.stringify(linkTypes)}` : ""
      }${samplesLine}`;
    })
    .join("\n");

  return `Priorities:
${prioritiesBlock}

Channels to route:
${channelsBlock}

For each channel, decide which priority is the right default home for new threads, or null if nothing clearly fits.`;
}
