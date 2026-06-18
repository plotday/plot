/**
 * Tests for /topic/* routes — version-gate correctness.
 *
 * APPROACH CHOSEN: Unit tests (vitest.config.ts, node environment).
 *
 * Why NOT the integration config (vitest.integration.config.ts):
 *   The workers-pool integration config loads the entire API worker bundle
 *   via Vite, which transitively hits @plotday/twister/utils/markdown (from
 *   thread-helpers.ts). This module doesn't exist in the unbuilt submodule,
 *   so ALL integration tests fail with:
 *     "Failed to load url @plotday/twister/utils/markdown"
 *   This is a pre-existing project-wide issue unrelated to Task 3.
 *
 * Why this works in unit mode:
 *   topic.ts imports only: hono, zod, ../rpc, ../utils/*, type ../env.
 *   None of these transitively reach the broken twister exports.
 *
 * Two test groups:
 *   1. DB integration (txn-rollback) — calls create_topic and create_group
 *      RPCs through a real Kysely connection to the worktree DB (port 54346).
 *      Skipped when DATABASE_URL is absent (CI without DB).
 *
 *   2. Version-gate unit tests — mock rpc() and assert that POST /topic
 *      calls create_group for apiVersion < 3 and create_topic for >= 3.
 */

import { Hono } from "hono";
import {
  beforeAll,
  describe,
  expect,
  it,
  vi,
  type MockedFunction,
} from "vitest";

import { rpc } from "../rpc";
import type * as RpcModule from "../rpc";
import { isV3 } from "./topic";

// ---------------------------------------------------------------------------
// Mocks — vi.mock is hoisted above the imports, so `rpc` resolves to the mock
// even though it is imported at the top of the file (required by import/first).
// ---------------------------------------------------------------------------

vi.mock("../rpc", () => ({
  rpc: vi.fn(async () => "00000000-0000-0000-0000-000000000001"),
}));

vi.mock("../utils/error-capture", () => ({
  captureServerError: vi.fn(
    async (_c: any, _err: any, msg: string) =>
      new Response(JSON.stringify({ message: msg }), { status: 500 }),
  ),
}));

// Typed reference to the mocked rpc for assertions.
const rpcMock = rpc as MockedFunction<typeof rpc>;

// ---------------------------------------------------------------------------
// DB integration helpers (real DB, txn rollback)
// ---------------------------------------------------------------------------

// Run DB integration tests only when a database is configured via DATABASE_URL.
// In CI (no DB) this is unset, so the whole DB describe — including its
// beforeAll connection — is skipped. The default points at the worktree DB
// (port 54346) for convenience when DATABASE_URL is exported locally.
const DATABASE_URL = process.env.DATABASE_URL;
const DB_URL =
  DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54346/postgres";

describe("isV3 helper", () => {
  it("returns false when apiVersion is 0 (absent)", () => {
    expect(isV3({ var: { apiVersion: 0 } })).toBe(false);
  });

  it("returns false when apiVersion is 2", () => {
    expect(isV3({ var: { apiVersion: 2 } })).toBe(false);
  });

  it("returns true when apiVersion is 3", () => {
    expect(isV3({ var: { apiVersion: 3 } })).toBe(true);
  });

  it("returns true when apiVersion is 10 (future)", () => {
    expect(isV3({ var: { apiVersion: 10 } })).toBe(true);
  });

  it("returns false when apiVersion is undefined", () => {
    expect(isV3({ var: {} })).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// DB integration: create_topic / create_group RPCs (txn rollback)
// ---------------------------------------------------------------------------

describe.skipIf(!DATABASE_URL)("topic RPCs via DB (txn rollback)", () => {
  let userId: string;
  let db: any;

  beforeAll(async () => {
    // Lazy-import createDb so the pg driver only loads when we actually have a DB.
    const { createDb } = await import("../db");
    db = createDb({ DATABASE_URL: DB_URL } as any);
    const row = await db
      .selectFrom("user")
      .select("id")
      .executeTakeFirst();
    userId = row?.id ?? "";
  });

  it("create_topic RPC returns a UUID (txn rollback)", async () => {
    // Use the actual (un-mocked) rpc for DB integration tests.
    const realRpc = (await vi.importActual<typeof RpcModule>("../rpc")).rpc;

    let capturedTopicId: string | undefined;

    try {
      await db.transaction().execute(async (trx: any) => {
        const topicId = await realRpc(trx, "create_topic", {
          p_user_id: userId,
          p_name: "integration-test-topic",
          p_announce: false,
          p_contact_ids: `{}` as any,
          p_group_ids: `{}` as any,
        });

        capturedTopicId = topicId as string;

        // Confirm the topic row exists within the txn before rollback.
        const row = await trx
          .selectFrom("topic")
          .select("id")
          .where("id", "=", topicId)
          .executeTakeFirst();
        expect(row?.id).toBe(topicId);

        // Force rollback so nothing persists.
        throw Object.assign(new Error("__rollback__"), { isRollback: true });
      });
    } catch (e: any) {
      if (!e.isRollback) throw e;
    }

    expect(typeof capturedTopicId).toBe("string");
    expect(capturedTopicId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
  });

  it("create_group RPC returns a UUID (txn rollback)", async () => {
    const realRpc = (await vi.importActual<typeof RpcModule>("../rpc")).rpc;

    let capturedGroupId: string | undefined;

    try {
      await db.transaction().execute(async (trx: any) => {
        const groupId = await realRpc(trx, "create_group", {
          p_user_id: userId,
          p_name: "integration-test-group",
          p_type: "private" as any,
          p_join_policy: "member" as any,
          p_member_contact_ids: `{}` as any,
        });

        capturedGroupId = groupId as string;

        const row = await trx
          .selectFrom("group")
          .select("id")
          .where("id", "=", groupId)
          .executeTakeFirst();
        expect(row?.id).toBe(groupId);

        throw Object.assign(new Error("__rollback__"), { isRollback: true });
      });
    } catch (e: any) {
      if (!e.isRollback) throw e;
    }

    expect(typeof capturedGroupId).toBe("string");
    expect(capturedGroupId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
  });
});

// ---------------------------------------------------------------------------
// Route-level version gate: mocked rpc(), real Hono routing
// ---------------------------------------------------------------------------

function buildStubDb() {
  return {
    transaction: () => ({
      execute: (fn: (trx: any) => Promise<any>) => fn({}),
    }),
    selectFrom: () => ({
      where: () => ({
        where: () => ({
          executeTakeFirst: async () => undefined,
        }),
      }),
    }),
    insertInto: () => ({
      values: () => ({
        onConflict: () => ({
          doNothing: () => ({ execute: async () => [] }),
        }),
      }),
    }),
    deleteFrom: () => ({
      where: () => ({
        where: () => ({ execute: async () => [] }),
      }),
    }),
  };
}

async function postTopic(
  apiVersion: number,
  body: Record<string, unknown>,
): Promise<{ status: number; body: any; calledRpc: string | null }> {
  rpcMock.mockClear();

  const { default: topicRoutes } = await import("./topic");
  const app = new Hono<any>();
  const stubDb = buildStubDb();
  app.use("*", async (c: any, next: any) => {
    c.set("user", { id: "test-user-id" });
    c.set("apiVersion", apiVersion);
    c.set("db", stubDb);
    await next();
  });
  app.route("/", topicRoutes);

  const res = await app.request("/topic", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  const responseBody = await res.json().catch(() => null);
  const calledRpc =
    rpcMock.mock.calls.length > 0 ? (rpcMock.mock.calls[0][1] as string) : null;

  return { status: res.status, body: responseBody, calledRpc };
}

describe("POST /topic version gate", () => {
  it("apiVersion 0 (absent) routes to create_group", async () => {
    const { status, body, calledRpc } = await postTopic(0, { name: "my-group" });
    expect(status).toBe(200);
    expect(body.id).toBe("00000000-0000-0000-0000-000000000001");
    expect(calledRpc).toBe("create_group");
  });

  it("apiVersion 2 routes to create_group", async () => {
    const { calledRpc } = await postTopic(2, { name: "my-group" });
    expect(calledRpc).toBe("create_group");
  });

  it("apiVersion 3 routes to create_topic", async () => {
    const { status, body, calledRpc } = await postTopic(3, { name: "my-topic" });
    expect(status).toBe(200);
    expect(body.id).toBe("00000000-0000-0000-0000-000000000001");
    expect(calledRpc).toBe("create_topic");
  });

  it("apiVersion 5 (future v3+) routes to create_topic", async () => {
    const { calledRpc } = await postTopic(5, { name: "future-topic" });
    expect(calledRpc).toBe("create_topic");
  });

  it("create_group receives legacy schema fields (type, joinPolicy)", async () => {
    rpcMock.mockClear();
    await postTopic(2, { name: "g", type: "public", joinPolicy: "open" });
    const args = rpcMock.mock.calls[0][2] as any;
    expect(args.p_type).toBe("public");
    expect(args.p_join_policy).toBe("open");
    expect(args.p_announce).toBeUndefined();
  });

  it("create_topic receives new schema fields (announce)", async () => {
    rpcMock.mockClear();
    await postTopic(3, { name: "t", announce: true });
    const args = rpcMock.mock.calls[0][2] as any;
    expect(args.p_announce).toBe(true);
    expect(args.p_type).toBeUndefined();
  });
});
