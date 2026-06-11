/**
 * Canonical prod-extraction helpers (corpus schema v2).
 *
 * Shared by from-prod.ts, add-prod-cases.ts, add-prod-trainings.ts, and the
 * decision-log miner. Pure functions over a pg.Client + plain data: no file
 * IO and NO anonymization — every byte of raw PII extracted here must flow
 * through the single write choke point in emit.ts (`buildCorpusFiles`) or an
 * equivalent leak-checked writer before touching disk.
 */
import type pg from "pg";

/** Minimal client surface so tests can pass a raw pg.Client in a txn. */
export type PgClient = Pick<pg.Client, "query">;

// ===========================================================================
// Extracted shapes (raw, un-anonymized)
// ===========================================================================

export type ExtractedThread = {
  id: string;
  title: string | null;
  topic: string | null;
  contacts: string[];
  groups: string[];
  embedding: number[] | null;
  /** Provenance of `embedding`: thread.embedding vs earliest-note fallback. */
  embeddingSource: "thread-title" | "note-content" | null;
  /** thread.author_id ?? first non-archived note's author_id ?? null. */
  authorContactId: string | null;
  /** thread.created_by when thread.twist_id IS NOT NULL (a twist_instance id). */
  connectionId: string | null;
  facets: Record<string, string> | null;
  /** thread.created_at, ISO. */
  createdAt: string;
  /** thread_priority.priority_id for the extraction user (null when unfiled). */
  filedToPriority: string | null;
  /** thread_priority.updated_at (ISO) when user_moved = TRUE, else null. */
  movedAt: string | null;
};

export type ExtractedPriority = {
  id: string;
  path: string;
  title: string;
  key: string | null;
  description: string | null;
  facetFilters: Record<string, unknown> | null;
};

export type ExtractedContact = {
  id: string;
  email: string | null;
  name: string | null;
  linkedToUser: boolean;
};

export type ExtractedGroup = { id: string; title: string };

export type ExtractedConnection = {
  /** twist_instance id. */
  id: string;
  provider: string;
  /**
   * twist_instance_connection.actor_id (a contact — third-party PII), or
   * null when the instance has NO twist_instance_connection row at all.
   * Tic-less instances are real prod connections (verified live: many of
   * kris's twist_instances have zero tic rows): connection_org_key's actor
   * lateral finds no row for them, so acct.domain is NULL and the key falls
   * through to `team:<id>` (or NULL when personal). Emission synthesizes a
   * placeholder actor contact with NULL email/name so the sandbox reproduces
   * the identical org-key outcome — see placeholderActorContact in emit.ts.
   */
  actorContactId: string | null;
  teamId: number | null;
};

export type ExtractedChannel = {
  id: number;
  twistInstanceId: string;
  defaultPriorityId: string | null;
};

export type ExtractedWorld = {
  userId: string;
  userEmail: string;
  subscription: { plan: string; status: string } | null;
  priorities: ExtractedPriority[];
  contacts: ExtractedContact[];
  groups: ExtractedGroup[];
  connections: ExtractedConnection[];
  channels: ExtractedChannel[];
};

export type ExtractedNegative = {
  threadId: string;
  priorityId: string;
  /** Raw source text from thread_priority_negative (emit validates the enum). */
  source: string;
  /** Real row timestamp (backtest clock), ISO. */
  createdAt: string;
};

export type ActiveUserRow = {
  userId: string;
  threadPriorityCount: number;
  userMovedCount: number;
};

// ===========================================================================
// Row plumbing
// ===========================================================================

type ThreadRow = {
  id: string;
  title: string | null;
  topic: string | null;
  contacts: string[];
  groups: string[];
  embedding_text: string | null;
  note_embedding_text: string | null;
  author_id: string | null;
  note_author_id: string | null;
  created_by: string;
  twist_id: string | null;
  facets: unknown;
  created_at: Date;
  filed_to_priority: string | null;
  tp_updated_at: Date | null;
  user_moved: boolean | null;
};

/**
 * The single source of truth for thread hydration. `$1` is the extraction
 * user (drives the thread_priority join); callers append their own WHERE /
 * ORDER BY tail.
 *
 * NOTE on the two note subqueries: `note_embedding_text` and `note_author_id`
 * are deliberately INDEPENDENT subqueries with different WHERE predicates.
 * `note_embedding_text` selects the earliest note that HAS an embedding
 * (n.embedding IS NOT NULL); `note_author_id` selects the earliest note
 * regardless of embedding. They may therefore come from different rows.
 * This is intentional: the embedding fallback needs a usable vector, while
 * the author fallback just needs the earliest known author.
 */
const THREAD_SELECT = `
  SELECT t.id,
         t.title,
         t.topic,
         t.contacts,
         t.groups,
         t.embedding::text AS embedding_text,
         (
           SELECT n.embedding::text
             FROM public.note n
            WHERE n.thread_id = t.id
              AND n.archived_at IS NULL
              AND n.embedding IS NOT NULL
            ORDER BY n.created_at ASC
            LIMIT 1
         ) AS note_embedding_text,
         t.author_id,
         (
           SELECT n.author_id
             FROM public.note n
            WHERE n.thread_id = t.id
              AND n.archived_at IS NULL
            ORDER BY n.created_at ASC
            LIMIT 1
         ) AS note_author_id,
         t.created_by,
         t.twist_id,
         t.facets,
         t.created_at,
         tp.priority_id AS filed_to_priority,
         tp.updated_at AS tp_updated_at,
         tp.user_moved
    FROM public.thread t
    LEFT JOIN public.thread_priority tp
      ON tp.thread_id = t.id AND tp.user_id = $1`;

/** Parses a halfvec text literal ("[0.1, -0.2, ...]"); null unless 384-dim. */
export function parseHalfvec(literal: string | null): number[] | null {
  if (!literal) return null;
  const inner = literal.trim().replace(/^\[/, "").replace(/\]$/, "");
  const parts = inner.split(",").map((s) => Number(s.trim()));
  return parts.length === 384 ? parts : null;
}

function sanitizeFacets(raw: unknown): Record<string, string> | null {
  if (raw === null || raw === undefined) return null;
  if (typeof raw !== "object" || Array.isArray(raw)) return null;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    out[k] = typeof v === "string" ? v : String(v);
  }
  return out;
}

function mapThreadRow(r: ThreadRow): ExtractedThread {
  const threadVec = parseHalfvec(r.embedding_text);
  const noteVec = threadVec ? null : parseHalfvec(r.note_embedding_text);
  return {
    id: r.id,
    title: r.title,
    topic: r.topic,
    contacts: r.contacts,
    groups: r.groups,
    embedding: threadVec ?? noteVec,
    embeddingSource: threadVec ? "thread-title" : noteVec ? "note-content" : null,
    authorContactId: r.author_id ?? r.note_author_id ?? null,
    connectionId: r.twist_id !== null ? r.created_by : null,
    facets: sanitizeFacets(r.facets),
    createdAt: new Date(r.created_at).toISOString(),
    filedToPriority: r.filed_to_priority,
    movedAt:
      r.user_moved && r.tp_updated_at
        ? new Date(r.tp_updated_at).toISOString()
        : null,
  };
}

// ===========================================================================
// Public extraction functions
// ===========================================================================

/**
 * Hydrates specific threads by id (no archived filter — explicit picks are
 * the caller's responsibility). Returns found threads in the input id order;
 * ids with no row for this user are silently omitted (compare lengths).
 */
export async function hydrateThreadsByIds(
  client: PgClient,
  userId: string,
  threadIds: string[]
): Promise<ExtractedThread[]> {
  if (threadIds.length === 0) return [];
  const { rows } = await client.query<ThreadRow>(
    `${THREAD_SELECT}
      WHERE t.id = ANY($2::uuid[])`,
    [userId, threadIds]
  );
  const byId = new Map(rows.map((r) => [r.id, mapThreadRow(r)]));
  const out: ExtractedThread[] = [];
  for (const id of threadIds) {
    const t = byId.get(id);
    if (t) out.push(t);
  }
  return out;
}

/**
 * All non-archived threads the user explicitly filed (user_moved = TRUE),
 * most recent move first. `movedAt` = thread_priority.updated_at — the best
 * available approximation of the move time until decision-log history
 * accrues (documented caveat in the design spec).
 */
export async function loadTrainingThreads(
  client: PgClient,
  userId: string
): Promise<ExtractedThread[]> {
  const { rows } = await client.query<ThreadRow>(
    `${THREAD_SELECT}
      WHERE tp.user_id IS NOT NULL
        AND tp.user_moved = TRUE
        AND t.archived_at IS NULL
        AND t.draft = FALSE
      ORDER BY tp.updated_at DESC`,
    [userId]
  );
  return rows.map(mapThreadRow);
}

/** All thread_priority_negative rows for the user, with real timestamps. */
export async function loadNegatives(
  client: PgClient,
  userId: string
): Promise<ExtractedNegative[]> {
  const { rows } = await client.query<{
    thread_id: string;
    priority_id: string;
    source: string;
    created_at: Date;
  }>(
    `SELECT thread_id, priority_id, source, created_at
       FROM public.thread_priority_negative
      WHERE user_id = $1
      ORDER BY created_at ASC, thread_id`,
    [userId]
  );
  return rows.map((r) => ({
    threadId: r.thread_id,
    priorityId: r.priority_id,
    source: r.source,
    createdAt: new Date(r.created_at).toISOString(),
  }));
}

/**
 * World entities for one user: identity + subscription, active priorities
 * (incl. description/facet_filters), contacts (linked aliases + thread
 * counterparties), groups referenced by any of the user's threads, channels
 * referenced by `channel:N` topics, and the channel-parent connections
 * (owner-remapped — see loadConnections). Thread-derived connections are NOT
 * included here; the caller merges them in via loadConnections.
 */
export async function loadWorldEntities(
  client: PgClient,
  userId: string
): Promise<ExtractedWorld> {
  const { rows: userRows } = await client.query<{ email: string }>(
    `SELECT email FROM public."user" WHERE id = $1`,
    [userId]
  );
  if (userRows.length === 0) throw new Error(`User ${userId} not found`);
  const userEmail = userRows[0]!.email;

  const { rows: subRows } = await client.query<{ plan: string; status: string }>(
    `SELECT plan::text AS plan, status::text AS status
       FROM public.user_subscription
      WHERE user_id = $1
      ORDER BY created_at DESC
      LIMIT 1`,
    [userId]
  );
  const subscription = subRows[0] ?? null;

  const { rows: priorityRows } = await client.query<{
    id: string;
    path: string;
    title: string;
    key: string | null;
    description: string | null;
    facet_filters: Record<string, unknown> | null;
  }>(
    `SELECT id, path::text AS path, title, key, description, facet_filters
       FROM public.priority
      WHERE user_id = $1 AND archived_at IS NULL
      ORDER BY path`,
    [userId]
  );
  const priorities: ExtractedPriority[] = priorityRows.map((p) => ({
    id: p.id,
    path: p.path,
    title: p.title,
    key: p.key,
    description: p.description,
    facetFilters: p.facet_filters,
  }));

  // Linked aliases (the user's own contacts) PLUS counterparty contacts that
  // appear in any of the user's threads. Ordered for deterministic emission.
  const { rows: contactRows } = await client.query<{
    id: string;
    email: string | null;
    name: string | null;
    linked_to_user: boolean;
  }>(
    `WITH linked AS (
       SELECT c.id, c.email, c.name, TRUE AS linked_to_user
         FROM public.contact c
         JOIN public.user_contact uc
           ON uc.contact_id = c.id AND uc.user_id = $1 AND uc.linked = TRUE
        WHERE c.archived_at IS NULL
     ),
     counterparties AS (
       SELECT DISTINCT c.id, c.email, c.name, FALSE AS linked_to_user
         FROM public.contact c
         JOIN public.thread t
           ON c.id = ANY(t.contacts)
         JOIN public.thread_priority tp ON tp.thread_id = t.id
        WHERE tp.user_id = $1
          AND t.archived_at IS NULL
          AND c.archived_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.user_contact uc
            WHERE uc.contact_id = c.id AND uc.user_id = $1 AND uc.linked = TRUE
          )
     )
     SELECT * FROM (
       SELECT * FROM linked
       UNION ALL
       SELECT * FROM counterparties
     ) all_contacts
     ORDER BY linked_to_user DESC, id`,
    [userId]
  );
  const contacts: ExtractedContact[] = contactRows.map((c) => ({
    id: c.id,
    email: c.email,
    name: c.name,
    linkedToUser: c.linked_to_user,
  }));

  const { rows: groupRows } = await client.query<{ id: string; title: string }>(
    `SELECT DISTINCT g.id, g.name AS title
       FROM public."group" g
       JOIN public.thread t ON g.id = ANY(t.groups)
       JOIN public.thread_priority tp ON tp.thread_id = t.id
      WHERE tp.user_id = $1
        AND t.archived_at IS NULL
      ORDER BY g.id`,
    [userId]
  );

  // Channels referenced by `channel:N` topics on the user's threads. Foreign
  // or archived default priorities are nulled rather than dropping the row.
  const { rows: channelRows } = await client.query<{
    id: number;
    twist_instance_id: string;
    default_priority_id: string | null;
  }>(
    `SELECT c.id::int AS id,
            c.twist_instance_id,
            CASE
              WHEN p.user_id = $1 AND p.archived_at IS NULL THEN c.default_priority_id
              ELSE NULL
            END AS default_priority_id
       FROM public.channel c
       LEFT JOIN public.priority p ON p.id = c.default_priority_id
      WHERE c.id IN (
        SELECT DISTINCT NULLIF(substring(t.topic FROM 9), '')::bigint
          FROM public.thread t
          JOIN public.thread_priority tp ON tp.thread_id = t.id
         WHERE tp.user_id = $1
           AND t.topic ~ '^channel:[0-9]+$'
           AND t.archived_at IS NULL
      )
      ORDER BY c.id`,
    [userId]
  );
  const channels: ExtractedChannel[] = channelRows.map((ch) => ({
    id: ch.id,
    twistInstanceId: ch.twist_instance_id,
    defaultPriorityId: ch.default_priority_id,
  }));

  const { connections } = await loadConnections(client, [
    ...new Set(channels.map((ch) => ch.twistInstanceId)),
  ]);

  return {
    userId,
    userEmail,
    subscription,
    priorities,
    contacts,
    groups: groupRows,
    connections,
    channels,
  };
}

/**
 * Hydrates connections (twist_instance + twist_instance_connection) by
 * twist_instance id. OWNER REMAP per spec C2: provider/actor are read from
 * the REAL owner's connection row (`tic.user_id = ti.owner_id`), but the
 * emitted corpus connection is always owned by the world user — the sandbox
 * inserts owner = world user regardless. When the owner row is missing, any
 * other user's row for the instance is used as a fallback.
 *
 * Instances with NO twist_instance_connection row at all are still real prod
 * connections and are KEPT, with `actorContactId: null` and a provider hint
 * taken from the parent twist's handle (`twist_instance.twist_id -> twist`,
 * 'unknown' when unresolvable) — there is no tic row to read a provider
 * from. Dropping them would also drop every channel they parent (channel
 * topics drive the channel_default/topic classifier stages) and null the
 * threads' connection refs (killing the origin exact-match signal). Only ids
 * with no twist_instance row at all (genuinely nonexistent) land in
 * `missing`.
 */
export async function loadConnections(
  client: PgClient,
  twistInstanceIds: string[]
): Promise<{ connections: ExtractedConnection[]; missing: string[] }> {
  if (twistInstanceIds.length === 0) return { connections: [], missing: [] };
  const { rows } = await client.query<{
    id: string;
    team_id: number | null;
    provider: string | null;
    actor_id: string | null;
    twist_handle: string | null;
  }>(
    `SELECT DISTINCT ON (ti.id)
            ti.id,
            ti.team_id::int AS team_id,
            tic.provider,
            tic.actor_id,
            tw.handle AS twist_handle
       FROM public.twist_instance ti
       LEFT JOIN public.twist_instance_connection tic
         ON tic.twist_instance_id = ti.id
       LEFT JOIN public.twist tw
         ON tw.id = ti.twist_id
      WHERE ti.id = ANY($1::uuid[])
      ORDER BY ti.id, (tic.user_id = ti.owner_id) DESC NULLS LAST, tic.provider`,
    [twistInstanceIds]
  );
  const found = new Map(rows.map((r) => [r.id, r]));
  const connections: ExtractedConnection[] = [];
  const missing: string[] = [];
  for (const id of new Set(twistInstanceIds)) {
    const row = found.get(id);
    if (!row) {
      missing.push(id);
    } else if (row.provider !== null && row.actor_id !== null) {
      connections.push({
        id: row.id,
        provider: row.provider,
        actorContactId: row.actor_id,
        teamId: row.team_id,
      });
    } else {
      // Tic-less instance: keep the connection; emit synthesizes the
      // placeholder actor (see ExtractedConnection.actorContactId).
      connections.push({
        id: row.id,
        provider: row.twist_handle?.toLowerCase() || "unknown",
        actorContactId: null,
        teamId: row.team_id,
      });
    }
  }
  return { connections, missing };
}

/** Hydrates contacts by id (no archived filter — completeness over hygiene). */
export async function loadContactsByIds(
  client: PgClient,
  userId: string,
  contactIds: string[]
): Promise<ExtractedContact[]> {
  if (contactIds.length === 0) return [];
  const { rows } = await client.query<{
    id: string;
    email: string | null;
    name: string | null;
    linked: boolean;
  }>(
    `SELECT c.id, c.email, c.name,
            EXISTS (
              SELECT 1 FROM public.user_contact uc
               WHERE uc.contact_id = c.id AND uc.user_id = $1 AND uc.linked = TRUE
            ) AS linked
       FROM public.contact c
      WHERE c.id = ANY($2::uuid[])
      ORDER BY c.id`,
    [userId, contactIds]
  );
  return rows.map((c) => ({
    id: c.id,
    email: c.email,
    name: c.name,
    linkedToUser: c.linked,
  }));
}

/** Hydrates groups by id. */
export async function loadGroupsByIds(
  client: PgClient,
  groupIds: string[]
): Promise<ExtractedGroup[]> {
  if (groupIds.length === 0) return [];
  const { rows } = await client.query<{ id: string; title: string }>(
    `SELECT id, name AS title FROM public."group"
      WHERE id = ANY($1::uuid[])
      ORDER BY id`,
    [groupIds]
  );
  return rows;
}

/**
 * Most active users by thread_priority volume. Returns user ids and counts
 * ONLY — never emails or any other identity (multi-user extraction is
 * authorized per-user by id; see spec C2).
 */
export async function listActiveUsers(
  client: PgClient,
  limit = 20
): Promise<ActiveUserRow[]> {
  const { rows } = await client.query<{
    user_id: string;
    thread_priority_count: number;
    user_moved_count: number;
  }>(
    `SELECT tp.user_id,
            count(*)::int AS thread_priority_count,
            (count(*) FILTER (WHERE tp.user_moved))::int AS user_moved_count
       FROM public.thread_priority tp
      GROUP BY tp.user_id
      ORDER BY user_moved_count DESC, thread_priority_count DESC, tp.user_id
      LIMIT $1`,
    [limit]
  );
  return rows.map((r) => ({
    userId: r.user_id,
    threadPriorityCount: r.thread_priority_count,
    userMovedCount: r.user_moved_count,
  }));
}

/** Resolves a user id from an email. Throws when not found. */
export async function resolveUserIdByEmail(
  client: PgClient,
  email: string
): Promise<string> {
  const { rows } = await client.query<{ id: string }>(
    `SELECT id FROM public."user" WHERE email = $1`,
    [email]
  );
  if (rows.length === 0) throw new Error(`User ${email} not found`);
  return rows[0]!.id;
}

/**
 * Thread ids matching an 8-hex case-id prefix for this user (used by the
 * refresh path when a case predates source_thread_id). Multiple matches mean
 * the prefix is ambiguous; the caller keeps the case verbatim.
 */
export async function resolveThreadIdPrefix(
  client: PgClient,
  userId: string,
  prefix: string
): Promise<string[]> {
  if (!/^[0-9a-f]{8}$/i.test(prefix)) return [];
  const { rows } = await client.query<{ id: string }>(
    `SELECT t.id
       FROM public.thread t
       JOIN public.thread_priority tp
         ON tp.thread_id = t.id AND tp.user_id = $1
      WHERE t.id::text LIKE $2
      ORDER BY t.id`,
    [userId, `${prefix.toLowerCase()}%`]
  );
  return rows.map((r) => r.id);
}

// ===========================================================================
// Case sampling (ids only — hydration goes through hydrateThreadsByIds)
// ===========================================================================

const TOPIC_SHAPES: Array<{ shape: string; predicate: string }> = [
  {
    shape: "channel-with-default",
    predicate:
      "t.topic ~ '^channel:[0-9]+$' AND ch.default_priority_id IS NOT NULL",
  },
  {
    shape: "channel-no-default",
    predicate:
      "t.topic ~ '^channel:[0-9]+$' AND ch.default_priority_id IS NULL",
  },
  { shape: "priority-key", predicate: "t.topic LIKE 'priority:%'" },
  { shape: "null-topic", predicate: "t.topic IS NULL" },
  {
    shape: "other-topic",
    predicate:
      "t.topic IS NOT NULL AND t.topic !~ '^channel:' AND t.topic NOT LIKE 'priority:%'",
  },
];

/**
 * Stratified sample of auto-filed (user_moved = FALSE) thread ids by topic
 * shape — deterministic stride sampling over each shape's most recent rows,
 * mirroring the v1 seeder's behavior.
 */
export async function sampleStratifiedCaseThreadIds(
  client: PgClient,
  userId: string,
  caseCount: number,
  excludeIds: Set<string>,
  activePriorityIds: Set<string>
): Promise<string[]> {
  if (caseCount <= 0) return [];
  const targetPer = Math.ceil(caseCount / TOPIC_SHAPES.length);
  const out: string[] = [];
  for (const s of TOPIC_SHAPES) {
    const { rows } = await client.query<{
      id: string;
      filed_to_priority: string;
    }>(
      `SELECT t.id, tp.priority_id AS filed_to_priority
         FROM public.thread_priority tp
         JOIN public.thread t ON t.id = tp.thread_id
         LEFT JOIN public.channel ch
           ON t.topic ~ '^channel:[0-9]+$'
          AND ch.id = NULLIF(substring(t.topic FROM 9), '')::bigint
        WHERE tp.user_id = $1
          AND tp.user_moved = FALSE
          AND tp.priority_id IS NOT NULL
          AND t.archived_at IS NULL
          AND t.draft = FALSE
          AND ${s.predicate}
        ORDER BY t.created_at DESC NULLS LAST
        LIMIT $2`,
      [userId, targetPer * 3] // overfetch then stride-sample
    );
    const filtered = rows.filter(
      (r) => !excludeIds.has(r.id) && activePriorityIds.has(r.filed_to_priority)
    );
    const stride = Math.max(1, Math.floor(filtered.length / targetPer));
    for (
      let i = 0;
      i < filtered.length && out.length < caseCount;
      i += stride
    ) {
      out.push(filtered[i]!.id);
    }
  }
  return out.slice(0, caseCount);
}

/**
 * `--timeline-cases`: N auto-filed thread ids spread evenly across the
 * user's thread.created_at timeline (for backtest-oriented corpora).
 */
export async function sampleTimelineCaseThreadIds(
  client: PgClient,
  userId: string,
  n: number,
  excludeIds: Set<string>,
  activePriorityIds: Set<string>
): Promise<string[]> {
  if (n <= 0) return [];
  const { rows } = await client.query<{
    id: string;
    filed_to_priority: string;
  }>(
    `SELECT t.id, tp.priority_id AS filed_to_priority
       FROM public.thread_priority tp
       JOIN public.thread t ON t.id = tp.thread_id
      WHERE tp.user_id = $1
        AND tp.user_moved = FALSE
        AND tp.priority_id IS NOT NULL
        AND t.archived_at IS NULL
        AND t.draft = FALSE
      ORDER BY t.created_at ASC, t.id`,
    [userId]
  );
  const candidates = rows
    .filter(
      (r) => !excludeIds.has(r.id) && activePriorityIds.has(r.filed_to_priority)
    )
    .map((r) => r.id);
  if (candidates.length <= n) return candidates;
  const picked: string[] = [];
  const seen = new Set<number>();
  for (let i = 0; i < n; i++) {
    const idx =
      n === 1 ? 0 : Math.round((i * (candidates.length - 1)) / (n - 1));
    if (!seen.has(idx)) {
      seen.add(idx);
      picked.push(candidates[idx]!);
    }
  }
  return picked;
}
