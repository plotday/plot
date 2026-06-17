/**
 * Tests for the /hook/todoist app-level webhook route.
 *
 * Unit mode (vitest.config.ts, node env) — mirrors topic-routes.test.ts. The
 * route imports only hono, superjson, ../db (mocked), ../twist/invoke-webhook
 * (mocked), ../utils/* and type ../env, none of which reach the broken
 * unbuilt-twister exports that fail the integration config.
 *
 * Todoist delivers ONE app-level webhook URL for all users; the route verifies
 * the HMAC, then routes by event_data.project_id → channel → twist_instance →
 * the connector's stored `webhook_callback_<projectId>` callback.
 */

import { describe, it, expect, vi, beforeEach, type Mock } from "vitest";
import superjson from "superjson";

import { createDb } from "../db";
import { invokeWebhookCallback } from "../twist/invoke-webhook";
import hookTodoist, { verifyTodoistSignature } from "./hook-todoist";

// vi.mock is hoisted above the imports, so the imported `createDb` /
// `invokeWebhookCallback` resolve to these mocks (mirrors topic-routes.test.ts).
vi.mock("../db", () => ({ createDb: vi.fn() }));
vi.mock("../twist/invoke-webhook", () => ({
  invokeWebhookCallback: vi.fn(async () => undefined),
}));
vi.mock("../utils/error-capture", () => ({
  captureServerError: vi.fn(
    async (_c: any, _err: any, msg: string) =>
      new Response(JSON.stringify({ message: msg }), { status: 500 }),
  ),
}));

const createDbMock = createDb as unknown as Mock;
const invokeMock = invokeWebhookCallback as unknown as Mock;

const SECRET = "test-todoist-client-secret";

/** Compute Todoist's HMAC-SHA256(body, secret) as base64 — same scheme the route verifies. */
async function sign(secret: string, body: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

/** Fake Kysely chain: every builder method returns the same object; execute() yields `rows`. */
function fakeDb(rows: Array<{ twist_instance_id: string }>) {
  const db: any = {
    selectFrom: vi.fn(() => db),
    select: vi.fn(() => db),
    where: vi.fn(() => db),
    execute: vi.fn(async () => rows),
    destroy: vi.fn(async () => {}),
  };
  return db;
}

/** Fake STORAGE DO namespace whose stub.get(key) returns a superjson-wrapped token (or null). */
function fakeStorage(token: string | null) {
  const stub = { get: vi.fn(async () => (token === null ? null : superjson.stringify(token))) };
  return { idFromName: vi.fn(() => "do-id"), get: vi.fn(() => stub) };
}

function makeEnv(token: string | null) {
  return { AUTH_TODOIST_SECRET: SECRET, STORAGE: fakeStorage(token) } as any;
}

const execCtx = { exports: {} } as any;

async function post(body: string, signature: string | undefined, env: any) {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (signature !== undefined) headers["x-todoist-hmac-sha256"] = signature;
  return hookTodoist.request(
    "/hook/todoist",
    { method: "POST", headers, body },
    env,
    execCtx,
  );
}

beforeEach(() => {
  createDbMock.mockReset();
  invokeMock.mockReset();
});

describe("verifyTodoistSignature", () => {
  it("accepts a correct HMAC-SHA256 base64 signature", async () => {
    const body = '{"event_name":"item:added"}';
    expect(await verifyTodoistSignature(SECRET, body, await sign(SECRET, body))).toBe(true);
  });

  it("rejects a wrong signature", async () => {
    const body = '{"event_name":"item:added"}';
    expect(await verifyTodoistSignature(SECRET, body, await sign("other-secret", body))).toBe(false);
  });

  it("rejects a missing signature", async () => {
    expect(await verifyTodoistSignature(SECRET, "{}", undefined)).toBe(false);
  });
});

describe("POST /hook/todoist", () => {
  it("returns 401 and dispatches nothing when the signature is invalid", async () => {
    const body = JSON.stringify({
      event_name: "item:added",
      user_id: "u1",
      event_data: { id: "t1", project_id: "p1" },
    });
    const res = await post(body, "not-a-valid-signature", makeEnv("doid:token"));
    expect(res.status).toBe(401);
    expect(createDbMock).not.toHaveBeenCalled();
    expect(invokeMock).not.toHaveBeenCalled();
  });

  it("dispatches the parsed event to the connector callback for a known project", async () => {
    createDbMock.mockReturnValue(fakeDb([{ twist_instance_id: "ti-1" }]));
    const event = {
      event_name: "item:completed",
      user_id: "u1",
      event_data: { id: "t1", project_id: "p1" },
    };
    const body = JSON.stringify(event);
    const res = await post(body, await sign(SECRET, body), makeEnv("doid:token"));
    expect(res.status).toBe(200);
    expect(invokeMock).toHaveBeenCalledTimes(1);
    // invokeWebhookCallback(env, ctx, token, { eventName, eventData })
    const [, , token, payload] = invokeMock.mock.calls[0];
    expect(token).toBe("doid:token");
    expect(payload).toEqual({ eventName: "item:completed", eventData: event.event_data });
  });

  it("acks without dispatching when no channel matches the project", async () => {
    createDbMock.mockReturnValue(fakeDb([]));
    const event = {
      event_name: "item:added",
      user_id: "u1",
      event_data: { id: "t1", project_id: "unknown" },
    };
    const body = JSON.stringify(event);
    const res = await post(body, await sign(SECRET, body), makeEnv("doid:token"));
    expect(res.status).toBe(200);
    expect(invokeMock).not.toHaveBeenCalled();
  });
});
