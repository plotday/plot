import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { loadCorpus } from "../src/corpus/load";
import {
  loadTrainingSet,
  loadWorld,
  openSandbox,
  stageCandidate,
  type SandboxHandle,
} from "../src/sandbox/pg-sandbox";

const KRIS_V1_DIR = resolve(__dirname, "fixtures", "kris-v1");

const USER_ID = "e0000000-0000-4000-8000-000000000001";
const P_ROOT = "e0000000-0000-4000-8000-000000000010";
const P_ENG = "e0000000-0000-4000-8000-000000000011";
const ANNA = "e0000000-0000-4000-8000-000000000020";
const BOB = "e0000000-0000-4000-8000-000000000021";
const CAROL = "e0000000-0000-4000-8000-000000000022";
const CONN_ORG = "e0000000-0000-4000-8000-000000000030";
const CONN_FREE = "e0000000-0000-4000-8000-000000000031";
const CONN_TEAM = "e0000000-0000-4000-8000-000000000032";
const T1 = "e0000000-0000-4000-8000-000000000100";
const NEG1 = "e0000000-0000-4000-8000-000000000200";
const TEAM_ID = 7;
const TEAM_OFFSET_ID = 1_000_000_000 + TEAM_ID;
const CHANNEL_ID = 987654301;

const WORLD_V2 = `
name: sandbox-v2-fixture
schema_version: 2
source: { kind: handcrafted }
user:
  id: "${USER_ID}"
  email: "sandbox-v2-user@example.test"
  subscription: { plan: pro, status: active }
teams:
  - { slug: acme, id: ${TEAM_ID}, name: Acme }
connections:
  - { slug: gmail-org, id: "${CONN_ORG}", provider: google, account_contact: anna, team: null }
  - { slug: gmail-free, id: "${CONN_FREE}", provider: google, account_contact: bob, team: null }
  - { slug: slack-team, id: "${CONN_TEAM}", provider: slack, account_contact: carol, team: acme }
priorities:
  - slug: root
    id: "${P_ROOT}"
    path: evalroot
    title: Root
    description: Email triage and follow-ups
    facet_filters:
      automation: { exclude: [automated] }
      trustedSendersOnly: true
  - { slug: eng, id: "${P_ENG}", path: evalroot.eng, title: Engineering }
contacts:
  - { slug: anna, id: "${ANNA}", email: "anna@lumenforge.com", name: Anna, linked_to_user: true }
  - { slug: bob, id: "${BOB}", email: "bob@gmail.com", linked_to_user: true }
  - { slug: carol, id: "${CAROL}" }
channels:
  - { id: ${CHANNEL_ID}, connection: gmail-org, default_priority_id: null }
`;

const TRAININGS_V2 = `
name: full
threads:
  - id: "${T1}"
    title: Invoice from vendor
    contacts: [anna]
    filed_to_priority: root
    author: anna
    connection: gmail-org
    facets: { format: message, automation: automated }
    created_at: "2026-04-02T10:00:00Z"
    moved_at: "2026-04-03T09:30:00Z"
negative_threads:
  - id: "${NEG1}"
    title: Marketing blast
    contacts: [anna]
    author: anna
    connection: gmail-org
    created_at: "2026-04-01T00:00:00Z"
negatives:
  - { thread: "${NEG1}", priority: eng, source: moved_out, created_at: "2026-04-05T08:00:00Z" }
`;

async function writeCorpus(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "eval-sandbox-v2-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(dir, rel);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
  }
  return dir;
}

function v2Files(): Record<string, string> {
  return {
    "world.yaml": WORLD_V2,
    "trainings/full.yaml": TRAININGS_V2,
    "cases.yaml": "cases: []\n",
  };
}

describe.runIf(!!process.env.DATABASE_URL)("sandbox v2", () => {
  let sandbox: SandboxHandle | null = null;

  afterEach(async () => {
    if (sandbox) {
      await sandbox.close();
      sandbox = null;
    }
  });

  it("loads a v2 world: org keys, subscription, priority extras, channel FK", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    sandbox = await openSandbox();
    await loadWorld(sandbox, corpus);

    // 1. connection_org_key resolves all three branches exactly as in prod.
    const orgKey = async (id: string) =>
      (
        (await sandbox!.rawQuery(
          `SELECT public.connection_org_key($1) AS key`,
          [id]
        )) as { rows: { key: string | null }[] }
      ).rows[0]!.key;
    expect(await orgKey(CONN_ORG)).toBe("domain:lumenforge.com");
    expect(await orgKey(CONN_FREE)).toBeNull(); // gmail.com is seeded freemail
    expect(await orgKey(CONN_TEAM)).toBe(`team:${TEAM_OFFSET_ID}`);

    // 2. Subscription row with the declared plan/status.
    const sub = (await sandbox.rawQuery(
      `SELECT plan::text AS plan, status::text AS status
       FROM public.user_subscription WHERE user_id = $1`,
      [USER_ID]
    )) as { rows: { plan: string; status: string }[] };
    expect(sub.rows).toEqual([{ plan: "pro", status: "active" }]);

    // 3. Priority carries description + facet_filters jsonb.
    const prio = (await sandbox.rawQuery(
      `SELECT description, facet_filters FROM public.priority WHERE id = $1`,
      [P_ROOT]
    )) as { rows: { description: string | null; facet_filters: unknown }[] };
    expect(prio.rows[0]!.description).toBe("Email triage and follow-ups");
    expect(prio.rows[0]!.facet_filters).toEqual({
      automation: { exclude: ["automated"] },
      trustedSendersOnly: true,
    });
    const prioEng = (await sandbox.rawQuery(
      `SELECT description, facet_filters FROM public.priority WHERE id = $1`,
      [P_ENG]
    )) as { rows: { description: string | null; facet_filters: unknown }[] };
    expect(prioEng.rows[0]).toEqual({ description: null, facet_filters: null });

    // 4. Channel references its declared connection (no placeholder).
    const ch = (await sandbox.rawQuery(
      `SELECT twist_instance_id FROM public.channel WHERE id = $1`,
      [CHANNEL_ID]
    )) as { rows: { twist_instance_id: string }[] };
    expect(ch.rows).toEqual([{ twist_instance_id: CONN_ORG }]);

    // v2 contacts get their names inserted.
    const contact = (await sandbox.rawQuery(
      `SELECT name FROM public.contact WHERE id = $1`,
      [ANNA]
    )) as { rows: { name: string | null }[] };
    expect(contact.rows[0]!.name).toBe("Anna");

    // Team id is offset into the high range.
    const team = (await sandbox.rawQuery(
      `SELECT name FROM public.team WHERE id = $1`,
      [TEAM_OFFSET_ID]
    )) as { rows: { name: string }[] };
    expect(team.rows).toEqual([{ name: "Acme" }]);
  });

  it("omits the user_subscription row when subscription is null", async () => {
    const files = v2Files();
    files["world.yaml"] = WORLD_V2.replace(/^ {2}subscription:.*\n/m, "");
    const dir = await writeCorpus(files);
    const corpus = await loadCorpus(dir);
    sandbox = await openSandbox();
    await loadWorld(sandbox, corpus);

    const sub = await sandbox.rawQuery(
      `SELECT 1 FROM public.user_subscription WHERE user_id = $1`,
      [USER_ID]
    );
    expect(sub.rows).toHaveLength(0);
  });

  it("loads a v2 training set: thread columns, negative threads, negatives", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    sandbox = await openSandbox();
    await loadWorld(sandbox, corpus);
    await loadTrainingSet(sandbox, corpus, corpus.trainingSets[0]!);

    // 5. Training thread row carries the v2 columns.
    const t1 = (await sandbox.rawQuery(
      `SELECT created_by, author_id, twist_id, facets, created_at
       FROM public.thread WHERE id = $1`,
      [T1]
    )) as {
      rows: {
        created_by: string;
        author_id: string | null;
        twist_id: string | null;
        facets: unknown;
        created_at: Date;
      }[];
    };
    expect(t1.rows).toHaveLength(1);
    const row = t1.rows[0]!;
    expect(row.created_by).toBe(CONN_ORG);
    expect(row.author_id).toBe(ANNA);
    expect(row.twist_id).not.toBeNull();
    expect(Number(row.twist_id)).toBeGreaterThanOrEqual(1_000_000_000);
    expect(row.facets).toEqual({ format: "message", automation: "automated" });
    expect(new Date(row.created_at).toISOString()).toBe(
      "2026-04-02T10:00:00.000Z"
    );

    // It still gets its thread_priority training filing.
    const tp = await sandbox.rawQuery(
      `SELECT 1 FROM public.thread_priority
       WHERE thread_id = $1 AND user_id = $2 AND priority_id = $3 AND user_moved`,
      [T1, USER_ID, P_ROOT]
    );
    expect(tp.rows).toHaveLength(1);

    // 6. Negative thread exists, has the same column treatment, no filing.
    const neg = (await sandbox.rawQuery(
      `SELECT created_by, author_id, twist_id, created_at
       FROM public.thread WHERE id = $1`,
      [NEG1]
    )) as {
      rows: {
        created_by: string;
        author_id: string | null;
        twist_id: string | null;
        created_at: Date;
      }[];
    };
    expect(neg.rows).toHaveLength(1);
    expect(neg.rows[0]!.created_by).toBe(CONN_ORG);
    expect(neg.rows[0]!.author_id).toBe(ANNA);
    expect(neg.rows[0]!.twist_id).not.toBeNull();
    expect(new Date(neg.rows[0]!.created_at).toISOString()).toBe(
      "2026-04-01T00:00:00.000Z"
    );
    const negTp = await sandbox.rawQuery(
      `SELECT 1 FROM public.thread_priority WHERE thread_id = $1`,
      [NEG1]
    );
    expect(negTp.rows).toHaveLength(0);

    // ...and its thread_priority_negative row.
    const tpn = (await sandbox.rawQuery(
      `SELECT source, created_at FROM public.thread_priority_negative
       WHERE user_id = $1 AND thread_id = $2 AND priority_id = $3`,
      [USER_ID, NEG1, P_ENG]
    )) as { rows: { source: string; created_at: Date }[] };
    expect(tpn.rows).toHaveLength(1);
    expect(tpn.rows[0]!.source).toBe("moved_out");
    expect(new Date(tpn.rows[0]!.created_at).toISOString()).toBe(
      "2026-04-05T08:00:00.000Z"
    );
  });

  it("stages a v2 candidate: connection created_by, author, twist_id, facets", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    sandbox = await openSandbox();
    await loadWorld(sandbox, corpus);

    const CAND = "e0000000-0000-4000-8000-000000000300";
    await stageCandidate(sandbox, corpus, {
      threadId: CAND,
      title: "Quarterly invoice arrived",
      topic: null,
      contacts: [ANNA],
      groups: [],
      embedding: null,
      authorContactId: ANNA,
      connectionId: CONN_ORG,
      createdByOverride: null,
      facets: { format: "message", automation: "automated" },
    });

    // stageCandidate runs with triggers ON (production path), so only assert
    // columns the trigger chain doesn't clobber: author_id, created_by,
    // twist_id, and facets are all safe.
    const res = (await sandbox.rawQuery(
      `SELECT created_by, author_id, twist_id, facets
       FROM public.thread WHERE id = $1`,
      [CAND]
    )) as {
      rows: {
        created_by: string;
        author_id: string | null;
        twist_id: string | null;
        facets: unknown;
      }[];
    };
    expect(res.rows).toHaveLength(1);
    const cand = res.rows[0]!;
    expect(cand.author_id).toBe(ANNA);
    expect(cand.created_by).toBe(CONN_ORG);
    expect(cand.twist_id).not.toBeNull();
    expect(Number(cand.twist_id)).toBeGreaterThanOrEqual(1_000_000_000);
    expect(cand.facets).toEqual({ format: "message", automation: "automated" });
  });

  it("fails loudly when a v2 channel id collides with an existing row", async () => {
    const dir = await writeCorpus(v2Files());
    const corpus = await loadCorpus(dir);
    sandbox = await openSandbox();

    // Simulate a pre-existing dev row with the same channel id. FKs are
    // disabled under replica role, PK uniqueness is not.
    await sandbox.rawQuery(`SET LOCAL session_replication_role = replica`);
    await sandbox.rawQuery(
      `INSERT INTO public.channel (id, twist_instance_id, channel_id, title)
       OVERRIDING SYSTEM VALUE
       VALUES ($1, $2, 'pre-existing', 'Pre-existing')`,
      [CHANNEL_ID, USER_ID]
    );

    await expect(loadWorld(sandbox, corpus)).rejects.toThrow(
      /duplicate key|channel_pkey/
    );
  });

  it("keeps v1 corpora byte-identical: no contact names, placeholder channels", async () => {
    const corpus = await loadCorpus(KRIS_V1_DIR);
    expect(corpus.world.schemaVersion).toBe(1);
    sandbox = await openSandbox();
    await loadWorld(sandbox, corpus);
    const full = corpus.trainingSets.find((t) => t.name === "full")!;
    await loadTrainingSet(sandbox, corpus, full);

    // v1 must NOT insert contact names (the tiebreaker prompt renders
    // COALESCE(name, email, id) — names would change prompts + cache keys).
    const namedInCorpus = corpus.world.contacts.filter((c) => c.name !== null);
    expect(namedInCorpus.length).toBeGreaterThan(0); // assert is not vacuous
    const named = (await sandbox.rawQuery(
      `SELECT count(*)::int AS n FROM public.contact
       WHERE id = ANY($1::uuid[]) AND name IS NOT NULL`,
      [namedInCorpus.map((c) => c.id)]
    )) as { rows: { n: number }[] };
    expect(named.rows[0]!.n).toBe(0);

    // v1 channels keep the placeholder parent (= world user id).
    expect(corpus.world.channels.length).toBeGreaterThan(0);
    const ch = (await sandbox.rawQuery(
      `SELECT count(*)::int AS n FROM public.channel
       WHERE id = ANY($1::bigint[]) AND twist_instance_id = $2`,
      [corpus.world.channels.map((c) => c.id), corpus.world.user.id]
    )) as { rows: { n: number }[] };
    expect(ch.rows[0]!.n).toBe(corpus.world.channels.length);

    // v1 training threads keep null author_id / twist_id / facets.
    const t = (await sandbox.rawQuery(
      `SELECT count(*)::int AS n FROM public.thread
       WHERE id = ANY($1::uuid[])
         AND author_id IS NULL AND twist_id IS NULL AND facets IS NULL`,
      [full.threads.map((th) => th.id)]
    )) as { rows: { n: number }[] };
    expect(t.rows[0]!.n).toBe(full.threads.length);
  });
});
