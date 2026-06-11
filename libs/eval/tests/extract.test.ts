import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import pg from "pg";
import { parse as parseYaml } from "yaml";

import { deterministicUuid } from "../src/corpus/hash";
import { loadCorpus } from "../src/corpus/load";
import { loadWorld, openSandbox } from "../src/sandbox/pg-sandbox";
import { anonymizePerson } from "../src/seeder/anonymize";
import {
  hydrateThreadsByIds,
  loadConnections,
  loadContactsByIds,
  loadGroupsByIds,
  loadNegatives,
  loadTrainingThreads,
  loadWorldEntities,
  listActiveUsers,
  resolveThreadIdPrefix,
  type ExtractedThread,
  type ExtractedWorld,
} from "../src/seeder/extract";
import {
  applySlugMigrationToYamlText,
  buildCorpusFiles,
  holdoutCaseEntries,
  mergeExistingCases,
  sampledCaseEntries,
  splitHoldout,
  type CaseResolution,
  type CorpusBuildInput,
} from "../src/seeder/emit";
import { resolveExistingCases } from "../src/seeder/from-prod";
import { contactSlugFromEmail } from "../src/seeder/slugs";

// ===========================================================================
// Fixture ids (distinct namespace; numeric ids in a range no other test uses)
// ===========================================================================

const W_USER = "f1000000-0000-4000-8000-000000000001";
const F_USER = "f1000000-0000-4000-8000-000000000002";
const P1 = "f1000000-0000-4000-8000-000000000010";
const P2 = "f1000000-0000-4000-8000-000000000011";
const C_ANNA = "f1000000-0000-4000-8000-000000000020"; // linked alias
const C_BOB = "f1000000-0000-4000-8000-000000000021"; // counterparty
const C_CARL = "f1000000-0000-4000-8000-000000000022"; // foreign connection actor
const TI1 = "f1000000-0000-4000-8000-000000000030"; // owned by W
const TI2 = "f1000000-0000-4000-8000-000000000031"; // owned by F (owner remap)
const TI3 = "f1000000-0000-4000-8000-000000000032"; // team-owned, NO tic row
const TI4 = "f1000000-0000-4000-8000-000000000033"; // personal, NO tic row
const T1 = "aaaa0001-0000-4000-8000-000000000100"; // connector-created
const T2 = "aaaa0002-0000-4000-8000-000000000101"; // note-author fallback
const T2B = "aaaa0002-0000-4000-8000-000000000102"; // shares T2's 8-hex prefix
const T3 = "aaaa0003-0000-4000-8000-000000000103"; // no author at all
const TNEG = "aaaa0004-0000-4000-8000-000000000104"; // negative evidence
const N1 = "f1000000-0000-4000-8000-000000000201";
const N2 = "f1000000-0000-4000-8000-000000000202";
const TWIST1 = 2_100_000_001;
const TWIST2 = 2_100_000_002;
const TEAM_ID = 2_100_000_777;
const CHANNEL_ID = 991_000_164;

function vec(first: number): string {
  return `[${[first, ...new Array(383).fill(0)].join(",")}]`;
}

// ===========================================================================
// DB-gated extraction tests
// ===========================================================================

describe.runIf(!!process.env.DATABASE_URL)("extract (db)", () => {
  let client: pg.Client;

  beforeAll(async () => {
    client = new pg.Client({ connectionString: process.env.DATABASE_URL });
    await client.connect();
  });

  afterAll(async () => {
    await client.end();
  });

  beforeEach(async () => {
    await client.query("BEGIN");
    // Same trick the sandbox uses: replica role disables triggers/FKs (but
    // not NOT NULL / CHECK), so explicit timestamps stick and the invited-
    // user activation trigger does not fire.
    await client.query("SET LOCAL session_replication_role = replica");

    await client.query(
      `INSERT INTO public."user" (id, email) VALUES
         ($1, 'extract-fixture-w@plotday-extract-fixture.com'),
         ($2, 'extract-fixture-f@plotday-extract-fixture.com')`,
      [W_USER, F_USER]
    );
    await client.query(
      `INSERT INTO public.user_subscription
         (user_id, plan, status, billing_cycle_start, billing_cycle_end)
       VALUES ($1, 'pro', 'active', '2026-01-01', '2027-01-01')`,
      [W_USER]
    );
    await client.query(
      `INSERT INTO public.priority
         (id, user_id, created_by, path, title, key, description, facet_filters)
       VALUES
         ($1, $3, $3, 'extractroot', 'Inbox', NULL, 'Email triage and follow-ups',
          '{"automation":{"exclude":["automated"]}}'::jsonb),
         ($2, $3, $3, 'extractroot.eng', 'Engineering', NULL, NULL, NULL)`,
      [P1, P2, W_USER]
    );
    await client.query(
      `INSERT INTO public.contact (id, email, name, user_id) VALUES
         ($1, 'annabellatrix@extract-fixture-org.example', 'Annabellatrix Vendorson', $4),
         ($2, 'bobfixture@gmail-extract-fixture.example', 'Bobfixture Counterpartison', NULL),
         ($3, 'carlfixture@extract-fixture-org2.example', 'Carlfixture Actorson', NULL)`,
      [C_ANNA, C_BOB, C_CARL, W_USER]
    );
    await client.query(
      `INSERT INTO public.user_contact (user_id, contact_id, linked)
       VALUES ($1, $2, TRUE)`,
      [W_USER, C_ANNA]
    );
    await client.query(
      `INSERT INTO public.team (id, name) OVERRIDING SYSTEM VALUE
       VALUES ($1, 'Raw Fixture Team Name')`,
      [TEAM_ID]
    );
    await client.query(
      `INSERT INTO public.twist
         (id, twist_package_id, user_id, environment, name, handle, version)
       OVERRIDING SYSTEM VALUE
       VALUES ($1, 'f1000000-0000-4000-8000-00000000aaaa', $3, 'personal', 'google', 'google', '0.0.0-fixture'),
              ($2, 'f1000000-0000-4000-8000-00000000aaab', $3, 'personal', 'slack', 'slack', '0.0.0-fixture')`,
      [TWIST1, TWIST2, W_USER]
    );
    await client.query(
      `INSERT INTO public.twist_instance (id, twist_id, owner_id, team_id, name) VALUES
         ($1, $3, $5, NULL, 'fixture google instance'),
         ($2, $4, $6, $7, 'fixture slack instance (foreign owner)')`,
      [TI1, TI2, TWIST1, TWIST2, W_USER, F_USER, TEAM_ID]
    );
    await client.query(
      `INSERT INTO public.twist_instance_connection
         (twist_instance_id, user_id, provider, actor_id) VALUES
         ($1, $3, 'google', $5),
         ($2, $4, 'slack', $6)`,
      [TI1, TI2, W_USER, F_USER, C_ANNA, C_CARL]
    );
    await client.query(
      `INSERT INTO public.channel
         (id, twist_instance_id, channel_id, title, default_priority_id)
       OVERRIDING SYSTEM VALUE
       VALUES ($1, $2, 'fixture-channel', 'Fixture Channel', $3)`,
      [CHANNEL_ID, TI2, P1]
    );

    // T1: connector-created — author_id set, twist_id + created_by=connection,
    // facets, own (thread-title) embedding, explicit created_at.
    await client.query(
      `INSERT INTO public.thread
         (id, created_by, author_id, twist_id, title, topic, contacts, groups,
          embedding, facets, created_at)
       VALUES ($1, $2, $3, $4, 'Fixture invoice thread', $5,
               ARRAY[$3, $6]::uuid[], '{}'::uuid[], $7::halfvec,
               '{"format":"message"}'::jsonb, '2026-03-01T10:00:00Z')`,
      [T1, TI1, C_ANNA, TWIST1, `channel:${CHANNEL_ID}`, C_BOB, vec(0.25)]
    );
    await client.query(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved, updated_at)
       VALUES ($1, $2, $3, TRUE, '2026-03-05T09:00:00Z')`,
      [T1, W_USER, P1]
    );

    // T2: no thread author/embedding — note fallbacks. Earliest note (N1) has
    // the author but no embedding; the later note (N2) has the embedding.
    await client.query(
      `INSERT INTO public.thread
         (id, created_by, title, contacts, groups, created_at)
       VALUES ($1, $2, 'Fixture note-author thread', ARRAY[$3]::uuid[],
               '{}'::uuid[], '2026-03-02T10:00:00Z')`,
      [T2, W_USER, C_BOB]
    );
    await client.query(
      `INSERT INTO public.note (id, author_id, created_by, thread_id, content, created_at)
       VALUES ($1, $3, $5, $6, 'first note', '2026-03-02T10:01:00Z'),
              ($2, $4, $5, $6, 'second note', '2026-03-02T10:02:00Z')`,
      [N1, N2, C_BOB, C_ANNA, W_USER, T2]
    );
    await client.query(
      `UPDATE public.note SET embedding = $1::halfvec WHERE id = $2`,
      [vec(0.5), N2]
    );
    await client.query(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved, updated_at)
       VALUES ($1, $2, $3, FALSE, '2026-03-04T09:00:00Z')`,
      [T2, W_USER, P2]
    );

    // T2B shares T2's 8-hex prefix (prefix-resolution ambiguity).
    await client.query(
      `INSERT INTO public.thread (id, created_by, title, created_at)
       VALUES ($1, $2, 'Fixture prefix twin', '2026-03-02T11:00:00Z')`,
      [T2B, W_USER]
    );
    await client.query(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved, updated_at)
       VALUES ($1, $2, $3, FALSE, '2026-03-04T10:00:00Z')`,
      [T2B, W_USER, P2]
    );

    // T3: no author anywhere, user-moved.
    await client.query(
      `INSERT INTO public.thread (id, created_by, title, created_at)
       VALUES ($1, $2, 'Fixture authorless thread', '2026-03-03T10:00:00Z')`,
      [T3, W_USER]
    );
    await client.query(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved, updated_at)
       VALUES ($1, $2, $3, TRUE, '2026-03-06T09:00:00Z')`,
      [T3, W_USER, P2]
    );

    // TNEG: negative evidence with a real timestamp.
    await client.query(
      `INSERT INTO public.thread (id, created_by, title, created_at)
       VALUES ($1, $2, 'Fixture negative thread', '2026-03-04T10:00:00Z')`,
      [TNEG, W_USER]
    );
    await client.query(
      `INSERT INTO public.thread_priority_negative
         (user_id, thread_id, priority_id, source, created_at)
       VALUES ($1, $2, $3, 'moved_out', '2026-03-07T00:00:00Z')`,
      [W_USER, TNEG, P2]
    );
  });

  afterEach(async () => {
    await client.query("ROLLBACK");
  });

  it("hydrateThreadsByIds: author chain, connection gating, embedding source, facets", async () => {
    const missing = "aaaa9999-0000-4000-8000-000000000999";
    const threads = await hydrateThreadsByIds(client, W_USER, [T1, T2, T3, missing]);
    expect(threads.map((t) => t.id)).toEqual([T1, T2, T3]);

    const t1 = threads[0]!;
    expect(t1.authorContactId).toBe(C_ANNA); // thread.author_id wins
    expect(t1.connectionId).toBe(TI1); // created_by only because twist_id set
    expect(t1.embeddingSource).toBe("thread-title");
    expect(t1.embedding![0]).toBeCloseTo(0.25);
    expect(t1.facets).toEqual({ format: "message" });
    expect(t1.createdAt).toBe("2026-03-01T10:00:00.000Z");
    expect(t1.filedToPriority).toBe(P1);
    expect(t1.movedAt).toBe("2026-03-05T09:00:00.000Z");
    expect(t1.contacts).toEqual(expect.arrayContaining([C_ANNA, C_BOB]));

    const t2 = threads[1]!;
    expect(t2.authorContactId).toBe(C_BOB); // earliest note's author
    expect(t2.connectionId).toBeNull(); // twist_id IS NULL → no connection
    expect(t2.embeddingSource).toBe("note-content"); // earliest note WITH embedding
    expect(t2.embedding![0]).toBeCloseTo(0.5);
    expect(t2.movedAt).toBeNull(); // user_moved = FALSE

    const t3 = threads[2]!;
    expect(t3.authorContactId).toBeNull();
    expect(t3.embedding).toBeNull();
    expect(t3.embeddingSource).toBeNull();
  });

  it("loadTrainingThreads: only user_moved, movedAt = tp.updated_at, recent first", async () => {
    const threads = await loadTrainingThreads(client, W_USER);
    expect(threads.map((t) => t.id)).toEqual([T3, T1]);
    expect(threads[0]!.movedAt).toBe("2026-03-06T09:00:00.000Z");
    expect(threads[1]!.movedAt).toBe("2026-03-05T09:00:00.000Z");
  });

  it("loadNegatives: real created_at preserved", async () => {
    const negatives = await loadNegatives(client, W_USER);
    expect(negatives).toEqual([
      {
        threadId: TNEG,
        priorityId: P2,
        source: "moved_out",
        createdAt: "2026-03-07T00:00:00.000Z",
      },
    ]);
  });

  it("loadWorldEntities: subscription, priority extras, contacts, channels, owner-remapped connections", async () => {
    const world = await loadWorldEntities(client, W_USER);

    expect(world.userId).toBe(W_USER);
    expect(world.userEmail).toBe("extract-fixture-w@plotday-extract-fixture.com");
    expect(world.subscription).toEqual({ plan: "pro", status: "active" });

    const p1 = world.priorities.find((p) => p.id === P1)!;
    expect(p1.description).toBe("Email triage and follow-ups");
    expect(p1.facetFilters).toEqual({ automation: { exclude: ["automated"] } });
    const p2 = world.priorities.find((p) => p.id === P2)!;
    expect(p2.description).toBeNull();
    expect(p2.facetFilters).toBeNull();

    const anna = world.contacts.find((c) => c.id === C_ANNA)!;
    expect(anna.linkedToUser).toBe(true);
    const bob = world.contacts.find((c) => c.id === C_BOB)!;
    expect(bob.linkedToUser).toBe(false);
    // The foreign connection's actor is NOT a thread counterparty — callers
    // must hydrate it explicitly (loadContactsByIds) before building.
    expect(world.contacts.find((c) => c.id === C_CARL)).toBeUndefined();

    expect(world.channels).toEqual([
      { id: CHANNEL_ID, twistInstanceId: TI2, defaultPriorityId: P1 },
    ]);

    // Owner remap: TI2 is owned by a DIFFERENT user; provider + actor still
    // resolve from the real owner's twist_instance_connection row, and the
    // emitted corpus connection belongs to the world user (the corpus has no
    // owner field — the sandbox always inserts owner = world user).
    expect(world.connections).toEqual([
      { id: TI2, provider: "slack", actorContactId: C_CARL, teamId: TEAM_ID },
    ]);
  });

  it("loadConnections: resolves by instance id; unknown ids land in missing", async () => {
    const unknown = "f1000000-0000-4000-8000-00000000dead";
    const { connections, missing } = await loadConnections(client, [TI1, TI2, unknown]);
    expect(missing).toEqual([unknown]);
    expect(connections).toEqual(
      expect.arrayContaining([
        { id: TI1, provider: "google", actorContactId: C_ANNA, teamId: null },
        { id: TI2, provider: "slack", actorContactId: C_CARL, teamId: TEAM_ID },
      ])
    );
  });

  /**
   * Prod reality (verified live on kris's data): many twist_instances have
   * ZERO twist_instance_connection rows. They must extract as REAL
   * connections (placeholder actor synthesized at emit), not as "missing".
   * TI3 reuses TWIST2 (handle "slack") + the team; TI4 reuses TWIST1
   * (handle "google") with no team.
   */
  async function insertTicLessInstances(): Promise<void> {
    await client.query(
      `INSERT INTO public.twist_instance (id, twist_id, owner_id, team_id, name) VALUES
         ($1, $3, $5, $6, 'fixture tic-less team instance'),
         ($2, $4, $5, NULL, 'fixture tic-less personal instance')`,
      [TI3, TI4, TWIST2, TWIST1, W_USER, TEAM_ID]
    );
  }

  it("loadConnections: tic-less instances extract with null actor + twist-handle provider", async () => {
    await insertTicLessInstances();
    const { connections, missing } = await loadConnections(client, [TI3, TI4]);
    expect(missing).toEqual([]);
    expect(connections).toEqual(
      expect.arrayContaining([
        { id: TI3, provider: "slack", actorContactId: null, teamId: TEAM_ID },
        { id: TI4, provider: "google", actorContactId: null, teamId: null },
      ])
    );
  });

  it("tic-less connections: placeholder actors round-trip and reproduce prod org keys", async () => {
    await insertTicLessInstances();
    const { connections, missing } = await loadConnections(client, [TI3, TI4]);
    expect(missing).toEqual([]);

    // Release the fixture transaction before opening the sandbox: it uses a
    // SEPARATE connection and would block forever on our uncommitted
    // twist_instance/user rows when loadWorld re-inserts the same ids. The
    // immediate BEGIN keeps afterEach's ROLLBACK balanced.
    await client.query("ROLLBACK");
    await client.query("BEGIN");

    const input = baseBuildInput();
    input.world.connections.push(...connections);
    const { files, report } = buildCorpusFiles(input);
    expect(report.some((l) => l.includes("dropped connection"))).toBe(false);

    const dir = await writeBuiltCorpus(files);
    const corpus = await loadCorpus(dir);

    const teamConn = corpus.world.connections.find((c) => c.id === TI3)!;
    const personalConn = corpus.world.connections.find((c) => c.id === TI4)!;
    expect(teamConn.teamId).toBe(TEAM_ID);
    expect(personalConn.teamId).toBeNull();
    // The team entry is emitted even though only a placeholder-actor
    // connection references it.
    expect(corpus.world.teams.some((t) => t.id === TEAM_ID)).toBe(true);
    for (const [conn, connectionId] of [
      [teamConn, TI3],
      [personalConn, TI4],
    ] as const) {
      const placeholder = corpus.world.contacts.find(
        (ct) => ct.id === conn.accountContactId
      )!;
      expect(placeholder).toBeDefined();
      expect(placeholder.id).toBe(deterministicUuid(`conn-actor:${connectionId}`));
      expect(placeholder.email).toBeNull();
      expect(placeholder.name).toBeNull();
      expect(placeholder.linked_to_user).toBe(false);
      expect(placeholder.slug ?? "").toMatch(/^conn-actor-[0-9a-f]{6}$/);
    }

    // Sandbox: the placeholder actor's NULL email makes connection_org_key's
    // actor lateral skip the row, falling through to team:<offset id> / NULL
    // exactly like the tic-less prod instance.
    const sandbox = await openSandbox({ databaseUrl: process.env.DATABASE_URL });
    try {
      await loadWorld(sandbox, corpus);
      const team = await sandbox.rawQuery(
        `SELECT public.connection_org_key($1) AS key`,
        [TI3]
      );
      expect((team.rows[0] as { key: string | null }).key).toBe(
        `team:${1_000_000_000 + TEAM_ID}`
      );
      const personal = await sandbox.rawQuery(
        `SELECT public.connection_org_key($1) AS key`,
        [TI4]
      );
      expect((personal.rows[0] as { key: string | null }).key).toBeNull();
    } finally {
      await sandbox.close();
    }
  });

  it("loadContactsByIds / loadGroupsByIds hydrate referenced entities", async () => {
    const contacts = await loadContactsByIds(client, W_USER, [C_CARL, C_ANNA]);
    expect(contacts).toEqual([
      {
        id: C_ANNA,
        email: "annabellatrix@extract-fixture-org.example",
        name: "Annabellatrix Vendorson",
        linkedToUser: true,
      },
      {
        id: C_CARL,
        email: "carlfixture@extract-fixture-org2.example",
        name: "Carlfixture Actorson",
        linkedToUser: false,
      },
    ]);
    expect(await loadGroupsByIds(client, [])).toEqual([]);
  });

  it("listActiveUsers: counts without emails", async () => {
    const rows = await listActiveUsers(client, 10_000);
    const w = rows.find((r) => r.userId === W_USER)!;
    expect(w.threadPriorityCount).toBe(4);
    expect(w.userMovedCount).toBe(2);
    expect(Object.keys(w).sort()).toEqual([
      "threadPriorityCount",
      "userId",
      "userMovedCount",
    ]);
  });

  it("resolveThreadIdPrefix: unique match, ambiguity, and no match", async () => {
    expect(await resolveThreadIdPrefix(client, W_USER, T1.slice(0, 8))).toEqual([T1]);
    const twins = await resolveThreadIdPrefix(client, W_USER, T2.slice(0, 8));
    expect(twins.sort()).toEqual([T2, T2B].sort());
    expect(await resolveThreadIdPrefix(client, W_USER, "deadbeef")).toEqual([]);
    expect(await resolveThreadIdPrefix(client, W_USER, "nothex!!")).toEqual([]);
  });

  it("resolveExistingCases: multi-match prefixes disambiguate by candidate title", async () => {
    // uuidv7 prefixes collide heavily (one live kris prefix matched 42
    // threads). A third thread sharing T2's prefix, with a title DUPLICATING
    // T2's, exercises the matches-several branch.
    const T2C = "aaaa0002-0000-4000-8000-000000000105";
    await client.query(
      `INSERT INTO public.thread (id, created_by, title, created_at)
       VALUES ($1, $2, 'Fixture note-author thread', '2026-03-02T12:00:00Z')`,
      [T2C, W_USER]
    );
    await client.query(
      `INSERT INTO public.thread_priority
         (thread_id, user_id, priority_id, user_moved, updated_at)
       VALUES ($1, $2, $3, FALSE, '2026-03-04T11:00:00Z')`,
      [T2C, W_USER, P2]
    );

    const prefix = T2.slice(0, 8);
    const cases = [
      // Title equals exactly ONE of the three prefix matches → hydrated.
      { id: `010-${prefix}`, candidate: { title: "Fixture prefix twin" } },
      // Title equals TWO threads (T2 and T2C) → still ambiguous.
      { id: `011-${prefix}`, candidate: { title: "Fixture note-author thread" } },
      // Title equals NO thread → ambiguous.
      { id: `012-${prefix}`, candidate: { title: "No such title anywhere" } },
      // No candidate title → no disambiguation evidence → ambiguous.
      { id: `013-${prefix}`, candidate: {} },
    ] as Record<string, unknown>[];

    const res = await resolveExistingCases(client, W_USER, cases);
    const hit = res.get(`010-${prefix}`)!;
    expect(hit.status).toBe("hydrated");
    if (hit.status === "hydrated") expect(hit.thread.id).toBe(T2B);
    expect(res.get(`011-${prefix}`)).toEqual({ status: "ambiguous", matches: 3 });
    expect(res.get(`012-${prefix}`)).toEqual({ status: "ambiguous", matches: 3 });
    expect(res.get(`013-${prefix}`)).toEqual({ status: "ambiguous", matches: 3 });
  });
});

// ===========================================================================
// Pure emission tests (no DB required)
// ===========================================================================

const RAW_USER_EMAIL = "real-fixture-user@plotday-fixture-org.com";
const RAW_ANNA_EMAIL = "annabellatrix@fixturevendor-co.com";
const RAW_ANNA_NAME = "Annabellatrix Vendorson";
const RAW_BOB_EMAIL = "bobfixture@gmail.com";
const RAW_BOB_NAME = "Bobfixture Counterpartison";

const CONN1 = "f2000000-0000-4000-8000-000000000030";
const G1 = "f2000000-0000-4000-8000-000000000040";
const E_T1 = "f2000000-0000-4000-8000-000000000100";
const E_T2 = "f2000000-0000-4000-8000-000000000101";
const E_T3 = "f2000000-0000-4000-8000-000000000102";
const E_NEG = "f2000000-0000-4000-8000-000000000103";
const E_CASE = "f2000000-0000-4000-8000-000000000104";

function numVec(first: number): number[] {
  return [first, ...new Array(383).fill(0)];
}

function fixtureWorld(): ExtractedWorld {
  return {
    userId: W_USER,
    userEmail: RAW_USER_EMAIL,
    subscription: { plan: "pro", status: "active" },
    priorities: [
      {
        id: P1,
        path: "evalroot",
        title: "Inbox",
        key: null,
        description: "Email triage",
        facetFilters: { automation: { exclude: ["automated"] } },
      },
      {
        id: P2,
        path: "evalroot.eng",
        title: "Engineering",
        key: null,
        description: null,
        facetFilters: null,
      },
    ],
    contacts: [
      { id: C_ANNA, email: RAW_ANNA_EMAIL, name: RAW_ANNA_NAME, linkedToUser: true },
      { id: C_BOB, email: RAW_BOB_EMAIL, name: RAW_BOB_NAME, linkedToUser: false },
    ],
    groups: [{ id: G1, title: "Annabellatrix & friends planning" }],
    connections: [
      { id: CONN1, provider: "google", actorContactId: C_ANNA, teamId: 42 },
    ],
    channels: [{ id: 164, twistInstanceId: CONN1, defaultPriorityId: P1 }],
  };
}

function fixtureThread(overrides: Partial<ExtractedThread> & { id: string }): ExtractedThread {
  return {
    title: "Fixture thread",
    topic: null,
    contacts: [C_ANNA],
    groups: [],
    embedding: null,
    embeddingSource: null,
    authorContactId: C_ANNA,
    connectionId: null,
    facets: null,
    createdAt: "2026-04-01T00:00:00.000Z",
    filedToPriority: P1,
    movedAt: null,
    ...overrides,
  };
}

function baseBuildInput(): CorpusBuildInput {
  const t1 = fixtureThread({
    id: E_T1,
    title: "Invoice from vendor",
    topic: `channel:164`,
    contacts: [C_ANNA, C_BOB],
    groups: [G1],
    embedding: numVec(0.25),
    embeddingSource: "thread-title",
    connectionId: CONN1,
    facets: { format: "message", automation: "automated" },
    createdAt: "2026-04-02T10:00:00.000Z",
    movedAt: "2026-04-03T09:30:00.000Z",
  });
  const t2 = fixtureThread({
    id: E_T2,
    title: "Reply thread with note embedding",
    contacts: [C_BOB],
    authorContactId: C_BOB,
    embedding: numVec(0.5),
    embeddingSource: "note-content",
    createdAt: "2026-04-04T10:00:00.000Z",
    filedToPriority: P2,
    movedAt: "2026-04-05T09:30:00.000Z",
  });
  const neg = fixtureThread({
    id: E_NEG,
    title: "Marketing blast",
    filedToPriority: null,
    createdAt: "2026-04-01T08:00:00.000Z",
  });
  const caseThread = fixtureThread({
    id: E_CASE,
    title: "Agenda times",
    topic: `channel:kris-topic-email@plotday-fixture-org.com`,
    createdAt: "2026-05-01T12:00:00.000Z",
    filedToPriority: P2,
  });
  return {
    corpusName: "fixture-corpus",
    world: fixtureWorld(),
    trainings: [t1, t2],
    negatives: [
      {
        threadId: E_NEG,
        priorityId: P2,
        source: "moved_out",
        createdAt: "2026-04-06T08:00:00.000Z",
      },
    ],
    negativeThreads: [neg],
    cases: sampledCaseEntries([caseThread], 1, "2026-06-11T00:00:00.000Z"),
    allowNoteContentEmbeddings: true,
    regenerateCommand:
      "pnpm exec tsx src/seeder/from-prod.ts --user-id <uuid> --out fixture-corpus",
    now: new Date("2026-06-11T00:00:00.000Z"),
  };
}

async function writeBuiltCorpus(files: { path: string; text: string }[]): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-extract-emit-"));
  for (const f of files) {
    const path = join(dir, f.path);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, f.text);
  }
  return dir;
}

describe("contactSlugFromEmail (v2 email shapes)", () => {
  it("derives slugs from anonymized local parts", () => {
    expect(contactSlugFromEmail("jordan.mercer@lumenforge.com", W_USER)).toBe(
      "jordan-mercer"
    );
    expect(contactSlugFromEmail("c-1a2b3c4d5e6f@gmail.com", W_USER)).toBe(
      "c-1a2b3c4d5e6f"
    );
    // Legacy v1 shape still works.
    expect(contactSlugFromEmail("c-3f5cc8fd9fc9@example.test", W_USER)).toBe(
      "c-3f5cc8fd9fc9"
    );
  });

  it("falls back to an id-derived slug", () => {
    expect(contactSlugFromEmail(null, "abcd1234-0000-4000-8000-000000000000")).toBe(
      "c-abcd1234"
    );
    expect(contactSlugFromEmail("@@", "abcd1234-0000-4000-8000-000000000000")).toBe(
      "c-abcd1234"
    );
  });
});

describe("splitHoldout", () => {
  it("takes the N most recent moves and keeps training order", () => {
    const a = fixtureThread({ id: E_T1, movedAt: "2026-04-03T00:00:00.000Z" });
    const b = fixtureThread({ id: E_T2, movedAt: "2026-04-05T00:00:00.000Z" });
    const c = fixtureThread({ id: E_T3, movedAt: "2026-04-01T00:00:00.000Z" });
    const { training, holdout } = splitHoldout([a, b, c], 1);
    expect(holdout.map((t) => t.id)).toEqual([E_T2]);
    expect(training.map((t) => t.id)).toEqual([E_T1, E_T3]);
  });

  it("returns everything as training when n = 0", () => {
    const a = fixtureThread({ id: E_T1 });
    const { training, holdout } = splitHoldout([a], 0);
    expect(training).toHaveLength(1);
    expect(holdout).toHaveLength(0);
  });
});

describe("applySlugMigrationToYamlText", () => {
  it("rewrites whole tokens only", () => {
    const migration = new Map([
      ["c-dead", "c-new-short"],
      ["c-deadbeef", "anna-fake"],
    ]);
    const { text, replacements } = applySlugMigrationToYamlText(
      "contacts:\n  - c-deadbeef\n  - c-dead\nauthor: c-deadbeef\n",
      migration
    );
    expect(text).toBe(
      "contacts:\n  - anna-fake\n  - c-new-short\nauthor: anna-fake\n"
    );
    expect(replacements).toBe(3);
  });
});

describe("mergeExistingCases", () => {
  const existing = [
    {
      id: "001-aaaa0001",
      description: "Sampled from prod (topic-shape: channel:N).",
      candidate: { title: "old title", contacts: ["c-old"] },
      labels: {
        gold: "inbox",
        gold_rationale: "Contact and topic",
        expected: "eng",
        expected_stage: null,
        expected_recorded_at: "2026-05-18 00:30:34.947000+00:00",
      },
      notes: "hand-written note",
      tags: ["channel:N"],
    },
    {
      id: "002-bbbb0002",
      candidate: { title: "unresolvable" },
      labels: { gold: null },
    },
  ];

  it("preserves labels/tags/notes for hydrated cases; keeps unresolvable cases verbatim", () => {
    const thread = fixtureThread({ id: E_T1 });
    const resolution = new Map<string, CaseResolution>([
      ["001-aaaa0001", { status: "hydrated", thread }],
      ["002-bbbb0002", { status: "ambiguous", matches: 3 }],
    ]);
    const merged = mergeExistingCases(
      existing as Record<string, unknown>[],
      resolution
    );
    expect(merged.maxCaseNumber).toBe(2);
    expect(merged.resolvedThreadIds.has(E_T1)).toBe(true);
    expect(merged.report).toEqual([
      "case 002-bbbb0002: thread-id prefix matched 3 threads — kept verbatim",
    ]);

    const first = merged.entries[0]!;
    expect(first.kind).toBe("thread");
    if (first.kind === "thread") {
      expect(first.id).toBe("001-aaaa0001");
      expect(first.tags).toEqual(["channel:N"]);
      expect(first.notes).toBe("hand-written note");
      expect(first.labels).toEqual({
        kind: "preserved",
        raw: existing[0]!.labels,
      });
    }
    expect(merged.entries[1]!.kind).toBe("verbatim");
  });
});

describe("buildCorpusFiles", () => {
  it("round-trips the full v2 surface through loadCorpus", async () => {
    const input = baseBuildInput();
    const { files, report } = buildCorpusFiles(input);
    expect(files.map((f) => f.path).sort()).toEqual([
      "README.md",
      "cases.yaml",
      "embeddings.yaml",
      "trainings/full.yaml",
      "world.yaml",
    ]);

    const dir = await writeBuiltCorpus(files);
    const corpus = await loadCorpus(dir);

    // World.
    expect(corpus.world.schemaVersion).toBe(2);
    expect(corpus.world.user.subscription).toEqual({ plan: "pro", status: "active" });
    expect(corpus.world.teams).toHaveLength(1);
    expect(corpus.world.teams[0]!.id).toBe(42);
    expect(corpus.world.teams[0]!.name).toMatch(/^Team [0-9a-f]{6}$/);
    expect(corpus.world.connections).toHaveLength(1);
    const conn = corpus.world.connections[0]!;
    expect(conn.id).toBe(CONN1);
    expect(conn.provider).toBe("google");
    expect(conn.accountContactId).toBe(C_ANNA);
    expect(conn.teamId).toBe(42);
    const inbox = corpus.world.priorities.find((p) => p.id === P1)!;
    expect(inbox.description).toBe("Email triage");
    expect(inbox.facetFilters).toEqual({ automation: { exclude: ["automated"] } });
    expect(corpus.world.channels).toEqual([
      { id: 164, connectionId: CONN1, default_priority_id: P1 },
    ]);

    // Trainings.
    const full = corpus.trainingSets.find((t) => t.name === "full")!;
    expect(full.threads).toHaveLength(2);
    const t1 = full.threads.find((t) => t.id === E_T1)!;
    expect(t1.authorContactId).toBe(C_ANNA);
    expect(t1.connectionId).toBe(CONN1);
    expect(t1.facets).toEqual({ format: "message", automation: "automated" });
    expect(t1.createdAt!.toISOString()).toBe("2026-04-02T10:00:00.000Z");
    expect(t1.movedAt!.toISOString()).toBe("2026-04-03T09:30:00.000Z");
    expect(t1.filedToPriority).toBe(P1);
    expect(full.negativeThreads).toHaveLength(1);
    expect(full.negatives).toEqual([
      {
        threadId: E_NEG,
        priorityId: P2,
        source: "moved_out",
        createdAt: new Date("2026-04-06T08:00:00.000Z"),
      },
    ]);

    // Cases.
    expect(corpus.cases).toHaveLength(1);
    const cs = corpus.cases[0]!;
    expect(cs.id).toBe(`001-${E_CASE.slice(0, 8)}`);
    expect(cs.sourceThreadId).toBe(E_CASE);
    expect(cs.asOf!.toISOString()).toBe("2026-05-01T12:00:00.000Z");
    expect(cs.tags).toEqual(["other"]);
    expect(cs.labels.gold).toBeNull();
    expect(cs.labels.goldSource).toBeNull();
    expect(cs.labels.expected).toBe(P2);

    // Embeddings with provenance.
    expect(corpus.embeddings.size).toBe(2);
    const t1Emb = corpus.embeddings.get(t1.embedding_ref!)!;
    expect(t1Emb.source).toBe("thread-title");

    expect(report.some((l) => l.startsWith("emitted:"))).toBe(true);
  });

  it("anonymizes every raw identity (incl. the user email and topic emails)", () => {
    const { files } = buildCorpusFiles(baseBuildInput());
    const allText = files.map((f) => f.text).join("\n");
    expect(allText).not.toContain(RAW_USER_EMAIL);
    expect(allText).not.toContain(RAW_ANNA_EMAIL);
    expect(allText).not.toContain("Annabellatrix");
    expect(allText).not.toContain("Vendorson");
    expect(allText).not.toContain("fixturevendor-co.com");
    expect(allText).not.toContain("plotday-fixture-org.com");
    expect(allText).not.toContain("kris-topic-email");
    // Team names are synthesized, never extracted.
    expect(allText).toMatch(/Team [0-9a-f]{6}/);

    // The case topic kept its channel: prefix with an anonymized email.
    const cases = parseYaml(files.find((f) => f.path === "cases.yaml")!.text) as {
      cases: { candidate: { topic: string } }[];
    };
    expect(cases.cases[0]!.candidate.topic).toMatch(/^channel:.+@.+$/);
  });

  it("throws on raw PII outside title scope (leak check wired at the choke point)", () => {
    const input = baseBuildInput();
    const entry = input.cases[0]!;
    if (entry.kind === "thread") {
      entry.description = `Curated while talking to ${RAW_ANNA_EMAIL}`;
    }
    expect(() => buildCorpusFiles(input)).toThrow(/Leak check failed/);
  });

  it("warns (but still emits) on raw PII inside a verbatim title", () => {
    const input = baseBuildInput();
    input.trainings[0]!.title = `Re: ${RAW_ANNA_NAME} intro`;
    const { files, warnings } = buildCorpusFiles(input);
    expect(files.length).toBeGreaterThan(0);
    expect(
      warnings.some((w) => w.kind === "name" && /annabellatrix/i.test(w.value))
    ).toBe(true);
  });

  it("surfaces group-name residue tokens as warnings", () => {
    const { warnings } = buildCorpusFiles(baseBuildInput());
    const residue = warnings.find((w) => w.context.includes(`group ${G1}`));
    expect(residue).toBeDefined();
    expect(residue!.value).toContain("friends");
  });

  it("drops note-content embeddings unless allowed, and reports the count", () => {
    const input = baseBuildInput();
    input.allowNoteContentEmbeddings = false;
    const { files, report } = buildCorpusFiles(input);
    const embDoc = parseYaml(
      files.find((f) => f.path === "embeddings.yaml")!.text
    ) as { embeddings: { ref: string; source: string | null }[] };
    expect(embDoc.embeddings).toHaveLength(1);
    expect(embDoc.embeddings[0]!.source).toBe("thread-title");
    const trainDoc = parseYaml(
      files.find((f) => f.path === "trainings/full.yaml")!.text
    ) as { threads: { id: string; embedding_ref: string | null }[] };
    expect(trainDoc.threads.find((t) => t.id === E_T2)!.embedding_ref).toBeNull();
    expect(report.some((l) => l.includes("excluded 1 note-content"))).toBe(true);
  });

  it("builds the slug migration map and rewrites verbatim cases (v1 author → created_by_override)", async () => {
    const input = baseBuildInput();
    const expectedAnnaSlug = contactSlugFromEmail(
      anonymizePerson({ name: RAW_ANNA_NAME, email: RAW_ANNA_EMAIL }).email,
      C_ANNA
    );
    input.existingWorldYaml = [
      "name: fixture-corpus",
      "schema_version: 1",
      `user: { id: "${W_USER}", email: "c-old@example.test" }`,
      "priorities:",
      `  - { slug: inbox-zero, id: "${P1}", path: evalroot, title: Old Inbox }`,
      "contacts:",
      `  - { slug: c-deadbeef0001, id: "${C_ANNA}", email: "c-deadbeef0001@example.test" }`,
      "embeddings:",
      `  - { ref: emb-old1, vector: [${numVec(0.75).join(", ")}] }`,
      "",
    ].join("\n");
    input.cases.push({
      kind: "verbatim",
      raw: {
        id: "002-deadbeef",
        description: "kept verbatim",
        candidate: {
          title: "old title",
          contacts: ["c-deadbeef0001"],
          groups: [],
          embedding_ref: "emb-old1",
          author: "c-deadbeef0001",
        },
        labels: {
          gold: "inbox-zero",
          gold_rationale: "old rationale",
          expected: "inbox-zero",
          expected_stage: null,
          expected_recorded_at: "2026-05-18T00:00:00.000Z",
        },
        notes: "",
      },
    });
    input.cases.push({
      kind: "verbatim",
      raw: {
        id: "003-deadbe0f",
        candidate: { title: "dangling ref", embedding_ref: "emb-gone" },
        labels: { gold: null },
      },
    });

    const { files, report, slugMigration } = buildCorpusFiles(input);
    expect(slugMigration.get("c-deadbeef0001")).toBe(expectedAnnaSlug);
    expect(slugMigration.get("inbox-zero")).toBe("inbox");

    const casesDoc = parseYaml(files.find((f) => f.path === "cases.yaml")!.text) as {
      cases: Record<string, any>[];
    };
    const verbatim = casesDoc.cases.find((c) => c.id === "002-deadbeef")!;
    expect(verbatim.candidate.contacts).toEqual([expectedAnnaSlug]);
    // v1 author semantics (= created_by) preserved via the v2 escape hatch.
    expect(verbatim.candidate.author).toBeNull();
    expect(verbatim.candidate.created_by_override).toBe(expectedAnnaSlug);
    expect(verbatim.labels.gold).toBe("inbox");
    expect(verbatim.labels.gold_rationale).toBe("old rationale");
    // Old embedding carried forward; unrecoverable ref nulled.
    const embDoc = parseYaml(files.find((f) => f.path === "embeddings.yaml")!.text) as {
      embeddings: { ref: string }[];
    };
    expect(embDoc.embeddings.some((e) => e.ref === "emb-old1")).toBe(true);
    const dangling = casesDoc.cases.find((c) => c.id === "003-deadbe0f")!;
    expect(dangling.candidate.embedding_ref).toBeNull();
    expect(report.some((l) => l.includes("emb-gone"))).toBe(true);

    // The migrated corpus still loads.
    const dir = await writeBuiltCorpus(files);
    const corpus = await loadCorpus(dir);
    expect(corpus.cases.map((c) => c.id)).toContain("002-deadbeef");
  });

  it("holdout: excluded from trainings, emitted as gold cases", async () => {
    const input = baseBuildInput();
    const { training, holdout } = splitHoldout(input.trainings, 1);
    expect(holdout.map((t) => t.id)).toEqual([E_T2]); // most recent move
    input.trainings = training;
    input.cases = [
      ...input.cases,
      ...holdoutCaseEntries(holdout, 2, "2026-06-11T00:00:00.000Z"),
    ];

    const { files } = buildCorpusFiles(input);
    const dir = await writeBuiltCorpus(files);
    const corpus = await loadCorpus(dir);

    const full = corpus.trainingSets.find((t) => t.name === "full")!;
    expect(full.threads.map((t) => t.id)).not.toContain(E_T2);

    const holdoutCase = corpus.cases.find((c) => c.sourceThreadId === E_T2)!;
    expect(holdoutCase.id).toBe(`002-${E_T2.slice(0, 8)}`);
    expect(holdoutCase.tags).toEqual(["holdout-move"]);
    expect(holdoutCase.labels.gold).toBe(P2);
    expect(holdoutCase.labels.goldSource).toBe("human");
    expect(holdoutCase.labels.expected).toBe(P2);
    expect(holdoutCase.asOf!.toISOString()).toBe("2026-04-04T10:00:00.000Z");
  });

  it("preserves refreshed-case labels byte-exactly through the merge + build path", async () => {
    const input = baseBuildInput();
    const originalLabels = {
      gold: "inbox",
      gold_rationale: "Contact and topic — multi-line\nrationale text",
      expected: "engineering",
      expected_stage: "llm_tiebreaker",
      expected_recorded_at: "2026-05-18 00:30:34.947000+00:00",
    };
    const existing = [
      {
        id: "001-f2000000",
        description: "Sampled from prod (topic-shape: channel:N).",
        tags: ["channel:N", "hand-tag"],
        candidate: { title: "stale title", contacts: [] },
        labels: { ...originalLabels },
        notes: "keep me",
      },
      {
        id: "002-deadbeef",
        candidate: { title: "unresolvable" },
        labels: { gold: null },
        notes: "",
      },
    ];
    const refreshedThread = fixtureThread({
      id: E_CASE,
      title: "Fresh hydrated title",
      createdAt: "2026-05-01T12:00:00.000Z",
      filedToPriority: P2,
    });
    const resolution = new Map<string, CaseResolution>([
      ["001-f2000000", { status: "hydrated", thread: refreshedThread }],
      ["002-deadbeef", { status: "missing" }],
    ]);
    const merged = mergeExistingCases(
      existing as Record<string, unknown>[],
      resolution
    );
    input.cases = merged.entries;

    const { files, report } = buildCorpusFiles(input);
    const casesDoc = parseYaml(files.find((f) => f.path === "cases.yaml")!.text) as {
      cases: Record<string, any>[];
    };

    const refreshed = casesDoc.cases.find((c) => c.id === "001-f2000000")!;
    // Labels byte-exact (no gold_source injected; raw strings untouched).
    expect(refreshed.labels).toEqual(originalLabels);
    expect("gold_source" in refreshed.labels).toBe(false);
    expect(refreshed.tags).toEqual(["channel:N", "hand-tag"]);
    expect(refreshed.notes).toBe("keep me");
    // Candidate upgraded from the fresh hydration; refresh metadata filled.
    expect(refreshed.candidate.title).toBe("Fresh hydrated title");
    expect(refreshed.source_thread_id).toBe(E_CASE);
    expect(refreshed.as_of).toBe("2026-05-01T12:00:00.000Z");

    // Unresolvable case kept entirely verbatim + reported by the merge step.
    const verbatim = casesDoc.cases.find((c) => c.id === "002-deadbeef")!;
    expect(verbatim.candidate.title).toBe("unresolvable");
    expect(merged.report.some((l) => l.includes("002-deadbeef"))).toBe(true);
    expect(report).toBeDefined();
  });

  it("never wraps long title lines, so title PII stays warning-grade", () => {
    const input = baseBuildInput();
    // Pre-fix, yaml's default lineWidth (80) wrapped long quoted titles onto
    // continuation lines that don't start with `title:`, so policy-exempt
    // title content was counted as a hard violation (observed live:
    // trainings/full.yaml title tails ending in "(kris@plot.day)").
    const longTitle =
      `${"Quarterly planning review with the vendor leadership team ".repeat(4)}(${RAW_USER_EMAIL})`;
    expect(longTitle.length).toBeGreaterThan(200);
    input.trainings[0]!.title = longTitle;

    const { files, warnings } = buildCorpusFiles(input); // must NOT throw
    expect(
      warnings.some((w) => w.kind === "email" && w.value === RAW_USER_EMAIL)
    ).toBe(true);

    // Every line carrying the raw email is a single-line `title:` scalar.
    for (const f of files) {
      if (!/\.ya?ml$/.test(f.path)) continue;
      const hitLines = f.text
        .split("\n")
        .filter((l) => l.includes(RAW_USER_EMAIL));
      for (const l of hitLines) {
        expect(l).toMatch(/^\s*(?:-\s*)?title:/);
        expect(l).toContain(longTitle); // the whole title is on this line
      }
    }
    const full = files.find((f) => f.path === "trainings/full.yaml")!;
    expect(full.text).toContain(longTitle);
  });

  it("anonymizes verbatim-case topics while preserving labels byte-exactly", () => {
    const input = baseBuildInput();
    input.cases.push({
      kind: "verbatim",
      raw: {
        id: "002-deadbeef",
        description: "kept verbatim",
        candidate: {
          title: "unresolvable thread",
          // A topic is candidate DATA, not a preserved label — pre-fix this
          // raw email survived into cases.yaml as a hard violation
          // (observed live: `topic: channel:kris@plot.day`).
          topic: `channel:${RAW_USER_EMAIL}`,
          contacts: [],
          groups: [],
        },
        labels: {
          gold: null,
          gold_rationale: "byte-preserved rationale",
          expected: null,
        },
        notes: "byte-preserved note",
      },
    });

    const { files } = buildCorpusFiles(input); // must NOT throw
    const casesDoc = parseYaml(files.find((f) => f.path === "cases.yaml")!.text) as {
      cases: Record<string, any>[];
    };
    const v = casesDoc.cases.find((c) => c.id === "002-deadbeef")!;
    expect(v.candidate.topic).toMatch(/^channel:.+@.+$/);
    expect(v.candidate.topic).not.toContain(RAW_USER_EMAIL);
    // Label fields remain byte-preserved.
    expect(v.labels.gold_rationale).toBe("byte-preserved rationale");
    expect(v.notes).toBe("byte-preserved note");
    expect(v.candidate.title).toBe("unresolvable thread");
  });

  it("throws when a referenced contact is missing from the world (caller bug)", () => {
    const input = baseBuildInput();
    input.trainings[0]!.contacts = [
      ...input.trainings[0]!.contacts,
      "f2000000-0000-4000-8000-00000000beef",
    ];
    expect(() => buildCorpusFiles(input)).toThrow(/loadContactsByIds/);
  });

  it("synthesizes a placeholder actor contact for tic-less connections", () => {
    const TIC_LESS = "f2000000-0000-4000-8000-000000000031";
    const input = baseBuildInput();
    input.world.connections.push({
      id: TIC_LESS,
      provider: "unknown",
      actorContactId: null,
      teamId: 77,
    });

    const { files, report } = buildCorpusFiles(input);
    expect(report.some((l) => l.includes("dropped connection"))).toBe(false);

    const worldDoc = parseYaml(
      files.find((f) => f.path === "world.yaml")!.text
    ) as {
      connections: Record<string, unknown>[];
      contacts: Record<string, unknown>[];
      teams: { id: number }[];
    };
    const conn = worldDoc.connections.find((c) => c.id === TIC_LESS)!;
    expect(conn).toBeDefined();
    expect(conn.account_contact).toMatch(/^conn-actor-[0-9a-f]{6}$/);
    const placeholder = worldDoc.contacts.find(
      (c) => c.slug === conn.account_contact
    )!;
    // The placeholder is deterministic (stable across re-extractions) with
    // NULL email/name so connection_org_key's actor lateral skips it.
    expect(placeholder.id).toBe(deterministicUuid(`conn-actor:${TIC_LESS}`));
    expect(placeholder.email).toBeNull();
    expect(placeholder.name).toBeNull();
    expect(placeholder.linked_to_user).toBe(false);
    // The team referenced only by the placeholder-actor connection is emitted.
    expect(worldDoc.teams.some((t) => t.id === 77)).toBe(true);
  });
});
