import { Kysely, PostgresDialect } from "kysely";
import pg from "pg";

import type {
  Corpus,
  CorpusNegative,
  CorpusThreadBase,
  CorpusTrainingSet,
  CorpusTrainingThread,
  CorpusWorld,
} from "../corpus/schema";
import { deterministicUuid } from "../corpus/hash";
import { resolveDatabaseUrl } from "./resolve-db-url";

/**
 * Corpus-declared numeric identity ids (teams, synthetic per-provider twists)
 * are offset into a high range so they cannot collide with live dev rows.
 * IMPORTANT: the OFFSET ids are what surfaces externally — e.g.
 * `connection_org_key` returns `team:<offset id>` — so the same offset must be
 * applied everywhere a team id is referenced (twist_instance.team_id, tests).
 */
const NUMERIC_ID_OFFSET = 1_000_000_000;

/**
 * Maps each distinct connection provider to a stable synthetic `twist` bigint
 * id (sorted providers, id = NUMERIC_ID_OFFSET + index), and each connection
 * to its provider's twist id. Shared by loadWorld (which inserts the twist
 * rows), loadTrainingSet, and stageCandidate (which write thread.twist_id).
 */
function connectionTwists(world: CorpusWorld): {
  providers: string[];
  twistIdByProvider: Map<string, number>;
  twistIdByConnection: Map<string, number>;
} {
  const providers = [...new Set(world.connections.map((c) => c.provider))].sort();
  const twistIdByProvider = new Map(
    providers.map((p, i) => [p, NUMERIC_ID_OFFSET + i])
  );
  const twistIdByConnection = new Map(
    world.connections.map((c) => [c.id, twistIdByProvider.get(c.provider)!])
  );
  return { providers, twistIdByProvider, twistIdByConnection };
}

export type SandboxOptions = {
  /** Postgres connection string. Defaults to $DATABASE_URL. */
  databaseUrl?: string;
};

export type SandboxHandle = {
  db: Kysely<Record<string, unknown>>;
  rawQuery: (text: string, values?: unknown[]) => Promise<{ rows: unknown[] }>;
  /** Wraps work in a SAVEPOINT so per-case mutations can be rolled back. */
  withSavepoint: <T>(name: string, fn: () => Promise<T>) => Promise<T>;
  /** Releases all resources; rolls back the outer transaction (no data persists). */
  close: () => Promise<void>;
};

/**
 * Transactional sandbox. Opens one connection, BEGINs a transaction, lets the
 * caller load world state and run cases inside SAVEPOINTs, and ROLLBACKs
 * everything when closed. No data persists to the dev DB.
 *
 * The sandbox uses the live `public` schema so it exercises the production
 * classifier function and triggers unchanged — isolation comes from
 * transactional rollback plus fresh UUIDs from the corpus (never colliding
 * with existing dev data).
 */
export async function openSandbox(opts: SandboxOptions = {}): Promise<SandboxHandle> {
  const url = opts.databaseUrl ?? resolveDatabaseUrl();
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  await client.query("BEGIN");

  const rawQuery = async (text: string, values?: unknown[]) => {
    const res = await client.query(text, values);
    return { rows: res.rows };
  };

  // Minimal Kysely instance bound to the same client. We use rawQuery for
  // everything; the Kysely handle is exposed only because some classifier
  // implementations may want to compose queries.
  const db = new Kysely<Record<string, unknown>>({
    dialect: new PostgresDialect({
      pool: {
        connect: async () => client,
        end: async () => {},
      } as unknown as pg.Pool,
    }),
  });

  let savepointCounter = 0;
  const withSavepoint = async <T>(name: string, fn: () => Promise<T>): Promise<T> => {
    const safe = name.replace(/[^A-Za-z0-9_]/g, "_");
    const sp = `sp_${safe}_${++savepointCounter}`;
    await client.query(`SAVEPOINT ${sp}`);
    try {
      const result = await fn();
      await client.query(`ROLLBACK TO SAVEPOINT ${sp}`);
      await client.query(`RELEASE SAVEPOINT ${sp}`);
      return result;
    } catch (err) {
      try {
        await client.query(`ROLLBACK TO SAVEPOINT ${sp}`);
        await client.query(`RELEASE SAVEPOINT ${sp}`);
      } catch {
        /* ignore secondary errors */
      }
      throw err;
    }
  };

  const close = async () => {
    try {
      await client.query("ROLLBACK");
    } finally {
      await client.end();
    }
  };

  return { db, rawQuery, withSavepoint, close };
}

/**
 * Loads a corpus world into the open sandbox transaction. After this returns,
 * the user, priorities, contacts, groups, channels, and embeddings exist
 * (only inside the outer transaction). Training threads are NOT inserted —
 * each training set is loaded separately via loadTrainingSet so the runner
 * can iterate across multiple variants.
 */
export async function loadWorld(
  sandbox: SandboxHandle,
  corpus: Corpus
): Promise<void> {
  const { rawQuery } = sandbox;
  const { world } = corpus;

  // Disable user triggers during world load so we can:
  // (1) skip activate_invited_user (which creates Everything + Using Plot
  //     auto-priorities that would conflict with the corpus tree); and
  // (2) avoid running peer-filing / seq-bump triggers on rows that don't
  //     reflect a real user action.
  // Trigger evaluation is restored before staging candidates so the case
  // path exercises the full production trigger chain.
  await rawQuery(`SET LOCAL session_replication_role = replica`);

  await rawQuery(`INSERT INTO public."user" (id, email) VALUES ($1, $2)`, [
    world.user.id,
    world.user.email,
  ]);

  // 1b. Subscription (when declared; absent/null = free, no row). Billing
  //     cycle bounds are NOT NULL — fixed constants, never read by signals.
  if (world.user.subscription !== null) {
    await rawQuery(
      `INSERT INTO public.user_subscription
         (user_id, plan, status, billing_cycle_start, billing_cycle_end)
       VALUES ($1, $2::subscription_plan, $3::subscription_status,
               '2026-01-01', '2027-01-01')`,
      [world.user.id, world.user.subscription.plan, world.user.subscription.status]
    );
  }

  // 1c. Teams (org-key `team:` branch). Identity ids are offset; insert must
  //     fail loudly on collision with live dev rows (no ON CONFLICT).
  for (const team of world.teams) {
    await rawQuery(
      `INSERT INTO public.team (id, name)
       OVERRIDING SYSTEM VALUE
       VALUES ($1, $2)`,
      [NUMERIC_ID_OFFSET + team.id, team.name]
    );
  }

  // 1d. One synthetic twist per distinct provider. The synthesized NOT NULL
  //     columns and the personal-environment owner shape satisfy
  //     twist_owner_check (user_id set, publisher_id NULL).
  const twists = connectionTwists(world);
  for (const provider of twists.providers) {
    await rawQuery(
      `INSERT INTO public.twist
         (id, twist_package_id, user_id, environment, name, handle, version)
       OVERRIDING SYSTEM VALUE
       VALUES ($1, $2, $3, 'personal', $4, $4, '0.0.0-eval')`,
      [
        twists.twistIdByProvider.get(provider),
        deterministicUuid(provider),
        world.user.id,
        provider,
      ]
    );
  }

  // 1e. Connections: twist_instance (the connection itself; its uuid doubles
  //     as an actor id) + twist_instance_connection (whose actor contact's
  //     email domain drives connection_org_key).
  for (const conn of world.connections) {
    await rawQuery(
      `INSERT INTO public.twist_instance (id, twist_id, owner_id, team_id, name)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        conn.id,
        twists.twistIdByConnection.get(conn.id),
        world.user.id,
        conn.teamId === null ? null : NUMERIC_ID_OFFSET + conn.teamId,
        `eval ${conn.provider} ${conn.slug}`,
      ]
    );
    await rawQuery(
      `INSERT INTO public.twist_instance_connection
         (twist_instance_id, user_id, provider, actor_id)
       VALUES ($1, $2, $3, $4)`,
      [conn.id, world.user.id, conn.provider, conn.accountContactId]
    );
  }

  // 2. Priorities. Path ordering matters (parents before children).
  //    description/facet_filters are v2 additions; v1 normalization yields
  //    nulls, which is identical to omitting the columns (no defaults).
  const sortedPriorities = [...world.priorities].sort(
    (a, b) => a.path.split(".").length - b.path.split(".").length
  );
  for (const p of sortedPriorities) {
    await rawQuery(
      `INSERT INTO public.priority
         (id, user_id, created_by, path, title, key, description, facet_filters)
       VALUES ($1, $2, $2, $3::ltree, $4, $5, $6, $7::jsonb)`,
      [
        p.id,
        world.user.id,
        p.path,
        p.title,
        p.key,
        p.description,
        p.facetFilters === null ? null : JSON.stringify(p.facetFilters),
      ]
    );
  }

  // 3. Contacts. user_contact rows mark which contacts are "linked" to the
  //    user, which expand_contacts() uses for alias-aware Jaccard.
  //    v2 worlds also insert contact.name; v1 worlds MUST NOT — the LLM
  //    tiebreaker prompt renders COALESCE(name, email, id), so adding names
  //    under v1 would change prompts and cache keys (byte-exact compat).
  //    v2 inserts are plain (no ON CONFLICT) so an id collision with live dev
  //    rows throws instead of silently mixing dev data into eval signals;
  //    v1 keeps the legacy conflict-tolerant inserts byte-exactly.
  for (const c of world.contacts) {
    if (world.schemaVersion >= 2) {
      await rawQuery(
        `INSERT INTO public.contact (id, email, name, user_id)
         VALUES ($1, $2, $3, $4)`,
        [c.id, c.email, c.name, c.linked_to_user ? world.user.id : null]
      );
      if (c.linked_to_user) {
        await rawQuery(
          `INSERT INTO public.user_contact (user_id, contact_id, linked)
           VALUES ($1, $2, TRUE)`,
          [world.user.id, c.id]
        );
      }
    } else {
      await rawQuery(
        `INSERT INTO public.contact (id, email, user_id)
         VALUES ($1, $2, $3)
         ON CONFLICT (id) DO NOTHING`,
        [c.id, c.email, c.linked_to_user ? world.user.id : null]
      );
      if (c.linked_to_user) {
        await rawQuery(
          `INSERT INTO public.user_contact (user_id, contact_id, linked)
           VALUES ($1, $2, TRUE)
           ON CONFLICT (user_id, contact_id) DO NOTHING`,
          [world.user.id, c.id]
        );
      }
    }
  }

  // 4. Groups. Plot's group table is reserved-keyword-named ("group").
  //    Fails loudly on id collision in both v1 and v2 (long-standing plain
  //    INSERT behavior).
  for (const g of world.groups) {
    await rawQuery(
      `INSERT INTO public."group" (id, name, created_by) VALUES ($1, $2, $3)`,
      [g.id, g.title, world.user.id]
    );
  }

  // 5. Channels. v2 channels reference their declared connection's
  //    twist_instance and must fail loudly on an id collision with live dev
  //    rows — a silent collision (e.g. an existing channel's real
  //    default_priority_id) would corrupt results invisibly. v1 channels keep
  //    the legacy placeholder parent + conflict-tolerant insert byte-exactly.
  for (const ch of world.channels) {
    if (ch.connectionId !== null) {
      await rawQuery(
        `INSERT INTO public.channel (id, twist_instance_id, channel_id, title, default_priority_id)
         OVERRIDING SYSTEM VALUE
         VALUES ($1, $2, $3, $4, $5)`,
        [
          ch.id,
          ch.connectionId,
          `synthetic-${ch.id}`,
          `Synthetic channel ${ch.id}`,
          ch.default_priority_id,
        ]
      );
    } else {
      await rawQuery(
        `INSERT INTO public.channel (id, twist_instance_id, channel_id, title, default_priority_id)
         OVERRIDING SYSTEM VALUE
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (id) DO NOTHING`,
        [
          ch.id,
          world.user.id, // placeholder; FK validation happens only on parent table
          `synthetic-${ch.id}`,
          `Synthetic channel ${ch.id}`,
          ch.default_priority_id,
        ]
      );
    }
  }

  // Re-enable triggers so subsequent training-set and candidate inserts go
  // through the normal production path (peer filing, seq bumps, etc.).
  await rawQuery(`SET LOCAL session_replication_role = origin`);
}

/**
 * Inserts a training set's threads into the sandbox. Each becomes a thread
 * row + a thread_priority row with user_moved=TRUE (the classifier's
 * training signal). Callers should wrap this in a savepoint so the rows can
 * be rolled back when switching to the next training set.
 *
 * Triggers are suppressed during the load because these threads represent
 * historical user actions whose side effects (peer filing) already happened
 * in production and would only add noise here.
 */
export async function loadTrainingSet(
  sandbox: SandboxHandle,
  corpus: Corpus,
  trainingSet: CorpusTrainingSet
): Promise<void> {
  await insertTrainingThreads(sandbox, corpus, trainingSet.threads);
  await insertNegatives(
    sandbox,
    corpus,
    trainingSet.negativeThreads,
    trainingSet.negatives
  );
}

/** Shared thread-row INSERT for training and negative-evidence threads. */
async function insertThreadRow(
  sandbox: SandboxHandle,
  corpus: Corpus,
  twists: ReturnType<typeof connectionTwists>,
  t: CorpusThreadBase
): Promise<void> {
  const { rawQuery } = sandbox;
  const { world } = corpus;
  const emb = t.embedding_ref ? corpus.embeddings.get(t.embedding_ref) : null;
  const embLiteral = emb ? toHalfvecLiteral(emb.vector) : null;
  const values = [
    t.id,
    // created_by precedence: explicit override (carries v1 author
    // semantics), else the connection (twist_instance) like production
    // connector-created threads, else the world user.
    t.createdByOverride ?? t.connectionId ?? world.user.id,
    t.authorContactId,
    t.connectionId === null
      ? null
      : (twists.twistIdByConnection.get(t.connectionId) ?? null),
    t.title,
    t.topic,
    t.contacts,
    t.groups,
    embLiteral,
    t.facets === null ? null : JSON.stringify(t.facets),
  ];
  if (t.createdAt !== null) {
    // Triggers are disabled here, so the explicit value sticks.
    await rawQuery(
      `INSERT INTO public.thread
         (id, created_by, author_id, twist_id, title, topic, contacts,
          groups, embedding, facets, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7::uuid[], $8::uuid[], $9::halfvec,
               $10::jsonb, $11)`,
      [...values, t.createdAt]
    );
  } else {
    await rawQuery(
      `INSERT INTO public.thread
         (id, created_by, author_id, twist_id, title, topic, contacts,
          groups, embedding, facets)
       VALUES ($1, $2, $3, $4, $5, $6, $7::uuid[], $8::uuid[], $9::halfvec,
               $10::jsonb)`,
      values
    );
  }
}

/**
 * Inserts training threads (thread row + user_moved thread_priority filing)
 * into the open sandbox transaction. The helper sets and restores
 * `session_replication_role` itself, so every call site — the full
 * loadTrainingSet batch and each incremental backtest batch — gets trigger
 * suppression without remembering to wrap. No statements run for an empty
 * batch.
 */
export async function insertTrainingThreads(
  sandbox: SandboxHandle,
  corpus: Corpus,
  threads: CorpusTrainingThread[]
): Promise<void> {
  if (threads.length === 0) return;
  const { rawQuery } = sandbox;
  const twists = connectionTwists(corpus.world);

  await rawQuery(`SET LOCAL session_replication_role = replica`);

  for (const t of threads) {
    await insertThreadRow(sandbox, corpus, twists, t);
    await rawQuery(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved)
       VALUES ($1, $2, $3, TRUE)
       ON CONFLICT (thread_id, user_id) DO UPDATE SET
         priority_id = EXCLUDED.priority_id,
         user_moved = TRUE`,
      [t.id, corpus.world.user.id, t.filedToPriority]
    );
  }

  await rawQuery(`SET LOCAL session_replication_role = origin`);
}

/**
 * Inserts negative-evidence rows: thread rows for `negativeThreads` (no
 * thread_priority filing — they exist only to be referenced) followed by
 * `negatives` (thread_priority_negative rows). Like insertTrainingThreads,
 * the helper wraps itself in replica role; no statements run when both
 * arrays are empty.
 */
export async function insertNegatives(
  sandbox: SandboxHandle,
  corpus: Corpus,
  negativeThreads: CorpusThreadBase[],
  negatives: CorpusNegative[]
): Promise<void> {
  if (negativeThreads.length === 0 && negatives.length === 0) return;
  const { rawQuery } = sandbox;
  const twists = connectionTwists(corpus.world);

  await rawQuery(`SET LOCAL session_replication_role = replica`);

  for (const t of negativeThreads) {
    await insertThreadRow(sandbox, corpus, twists, t);
  }

  for (const n of negatives) {
    if (n.createdAt !== null) {
      await rawQuery(
        `INSERT INTO public.thread_priority_negative
           (user_id, thread_id, priority_id, source, created_at)
         VALUES ($1, $2, $3, $4, $5)`,
        [corpus.world.user.id, n.threadId, n.priorityId, n.source, n.createdAt]
      );
    } else {
      await rawQuery(
        `INSERT INTO public.thread_priority_negative
           (user_id, thread_id, priority_id, source)
         VALUES ($1, $2, $3, $4)`,
        [corpus.world.user.id, n.threadId, n.priorityId, n.source]
      );
    }
  }

  await rawQuery(`SET LOCAL session_replication_role = origin`);
}

/**
 * Inserts the case's candidate thread so the classifier can read it by id.
 * Runs with triggers ACTIVE (session_replication_role = origin) so the case
 * path exercises the production trigger chain. The caller wraps the call in
 * a savepoint, so the row disappears after the case.
 */
export async function stageCandidate(
  sandbox: SandboxHandle,
  corpus: Corpus,
  caseCandidate: {
    threadId: string;
    title: string;
    topic: string | null;
    contacts: string[];
    groups: string[];
    embedding: number[] | null;
    authorContactId: string | null;
    connectionId: string | null;
    createdByOverride: string | null;
    facets: Record<string, string> | null;
  }
): Promise<void> {
  const { world } = corpus;
  const twists = connectionTwists(world);
  const embLiteral = caseCandidate.embedding
    ? toHalfvecLiteral(caseCandidate.embedding)
    : null;
  // Same created_by precedence as training threads. No explicit created_at:
  // triggers run here (production path), so the value wouldn't stick anyway.
  await sandbox.rawQuery(
    `INSERT INTO public.thread
       (id, created_by, author_id, twist_id, title, topic, contacts, groups,
        embedding, facets)
     VALUES ($1, $2, $3, $4, $5, $6, $7::uuid[], $8::uuid[], $9::halfvec,
             $10::jsonb)`,
    [
      caseCandidate.threadId,
      caseCandidate.createdByOverride ??
        caseCandidate.connectionId ??
        world.user.id,
      caseCandidate.authorContactId,
      caseCandidate.connectionId === null
        ? null
        : (twists.twistIdByConnection.get(caseCandidate.connectionId) ?? null),
      caseCandidate.title,
      caseCandidate.topic,
      caseCandidate.contacts,
      caseCandidate.groups,
      embLiteral,
      caseCandidate.facets === null ? null : JSON.stringify(caseCandidate.facets),
    ]
  );
}

function toHalfvecLiteral(vec: number[]): string {
  // Postgres halfvec literal: "[0.1, -0.2, ...]"
  return `[${vec.join(",")}]`;
}
