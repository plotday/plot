import { Kysely, PostgresDialect } from "kysely";
import pg from "pg";

import type { Corpus, CorpusTrainingSet } from "../corpus/schema";
import { resolveDatabaseUrl } from "./resolve-db-url";

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

  // 2. Priorities. Path ordering matters (parents before children).
  const sortedPriorities = [...world.priorities].sort(
    (a, b) => a.path.split(".").length - b.path.split(".").length
  );
  for (const p of sortedPriorities) {
    await rawQuery(
      `INSERT INTO public.priority (id, user_id, created_by, path, title, key)
       VALUES ($1, $2, $2, $3::ltree, $4, $5)`,
      [p.id, world.user.id, p.path, p.title, p.key]
    );
  }

  // 3. Contacts. user_contact rows mark which contacts are "linked" to the
  //    user, which expand_contacts() uses for alias-aware Jaccard.
  for (const c of world.contacts) {
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

  // 4. Groups. Plot's group table is reserved-keyword-named ("group").
  for (const g of world.groups) {
    await rawQuery(
      `INSERT INTO public."group" (id, name, created_by) VALUES ($1, $2, $3)`,
      [g.id, g.title, world.user.id]
    );
  }

  // 5. Channels (only those referenced by topic). Channels in production
  //    require a backing twist_instance; the sandbox doesn't model that, so
  //    callers who need channel_default coverage should supply a corpus that
  //    also stages a synthetic twist_instance, or skip channel cases.
  for (const ch of world.channels) {
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
  const { rawQuery } = sandbox;
  const { world } = corpus;

  await rawQuery(`SET LOCAL session_replication_role = replica`);

  for (const t of trainingSet.threads) {
    const emb = t.embedding_ref ? corpus.embeddings.get(t.embedding_ref) : null;
    const embLiteral = emb ? toHalfvecLiteral(emb.vector) : null;
    await rawQuery(
      `INSERT INTO public.thread
         (id, created_by, title, topic, contacts, groups, embedding)
       VALUES ($1, $2, $3, $4, $5::uuid[], $6::uuid[], $7::halfvec)`,
      [
        t.id,
        world.user.id,
        t.title,
        t.topic,
        t.contacts,
        t.groups,
        embLiteral,
      ]
    );
    await rawQuery(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved)
       VALUES ($1, $2, $3, TRUE)
       ON CONFLICT (thread_id, user_id) DO UPDATE SET
         priority_id = EXCLUDED.priority_id,
         user_moved = TRUE`,
      [t.id, world.user.id, t.filed_to_priority]
    );
  }

  await rawQuery(`SET LOCAL session_replication_role = origin`);
}

/**
 * Inserts the case's candidate thread (plus a default thread_priority filing
 * pointing at the user's root) so the classifier can read the row via
 * `p_thread_id`. Returns the thread_id; caller is in a savepoint so the row
 * disappears after the case.
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
  }
): Promise<void> {
  const embLiteral = caseCandidate.embedding
    ? toHalfvecLiteral(caseCandidate.embedding)
    : null;
  await sandbox.rawQuery(
    `INSERT INTO public.thread
       (id, created_by, title, topic, contacts, groups, embedding)
     VALUES ($1, $2, $3, $4, $5::uuid[], $6::uuid[], $7::halfvec)`,
    [
      caseCandidate.threadId,
      corpus.world.user.id,
      caseCandidate.title,
      caseCandidate.topic,
      caseCandidate.contacts,
      caseCandidate.groups,
      embLiteral,
    ]
  );
}

function toHalfvecLiteral(vec: number[]): string {
  // Postgres halfvec literal: "[0.1, -0.2, ...]"
  return `[${vec.join(",")}]`;
}
