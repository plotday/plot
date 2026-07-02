import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { rpcUser } from "../../rpc";
import { Integrations } from "./integrations";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type DispatchResult = Array<{ sourceMethod?: string; args?: unknown[] }>;

type IntegrationsDispatch = {
  dispatch: (item: unknown) => Promise<DispatchResult>;
};

/**
 * Build a minimally-wired Integrations tool against a real Kysely<DB>. The
 * `thread_read` dispatch path requires `sourceProvider` (the connector-only
 * gate) and only reads from `this.db`, so no DO stubs are needed.
 */
function makeTool(db: Kysely<DB>, twistInstanceId: string): IntegrationsDispatch {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const tool = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
    sourceProvider: { provider: "test" },
  });

  return tool as unknown as IntegrationsDispatch;
}

type IntegrationsSetThreadToDo = {
  setThreadToDo: (
    source: string,
    actorId: string,
    todo: boolean,
    options?: { date?: Date | string },
  ) => Promise<void>;
};

/**
 * Same wiring as {@link makeTool}, but exposes the public `setThreadToDo`
 * entrypoint (used by the write-back provenance tests below, which drive the
 * REAL production call path rather than re-asserting the Task 3 SQL-layer
 * contract directly). `getPlot().notifySyncDOs` is stubbed the same way
 * `integrations-todo.test.ts` does it, since `applyThreadToDoForUser` calls it
 * and a real Durable Object namespace isn't available under vitest.
 */
function makeSetThreadToDoTool(
  db: Kysely<DB>,
  twistInstanceId: string,
): IntegrationsSetThreadToDo {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const tool = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
    sourceProvider: { provider: "test" },
  });

  (tool as unknown as { getPlot: () => unknown }).getPlot = () => ({
    notifySyncDOs: async () => {},
  });

  return tool as unknown as IntegrationsSetThreadToDo;
}

type IntegrationsMarkSendFailed = {
  markSendFailed: (
    noteId: string,
    error: { code: string; message?: string | null },
  ) => Promise<void>;
};

/**
 * Same wiring as {@link makeTool}, but exposes the public `markSendFailed`
 * entrypoint (task-4 regression: this call site was missed when the other
 * three connector-attributed thread_state writes were given `p_write_source`).
 */
function makeMarkSendFailedTool(
  db: Kysely<DB>,
  twistInstanceId: string,
): IntegrationsMarkSendFailed {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const tool = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
    sourceProvider: { provider: "test" },
  });

  return tool as unknown as IntegrationsMarkSendFailed;
}

type IntegrationsTaskDone = {
  createTaskScheduleForLink: (threadId: string) => Promise<void>;
};

/**
 * Same wiring as {@link makeTool}, but exposes the private
 * `createTaskScheduleForLink` entrypoint (final-review regression: the
 * done-path direct-UPDATE was the last connector-attributed thread_state
 * write missed by the write-provenance sweep). Declares a `task` linkType
 * with a `done: true` status so `isStatusDone` recognizes the seeded link's
 * status as completion.
 */
function makeTaskDoneTool(
  db: Kysely<DB>,
  twistInstanceId: string,
): IntegrationsTaskDone {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const tool = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
    sourceProvider: {
      provider: "test",
      linkTypes: [
        {
          type: "task",
          label: "Task",
          statuses: [
            { status: "done", label: "Done", icon: "done", done: true },
          ],
        },
      ],
    },
  });

  return tool as unknown as IntegrationsTaskDone;
}

type SeedResult = {
  threadId: string;
  connectorId: string;
  ownerId: string;
  ownerContactId: string;
  gmailThreadId: string;
  channelId: string;
  /** Unique `link.source` for this seed — needed by setThreadToDo(source, ...). */
  source: string;
};

/**
 * Seed a connector-owned thread: an owner user with a linked primary contact, a
 * `twist_instance` owned by that user, a thread whose `created_by` is the
 * connector instance, and a link created by that same connector (so the dispatch
 * handler recognizes the thread as owned by it). The link's meta carries the
 * external `threadId` the connector needs for write-back. A `thread_priority`
 * filing (settled, unrevoked) and a starting `thread_state` row (inactive,
 * unread) are also seeded so `clear_thread_state`/`upsert_thread_state` write
 * synchronously instead of deferring to `pending_thread_state`, and so the
 * todo=false direct-UPDATE path has a row to flip. Triggers/FKs are disabled
 * during seeding; everything is rolled back afterward.
 */
async function withSeed(
  body: (trx: Kysely<DB>, seed: SeedResult) => Promise<void>,
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const ownerId = randomUUID();
  const connectorId = randomUUID();
  const ownerContactId = randomUUID();
  const threadId = randomUUID();
  const linkId = randomUUID();
  const priorityId = randomUUID();
  const gmailThreadId = `gmail-thread-${randomUUID()}`;
  const channelId = `google:${randomUUID()}`;
  const source = `google:gmail:${randomUUID()}`;
  const email = `tr-${ownerId}@example.test`;

  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${ownerId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", name, email)
        VALUES (${ownerContactId}::uuid, ${ownerId}::uuid, true, 'Owner', ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${ownerId}::uuid, ${ownerContactId}::uuid, true, true)`.execute(trx);

      // The connector instance, owned by the user above.
      await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (${connectorId}::uuid, 1, ${ownerId}::uuid, 'Test connector')`.execute(trx);

      // Thread + link both created by the connector twist_instance. The link's
      // meta holds the external Gmail thread id; channel_id holds the channel.
      await sql`INSERT INTO thread (id, created_by, title, contacts)
        VALUES (${threadId}::uuid, ${connectorId}::uuid, 'Email thread',
                ARRAY[${ownerContactId}::uuid]::uuid[])`.execute(trx);
      await sql`INSERT INTO link (id, thread_id, created_by, type, source, channel_id, meta)
        VALUES (${linkId}::uuid, ${threadId}::uuid, ${connectorId}::uuid, 'email',
                ${source}, ${channelId},
                ${sql.lit(JSON.stringify({ threadId: gmailThreadId }))}::jsonb)`.execute(trx);

      // role_id is required (priority_role_or_fyi CHECK). Triggers are off in
      // replica mode, so create a role inline and file the owner's filing under it.
      await sql`WITH r AS (
          INSERT INTO role (created_by, user_id, name)
          VALUES (${ownerId}::uuid, ${ownerId}::uuid, 'Test role') RETURNING id
        )
        INSERT INTO priority (id, created_by, user_id, title, path, role_id)
        SELECT ${priorityId}::uuid, ${ownerId}::uuid, ${ownerId}::uuid, 'Inbox', 'inbox'::ltree, r.id FROM r`.execute(trx);
      // Settled, unrevoked filing so clear_thread_state/upsert_thread_state
      // write directly to thread_state instead of deferring to pending_thread_state.
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (${threadId}::uuid, ${ownerId}::uuid, ${priorityId}::uuid)`.execute(trx);
      // Start inactive & unread so both the todo=true (upsert) and todo=false
      // (direct UPDATE ... WHERE read_at IS NULL) paths have a row to act on.
      await sql`INSERT INTO thread_state (user_id, thread_id, active, read_at, importance)
        VALUES (${ownerId}::uuid, ${threadId}::uuid, false, null, 50)`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      await body(trx, {
        threadId,
        connectorId,
        ownerId,
        ownerContactId,
        gmailThreadId,
        channelId,
        source,
      });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("Integrations.dispatch thread_read", () => {
  it("dispatches onThreadRead(unread=false) for the owner's read on a connector-owned thread", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId, ownerContactId, gmailThreadId, channelId }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: new Date().toISOString() },
      });

      expect(result).toHaveLength(1);
      expect(result[0].sourceMethod).toBe("onThreadRead");

      const [thread, actor, unread] = result[0].args as [
        { id: string; meta: { threadId?: string; channelId?: string | null } },
        { id: string },
        boolean,
      ];

      expect(thread.id).toBe(threadId);
      // The connector needs the external thread id + channel for write-back.
      expect(thread.meta.threadId).toBe(gmailThreadId);
      expect(thread.meta.channelId).toBe(channelId);
      // read_at set => the thread is now read, so unread=false.
      expect(unread).toBe(false);
      // Actor resolves to the owner's primary linked contact.
      expect(actor.id).toBe(ownerContactId);
    });
  });

  it("dispatches onThreadRead(unread=true) when read_at is cleared", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId }) => {
      const tool = makeTool(trx, connectorId);

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: null },
      });

      expect(result).toHaveLength(1);
      expect(result[0].sourceMethod).toBe("onThreadRead");
      const [, , unread] = result[0].args as [unknown, unknown, boolean];
      expect(unread).toBe(true);
    });
  });

  it("does not dispatch for a thread owned by a different twist", async () => {
    await withSeed(async (trx, { threadId, ownerId }) => {
      // A different connector instance — it owns no link on this thread.
      const tool = makeTool(trx, randomUUID());

      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: ownerId, read_at: new Date().toISOString() },
      });

      expect(result).toEqual([]);
    });
  });

  it("does not write back another user's read to the connection owner's account", async () => {
    await withSeed(async (trx, { threadId, connectorId }) => {
      const tool = makeTool(trx, connectorId);

      // A non-owner user read the shared thread — must NOT mark the owner's
      // external account read.
      const result = await tool.dispatch({
        itemType: "thread_read",
        item: { thread_id: threadId, user_id: randomUUID(), read_at: new Date().toISOString() },
      });

      expect(result).toEqual([]);
    });
  });
});

describe.skipIf(!DATABASE_URL)("connector write-back provenance", () => {
  // Step 1 of the task-4 brief: re-assert the Task 3 SQL-layer contract
  // directly against clear_thread_state's p_write_source param. This proves
  // the contract the production call-site edits below must uphold, but does
  // NOT by itself prove the production code passes p_write_source — that's
  // what the "production path" tests further down assert.
  it("connector-marked read does not re-emit to the connector (SQL-layer contract)", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId }) => {
      await rpcUser(trx, "clear_thread_state", {
        user_id: ownerId,
        p_thread_id: threadId,
        p_write_source: connectorId,
      });
      const rows = await sql`SELECT 1 FROM public.twist_instance_thread_read
        WHERE twist_instance_id=${connectorId} AND thread_id=${threadId}`.execute(trx);
      expect(rows.rows.length).toBe(0);
    });
  });

  // Production-path tests: drive the real `setThreadToDo` → `applyThreadToDoForUser`
  // code path (rather than calling the RPCs directly) so these fail if the
  // call-site edits in thread.ts/integrations.ts are missing or wrong.
  it("setThreadToDo(todo=true) stamps thread_state.todo_source via the real production path", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId, ownerContactId, source }) => {
      const tool = makeSetThreadToDoTool(trx, connectorId);

      await tool.setThreadToDo(source, ownerContactId, true);

      const row = await sql<{ active: boolean; todo_source: string | null }>`
        SELECT active, todo_source::text FROM public.thread_state
        WHERE thread_id=${threadId} AND user_id=${ownerId}`.execute(trx);
      expect(row.rows[0]?.active).toBe(true);
      expect(row.rows[0]?.todo_source).toBe(connectorId);
    });
  });

  it("setThreadToDo(todo=false) stamps thread_state.read_source via the direct-UPDATE transaction wrapper (this.db already a transaction)", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId, ownerContactId, source }) => {
      // `trx` here is itself a Kysely Transaction — this exercises the guard
      // in applyThreadToDoForUser that avoids nesting `this.db.transaction()`
      // when `this.db` is already a transaction (Kysely throws "calling the
      // transaction method for a Transaction is not supported" otherwise).
      const tool = makeSetThreadToDoTool(trx, connectorId);

      await tool.setThreadToDo(source, ownerContactId, false);

      const row = await sql<{ read_at: Date | null; read_source: string | null }>`
        SELECT read_at, read_source::text FROM public.thread_state
        WHERE thread_id=${threadId} AND user_id=${ownerId}`.execute(trx);
      expect(row.rows[0]?.read_at).not.toBeNull();
      expect(row.rows[0]?.read_source).toBe(connectorId);
    });
  });

  // Mirrors production wiring exactly: `this.db` is a fresh, non-transactional
  // connection (every real call site builds Integrations from `createDb`/
  // `createFrontendDb`, never a `trx` handle — see the twistFactory call sites
  // audited for this task). Seed data is committed (not rolled back) since a
  // second, independent connection needs to see it; cleanup deletes it after.
  it("setThreadToDo(todo=false) stamps thread_state.read_source via a fresh (non-transactional) connection", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const ownerId = randomUUID();
    const connectorId = randomUUID();
    const ownerContactId = randomUUID();
    const threadId = randomUUID();
    const linkId = randomUUID();
    const priorityId = randomUUID();
    const source = `google:gmail:${randomUUID()}`;
    const email = `trp-${ownerId}@example.test`;

    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email) VALUES (${ownerId}::uuid, ${email})`.execute(trx);
        await sql`INSERT INTO contact (id, user_id, "primary", name, email)
          VALUES (${ownerContactId}::uuid, ${ownerId}::uuid, true, 'Owner', ${email})`.execute(trx);
        await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
          VALUES (${ownerId}::uuid, ${ownerContactId}::uuid, true, true)`.execute(trx);
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name)
          VALUES (${connectorId}::uuid, 1, ${ownerId}::uuid, 'Test connector')`.execute(trx);
        await sql`INSERT INTO thread (id, created_by, title, contacts)
          VALUES (${threadId}::uuid, ${connectorId}::uuid, 'Email thread',
                  ARRAY[${ownerContactId}::uuid]::uuid[])`.execute(trx);
        await sql`INSERT INTO link (id, thread_id, created_by, type, source)
          VALUES (${linkId}::uuid, ${threadId}::uuid, ${connectorId}::uuid, 'email', ${source})`.execute(trx);
        await sql`WITH r AS (
            INSERT INTO role (created_by, user_id, name)
            VALUES (${ownerId}::uuid, ${ownerId}::uuid, 'Test role') RETURNING id
          )
          INSERT INTO priority (id, created_by, user_id, title, path, role_id)
          SELECT ${priorityId}::uuid, ${ownerId}::uuid, ${ownerId}::uuid, 'Inbox', 'inbox'::ltree, r.id FROM r`.execute(trx);
        await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
          VALUES (${threadId}::uuid, ${ownerId}::uuid, ${priorityId}::uuid)`.execute(trx);
        await sql`INSERT INTO thread_state (user_id, thread_id, active, read_at, importance)
          VALUES (${ownerId}::uuid, ${threadId}::uuid, false, null, 50)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
      });

      // `db` (not a transaction) mirrors the real `this.db` shape at every
      // production call site.
      const tool = makeSetThreadToDoTool(db, connectorId);
      await tool.setThreadToDo(source, ownerContactId, false);

      const row = await sql<{ read_at: Date | null; read_source: string | null }>`
        SELECT read_at, read_source::text FROM public.thread_state
        WHERE thread_id=${threadId} AND user_id=${ownerId}`.execute(db);
      expect(row.rows[0]?.read_at).not.toBeNull();
      expect(row.rows[0]?.read_source).toBe(connectorId);
    } finally {
      // thread_state/thread_priority/link cascade from thread; priority/role/
      // twist_instance/contact/user_contact cascade from user.
      await sql`DELETE FROM public.thread WHERE id = ${threadId}`.execute(db);
      await sql`DELETE FROM public."user" WHERE id = ${ownerId}`.execute(db);
      await db.destroy();
    }
  });

  // Task-4 regression: markSendFailed's unread write is the fourth
  // connector-attributed thread_state write, missed in the original sweep.
  // Without `p_write_source` this leaves read_source NULL, so the dispatch
  // view treats the Plot-side send-failure unread as an external change and
  // echoes onThreadRead(unread=true) back to the very connector whose send
  // just failed. Drives the real production path (not the RPC directly).
  it("markSendFailed stamps thread_state.read_source via the real production path", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId }) => {
      const noteId = randomUUID();
      await sql`INSERT INTO note (id, thread_id, author_id, created_by, draft, content)
        VALUES (${noteId}::uuid, ${threadId}::uuid, ${ownerId}::uuid, ${ownerId}::uuid, false, 'hello')`.execute(trx);
      // withSeed's baseline thread_state row already has read_at=NULL, which
      // would make the mark-unread write a no-op for the read_at column (NULL
      // -> NULL) and the per-dimension trigger only stamps read_source when
      // read_at actually changes. Mark it read (in the past, so the
      // p_note_created_at race guard in upsert_thread_state doesn't preserve
      // it) so the subsequent unread write is a real transition to observe.
      await sql`UPDATE thread_state SET read_at = now() - interval '1 hour'
        WHERE user_id=${ownerId}::uuid AND thread_id=${threadId}::uuid`.execute(trx);

      const tool = makeMarkSendFailedTool(trx, connectorId);
      await tool.markSendFailed(noteId, { code: "send_failed", message: "test failure" });

      const row = await sql<{ read_at: Date | null; read_source: string | null }>`
        SELECT read_at, read_source::text FROM public.thread_state
        WHERE thread_id=${threadId} AND user_id=${ownerId}`.execute(trx);
      expect(row.rows[0]?.read_at).toBeNull(); // marked unread
      expect(row.rows[0]?.read_source).toBe(connectorId); // attributed to the connector, not NULL
    });
  });

  // Final-review regression: createTaskScheduleForLink's done-path unread
  // write is the fifth connector-attributed thread_state write, missed in
  // the original sweep. Without provenance this leaves read_source NULL, so
  // the dispatch view treats the task-done read as Plot-origin and echoes
  // onThreadRead(unread=false) back to the connector that just completed the
  // task (e.g. Linear/Trello when assignee == owner). Drives the real
  // `createTaskScheduleForLink` production path (not the helper directly).
  it("createTaskScheduleForLink stamps thread_state.read_source when a link flips to done", async () => {
    await withSeed(async (trx, { threadId, connectorId, ownerId, ownerContactId }) => {
      // The seeded link is assigned to the owner and its status flips to a
      // type/status the tool's linkTypes config marks `done: true`.
      await sql`UPDATE link SET assignee_id = ${ownerContactId}::uuid, type = 'task', status = 'done'
        WHERE thread_id = ${threadId}::uuid`.execute(trx);

      const tool = makeTaskDoneTool(trx, connectorId);
      await tool.createTaskScheduleForLink(threadId);

      const row = await sql<{ read_at: Date | null; read_source: string | null }>`
        SELECT read_at, read_source::text FROM public.thread_state
        WHERE thread_id=${threadId} AND user_id=${ownerId}`.execute(trx);
      expect(row.rows[0]?.read_at).not.toBeNull();
      expect(row.rows[0]?.read_source).toBe(connectorId); // attributed to the connector, not NULL
    });
  });
});
