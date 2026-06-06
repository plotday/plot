/**
 * Tests for GET /sync/topics — version-gate correctness.
 *
 * APPROACH CHOSEN: Unit tests (vitest.config.ts, node environment).
 *
 * Why NOT the integration config (vitest.integration.config.ts):
 *   The workers-pool integration config loads the entire API worker bundle
 *   via Vite, which transitively hits @plotday/twister/utils/markdown (from
 *   thread-helpers.ts). This module doesn't exist in the unbuilt submodule,
 *   so ALL integration tests fail with:
 *     "Failed to load url @plotday/twister/utils/markdown"
 *   This is a pre-existing project-wide issue unrelated to this task.
 *
 * Two test groups:
 *   1. DB integration (txn-rollback) — queries user.topic and user.group
 *      views through a real Kysely connection to the worktree DB (port 54346).
 *      Skipped when DATABASE_URL points to a non-54346 port (CI without DB).
 *
 *   2. Version-gate unit tests — minimal Hono app with a stub db that
 *      records which view was queried, asserting the handler picks the
 *      correct branch by apiVersion.
 */

import { beforeAll, describe, expect, it } from "vitest";
import { Hono } from "hono";

// ---------------------------------------------------------------------------
// DB integration helpers
// ---------------------------------------------------------------------------

// Run DB integration tests only when a database is configured via DATABASE_URL.
// In CI (no DB) this is unset, so the whole describe — including its beforeAll
// connection — is skipped. The default points at the worktree DB (port 54346)
// for convenience when DATABASE_URL is exported locally.
const DATABASE_URL = process.env.DATABASE_URL;
const DB_URL =
  DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54346/postgres";

describe.skipIf(!DATABASE_URL)(
  "DB integration: user.topic vs user.group shapes",
  () => {
    let db: any;
    let userId: string;

    beforeAll(async () => {
      const { createDb } = await import("../../db");
      db = createDb({ DATABASE_URL: DB_URL } as any);

      // Pick a user that has at least one user.topic row.
      const row = await db
        .selectFrom("user.topic")
        .select("user_id")
        .where("user_id", "is not", null)
        .executeTakeFirst();
      userId = row?.user_id ?? "";
    });

    it("user.topic rows include is_member and not type (topic shape)", async () => {
      if (!userId) return;

      const rows = await db
        .selectFrom("user.topic")
        .selectAll()
        .where("user_id", "=", userId)
        .limit(5)
        .execute();

      expect(rows.length).toBeGreaterThan(0);
      // Topic-specific field present on user.topic
      expect(rows[0]).toHaveProperty("is_member");
      expect(rows[0]).toHaveProperty("announce");
      // group-specific field absent from user.topic
      expect(rows[0]).not.toHaveProperty("type");
      expect(rows[0]).not.toHaveProperty("privacy");
    });

    it("user.group rows include type and not announce (group shape)", async () => {
      // Find a user that has a user.group row.
      const row = await db
        .selectFrom("user.group")
        .select("user_id")
        .where("user_id", "is not", null)
        .executeTakeFirst();
      const gUserId = row?.user_id ?? "";
      if (!gUserId) return;

      const rows = await db
        .selectFrom("user.group")
        .selectAll()
        .where("user_id", "=", gUserId)
        .limit(5)
        .execute();

      expect(rows.length).toBeGreaterThan(0);
      // Group-specific fields present on user.group
      expect(rows[0]).toHaveProperty("type");
      expect(rows[0]).toHaveProperty("is_member");
      // Topic-specific field absent from user.group
      expect(rows[0]).not.toHaveProperty("announce");
    });
  },
);

// ---------------------------------------------------------------------------
// Version-gate unit tests (stub db, no real DB required)
// ---------------------------------------------------------------------------

/**
 * Build a minimal stub db that records which views were queried.
 * Returns rows shaped with either user.topic fields (announce, is_member)
 * or user.group fields (type, privacy) depending on which table is accessed.
 */
function buildStubDb() {
  const queriedViews: string[] = [];

  // A minimal Kysely-like chain stub.
  function makeChain(view: string, sampleRow: Record<string, unknown>) {
    queriedViews.push(view);
    const chain: any = {
      selectAll: () => chain,
      where: () => chain,
      orderBy: () => chain,
      limit: () => chain,
      execute: async () => [sampleRow],
    };
    return chain;
  }

  const topicRow = {
    user_id: "u1",
    id: "t1",
    name: "Test Topic",
    is_member: true,
    announce: false,
    can_post: true,
    can_manage: false,
    archived_at: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    seq: "100",
    team_id: null,
    join_policy: "open",
    key: null,
    auto_maintained: false,
    opted_out: false,
    is_admin: false,
    member_contact_ids: [],
  };

  const groupRow = {
    user_id: "u1",
    id: "g1",
    name: "Test Group",
    type: "private",
    privacy: "private",
    is_member: true,
    can_post: true,
    can_address: false,
    archived_at: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    seq: "100",
    team_id: null,
    join_policy: "member",
    key: null,
    auto_maintained: false,
    is_admin: false,
    member_contact_ids: [],
  };

  const stubDb = {
    transaction: () => ({
      execute: async (fn: (trx: any) => Promise<any>) => {
        // Build a trx that tracks which view is queried.
        const trx = {
          selectFrom: (view: string) => {
            if (view === "user.topic") return makeChain("user.topic", topicRow);
            if (view === "user.group") return makeChain("user.group", groupRow);
            return makeChain(view, {});
          },
          execute: async (q: any) => q.execute ? q.execute() : [],
        };
        // Also wire sql template helper used by readSafeHorizon
        (trx as any).executeQuery = async () => ({ rows: [{ horizon: "999" }] });
        (trx as any).getExecutor = () => ({
          transformQuery: (n: any) => n,
          compileQuery: () => ({ sql: "", parameters: [] }),
          executeQuery: async () => ({ rows: [{ horizon: "999" }] }),
        });
        return fn(trx);
      },
    }),
  };

  return { stubDb, queriedViews };
}

async function getTopics(
  apiVersion: number,
  query: Record<string, string> = {},
): Promise<{ status: number; body: any; queriedViews: string[] }> {
  const { stubDb, queriedViews } = buildStubDb();

  const { default: topicRoutes } = await import("./topics");
  const app = new Hono<any>();

  app.use("*", async (c: any, next: any) => {
    c.set("user", { id: "test-user-id" });
    c.set("apiVersion", apiVersion);
    c.set("db", stubDb);
    await next();
  });
  app.route("/", topicRoutes);

  const qs = new URLSearchParams(query).toString();
  const url = qs ? `/sync/topics?${qs}` : "/sync/topics";
  const res = await app.request(url, { method: "GET" });
  const body = await res.json().catch(() => null);

  return { status: res.status, body, queriedViews };
}

describe("GET /sync/topics version gate", () => {
  it("apiVersion 0 (absent) queries user.group (legacy shape)", async () => {
    const { status, body, queriedViews } = await getTopics(0);
    expect(status).toBe(200);
    expect(queriedViews).toContain("user.group");
    expect(queriedViews).not.toContain("user.topic");
    // Response is a plain array (no envelope) for legacy path
    expect(Array.isArray(body)).toBe(true);
    // group-specific field present
    expect(body[0]).toHaveProperty("type");
  });

  it("apiVersion 2 queries user.group (legacy shape)", async () => {
    const { queriedViews } = await getTopics(2);
    expect(queriedViews).toContain("user.group");
    expect(queriedViews).not.toContain("user.topic");
  });

  it("apiVersion 3 queries user.topic (new topic entity shape)", async () => {
    const { status, body, queriedViews } = await getTopics(3);
    expect(status).toBe(200);
    expect(queriedViews).toContain("user.topic");
    expect(queriedViews).not.toContain("user.group");
    // Without seq_since cursor, response is a plain array
    expect(Array.isArray(body)).toBe(true);
    // topic-specific field present
    expect(body[0]).toHaveProperty("announce");
  });

  it("apiVersion 5 (future v3+) queries user.topic", async () => {
    const { queriedViews } = await getTopics(5);
    expect(queriedViews).toContain("user.topic");
    expect(queriedViews).not.toContain("user.group");
  });

  it("apiVersion 3 with seq_since returns seqEnvelope shape", async () => {
    const { body, queriedViews } = await getTopics(3, { seq_since: "50" });
    expect(queriedViews).toContain("user.topic");
    // With seq_since the response is the seqEnvelope shape
    expect(body).toHaveProperty("rows");
    expect(body).toHaveProperty("next_horizon");
    expect(Array.isArray(body.rows)).toBe(true);
  });

  it("apiVersion 2 with seq_since still returns plain array (legacy path ignores seq cursor)", async () => {
    const { body, queriedViews } = await getTopics(2, { seq_since: "50" });
    expect(queriedViews).toContain("user.group");
    // Legacy path ignores seq_since; returns plain array
    expect(Array.isArray(body)).toBe(true);
  });
});
