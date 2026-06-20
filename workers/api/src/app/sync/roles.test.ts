/**
 * Tests for POST /sync/roles — response shape.
 *
 * Regression guard: `user.upsert_role` RETURNS a bare uuid, so the handler
 * must NOT return that string verbatim. The Flutter client pushes roles via
 * `BaseTable.put` → `api.post<Map<String, dynamic>>('/sync/roles', …)`, whose
 * `_parseResponse` does `jsonDecode(body) as Map<String, dynamic>`. A JSON
 * string decodes to a Dart `String`, which can't cast to `Map`, throwing
 *   type 'String' is not a subtype of type 'FutureOr<Map<String, dynamic>>'
 * and stranding the row in sync. The handler must wrap the id in an object so
 * the response decodes to a Map (mirrors POST /sync/groups → `{ id }`).
 *
 * APPROACH: unit test with the DB/RPC/notify dependencies mocked, calling the
 * route through a minimal Hono app via `app.request` (mirrors topics.test.ts).
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";

import { notifyUserSync } from "./notify";

const ROLE_ID = "019ec742-cebe-7a01-af53-073791eabb83";
const USER_ID = "test-user-id";

// upsert_role RETURNS uuid → rpcUser resolves to the bare id string.
vi.mock("../../rpc", () => ({
  rpcUser: vi.fn(async () => ROLE_ID),
}));

// withUserDb just runs the callback with a dummy trx; mapPgError/sql unused
// on the happy path.
vi.mock("../../db", () => ({
  withUserDb: (_db: unknown, _userId: string, fn: (trx: unknown) => unknown) =>
    fn({}),
  mapPgError: () => null,
  sql: {},
}));

// Roles are user-scoped, so the handler must notify the owner's UserSync DO
// directly via notifyUserSync — NOT the priority-scoped notifySync (which
// resolves recipients via get_users_with_priority_access and finds no users
// for a role id, so the change never broadcasts to other devices).
vi.mock("./notify", () => ({
  notifyUserSync: vi.fn(),
}));

beforeEach(() => {
  vi.clearAllMocks();
});

async function postRole(
  body: Record<string, unknown>,
): Promise<{ status: number; raw: string; parsed: unknown }> {
  const { default: roleRoutes } = await import("./roles");
  const app = new Hono<any>();
  app.use("*", async (c: any, next: any) => {
    c.set("user", { id: USER_ID });
    c.set("db", {});
    c.set("tracker", { captureException: () => {} });
    await next();
  });
  app.route("/", roleRoutes);

  const res = await app.request("/sync/roles", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const raw = await res.text();
  return { status: res.status, raw, parsed: JSON.parse(raw) };
}

describe("POST /sync/roles response shape", () => {
  it("returns a JSON object (not a bare string) so the client Map cast succeeds", async () => {
    const { status, parsed } = await postRole({ name: "Work" });

    expect(status).toBe(200);
    // The Flutter client casts the decoded body to Map<String, dynamic>; a
    // bare string would throw. Assert the body decodes to a plain object.
    expect(typeof parsed).toBe("object");
    expect(parsed).not.toBeNull();
    expect(Array.isArray(parsed)).toBe(false);
  });

  it("carries the upserted role id under `id` (mirrors /sync/groups)", async () => {
    const { parsed } = await postRole({ name: "Work" });
    expect(parsed).toMatchObject({ id: ROLE_ID });
  });
});

describe("POST /sync/roles broadcast routing", () => {
  it("notifies the owner's UserSync DO so the change broadcasts to other devices", async () => {
    await postRole({ name: "Work" });

    // Must notify by user id (user-scoped entity), so UserSync's alarm picks up
    // the 'role' user_sync row and fans a 'role' pull out over the WebSocket.
    expect(notifyUserSync).toHaveBeenCalledTimes(1);
    expect(notifyUserSync).toHaveBeenCalledWith(expect.anything(), USER_ID);
  });
});
