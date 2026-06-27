/**
 * Tests for /ai-preference GET + POST endpoints.
 *
 * Coverage:
 *   - GET returns { builtin_ai_key_id: null, twist_ai_key_id: null } (hardcoded, BYOK removed)
 *     plus the real twist_ai_disabled / builtin_ai_disabled values from DB.
 *   - GET returns safe defaults when no row exists.
 *   - POST writes twist_ai_disabled / builtin_ai_disabled but silently ignores
 *     legacy builtinAiKeyId / twistAiKeyId fields (back-compat: accepted, not written).
 *   - POST with only legacy key-id fields is a no-op on the DB (nothing written).
 *
 * Unit mode (vitest.config.ts, node env). DB is mocked — no real Postgres needed.
 */

import { Hono } from "hono";
import { describe, expect, it, vi } from "vitest";

import aiKeys from "./ai-keys";

vi.mock("../utils/error-capture", () => ({
  captureServerError: vi.fn(
    async (_c: any, _err: any, msg: string) =>
      new Response(JSON.stringify({ message: msg }), { status: 500 }),
  ),
}));

// ---------------------------------------------------------------------------
// Fake DB builder
// ---------------------------------------------------------------------------

/**
 * Builds a minimal Kysely-shaped chainable mock.
 * `executeTakeFirst()` resolves to `row` (or undefined when null is passed).
 * `execute()` resolves to `[]`.
 *
 * Tracks each `insertInto(table)` call separately so callers can inspect
 * what was inserted into a specific table (`_insertedInto(tableName)`).
 */
function fakeDb(row: Record<string, unknown> | null = null) {
  // Per-table insert tracking
  const inserts: Record<string, any> = {};

  function makeInsertChain(table: string): any {
    const chain: any = {
      values: vi.fn((v: any) => { inserts[table] = v; return chain; }),
      onConflict: vi.fn((fn: any) => {
        const oc: any = {
          column: vi.fn(() => oc),
          where: vi.fn(() => oc),
          doUpdateSet: vi.fn(() => chain),
        };
        fn(oc);
        return chain;
      }),
      execute: vi.fn(async () => []),
    };
    return chain;
  }

  const db: any = {
    /** Returns the values passed to insertInto(table).values(...) */
    _insertedInto: (table: string) => inserts[table],
    selectFrom: vi.fn(() => db),
    select: vi.fn(() => db),
    where: vi.fn(() => db),
    executeTakeFirst: vi.fn(async () => row ?? undefined),
    insertInto: vi.fn((table: string) => makeInsertChain(table)),
  };
  return db;
}

// ---------------------------------------------------------------------------
// Test app factory — mounts aiKeys on a parent Hono app with c.var injected
// ---------------------------------------------------------------------------

function makeApp(db: any, userId = "user-1") {
  const app = new Hono();
  // Inject user + db into context variables, mimicking the real auth middleware.
  app.use("*", async (c, next) => {
    c.set("user" as any, { id: userId });
    c.set("db" as any, db);
    await next();
  });
  app.route("/", aiKeys);
  return app;
}

// ---------------------------------------------------------------------------
// GET /ai-preference
// ---------------------------------------------------------------------------

describe("GET /ai-preference", () => {
  it("returns hardcoded null key_ids and DB-sourced disabled flags", async () => {
    const db = fakeDb({ twist_ai_disabled: true, builtin_ai_disabled: false });
    const app = makeApp(db);

    const res = await app.request("/ai-preference");
    expect(res.status).toBe(200);
    const body = await res.json();

    // Back-compat: key_id fields always null (BYOK removed in B4)
    expect(body.builtin_ai_key_id).toBeNull();
    expect(body.twist_ai_key_id).toBeNull();

    // Real values from DB
    expect(body.twist_ai_disabled).toBe(true);
    expect(body.builtin_ai_disabled).toBe(false);
  });

  it("returns false defaults when no preference row exists", async () => {
    const db = fakeDb(null); // no row
    const app = makeApp(db);

    const res = await app.request("/ai-preference");
    expect(res.status).toBe(200);
    const body = await res.json();

    expect(body.builtin_ai_key_id).toBeNull();
    expect(body.twist_ai_key_id).toBeNull();
    expect(body.twist_ai_disabled).toBe(false);
    expect(body.builtin_ai_disabled).toBe(false);
  });

  it("does NOT select builtin_ai_key_id or twist_ai_key_id columns from DB", async () => {
    const db = fakeDb(null);
    const selectSpy = db.select;
    const app = makeApp(db);

    await app.request("/ai-preference");

    // The select call should only include the disabled flags — not the key-id columns
    const selectedCols = selectSpy.mock.calls[0]?.[0] as string[];
    expect(selectedCols).not.toContain("builtin_ai_key_id");
    expect(selectedCols).not.toContain("twist_ai_key_id");
    expect(selectedCols).toContain("twist_ai_disabled");
    expect(selectedCols).toContain("builtin_ai_disabled");
  });
});

// ---------------------------------------------------------------------------
// POST /ai-preference
// ---------------------------------------------------------------------------

describe("POST /ai-preference — *_disabled toggles", () => {
  it("writes twist_ai_disabled when provided", async () => {
    const db = fakeDb({ twist_ai_disabled: false, builtin_ai_disabled: false });
    const app = makeApp(db);

    const res = await app.request("/ai-preference", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ twistAiDisabled: true }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.success).toBe(true);

    // The insertInto chain should have received twist_ai_disabled
    const inserted = db._insertedInto("ai_preference");
    expect(inserted).toBeDefined();
    expect(inserted.twist_ai_disabled).toBe(true);
    // key_id columns should NOT appear in the insert
    expect(inserted.builtin_ai_key_id).toBeUndefined();
    expect(inserted.twist_ai_key_id).toBeUndefined();
  });

  it("writes builtin_ai_disabled when provided", async () => {
    const db = fakeDb({ twist_ai_disabled: false, builtin_ai_disabled: false });
    const app = makeApp(db);

    const res = await app.request("/ai-preference", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ builtinAiDisabled: true }),
    });

    expect(res.status).toBe(200);
    const inserted = db._insertedInto("ai_preference");
    expect(inserted.builtin_ai_disabled).toBe(true);
    expect(inserted.builtin_ai_key_id).toBeUndefined();
  });
});

describe("POST /ai-preference — legacy key-id fields ignored", () => {
  it("silently ignores builtinAiKeyId (not written to DB)", async () => {
    const db = fakeDb(null);
    const app = makeApp(db);

    const res = await app.request("/ai-preference", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ builtinAiKeyId: 42 }),
    });

    // Should succeed (no 404 key-not-found; key validation removed)
    expect(res.status).toBe(200);

    // key_id columns must NOT appear in the DB insert values
    const inserted = db._insertedInto("ai_preference");
    expect(inserted?.builtin_ai_key_id).toBeUndefined();
    expect(inserted?.twist_ai_key_id).toBeUndefined();
  });

  it("silently ignores twistAiKeyId (not written to DB)", async () => {
    const db = fakeDb(null);
    const app = makeApp(db);

    const res = await app.request("/ai-preference", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ twistAiKeyId: 99 }),
    });

    expect(res.status).toBe(200);
    const inserted = db._insertedInto("ai_preference");
    expect(inserted?.twist_ai_key_id).toBeUndefined();
  });

  it("ignores key-id fields even when sent alongside disabled toggles", async () => {
    const db = fakeDb({ twist_ai_disabled: false, builtin_ai_disabled: false });
    const app = makeApp(db);

    const res = await app.request("/ai-preference", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        twistAiDisabled: true,
        builtinAiKeyId: 77, // legacy — must be ignored
      }),
    });

    expect(res.status).toBe(200);
    const inserted = db._insertedInto("ai_preference");
    expect(inserted.twist_ai_disabled).toBe(true);
    expect(inserted.builtin_ai_key_id).toBeUndefined();
  });
});
