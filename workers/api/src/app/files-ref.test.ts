import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import filesApp from "./files";

/**
 * Tests for GET /files/ref/:noteId/:actionIndex
 *
 * The handler lives in files.ts and is tested here by mocking:
 *   - `../twist/factory` (twistFactory → runConnectorMethod)
 *   - The Kysely `c.var.db` chain (via a fake db builder)
 *   - `../rpc` (rpcUser)
 *
 * vi.mock calls are hoisted by vitest before module evaluation, so filesApp
 * above sees the mocked dependencies even though vi.mock is declared here.
 */

// ---- Mock implementations ----

const runConnectorMethodMock = vi.fn();
const twistWrapperMock = { runConnectorMethod: runConnectorMethodMock };
const factoryInnerMock = vi.fn(async () => twistWrapperMock);
const rpcUserMock = vi.fn(async () => true);

vi.mock("../twist/factory", () => ({
  // twistFactory returns an inner factory function that returns the wrapper
  twistFactory: () => factoryInnerMock,
}));

vi.mock("../rpc", () => ({
  rpcUser: (...args: unknown[]) => rpcUserMock(...args),
}));

// ---- Helpers ----

const TEST_USER_ID = "user-uuid-001";
const TEST_NOTE_ID = "note-uuid-001";
const TEST_TWIST_INSTANCE_ID = "ti-uuid-001";

/**
 * Build a chainable Kysely-like query builder that resolves to `row` on
 * `executeTakeFirst()`.
 */
function makeDb(row: unknown) {
  const q: any = {};
  q.selectFrom = vi.fn(() => q);
  q.innerJoin = vi.fn(() => q);
  q.leftJoin = vi.fn(() => q);
  q.select = vi.fn(() => q);
  q.where = vi.fn(() => q);
  q.executeTakeFirst = vi.fn(async () => row);
  return q;
}

const captureExceptionMock = vi.fn();

/**
 * Issue a GET request to the Hono app with synthetic c.var bindings injected
 * via a plain middleware before the route handlers run.
 */
async function get(
  path: string,
  ctx: { user: { id: string } | null; db: any; tracker?: any },
) {
  const app = new Hono<{ Bindings: any }>();

  app.use("*", async (c, next) => {
    (c as any).set("user", ctx.user);
    (c as any).set("db", ctx.db);
    (c as any).set("tracker", ctx.tracker ?? null);
    await next();
  });

  app.route("/", filesApp);

  const req = new Request(`http://localhost${path}`);
  return app.fetch(
    req,
    {},
    { waitUntil: () => {}, passThroughOnException: () => {} } as any,
  );
}

// ---- Tests ----

describe("GET /files/ref/:noteId/:actionIndex", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    rpcUserMock.mockResolvedValue(true);
    factoryInnerMock.mockResolvedValue(twistWrapperMock);
  });

  it("returns 401 when no user is authenticated", async () => {
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, {
      user: null,
      db: makeDb(null),
    });
    expect(res.status).toBe(401);
  });

  it("returns 400 when actionIndex is not a non-negative integer", async () => {
    const ctx = { user: { id: TEST_USER_ID }, db: makeDb(null) };
    const resNeg = await get(`/files/ref/${TEST_NOTE_ID}/-1`, ctx);
    expect(resNeg.status).toBe(400);

    const resFloat = await get(`/files/ref/${TEST_NOTE_ID}/1.5`, ctx);
    expect(resFloat.status).toBe(400);

    const resStr = await get(`/files/ref/${TEST_NOTE_ID}/abc`, ctx);
    expect(resStr.status).toBe(400);
  });

  it("returns 404 when note row is not found", async () => {
    const ctx = { user: { id: TEST_USER_ID }, db: makeDb(undefined) };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);
    expect(res.status).toBe(404);
  });

  it("returns 403 when user has no priority access", async () => {
    rpcUserMock.mockResolvedValue(false);
    const noteRow = {
      actions: [{ type: "fileRef", ref: "r1", fileName: "doc.pdf", mimeType: "application/pdf" }],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);
    expect(res.status).toBe(403);
  });

  it("returns 400 when action at index does not exist", async () => {
    const noteRow = {
      actions: [],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.message).toMatch(/not found at index/i);
  });

  it("returns 400 when action type is not fileRef", async () => {
    const noteRow = {
      actions: [{ type: "file", fileId: "f1", fileName: "image.png", mimeType: "image/png", fileSize: 100 }],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.message).toMatch(/not a fileRef/i);
  });

  it("returns 410 when twistInstanceId is null (orphaned fileRef)", async () => {
    const noteRow = {
      actions: [{ type: "fileRef", ref: "r1", fileName: "doc.pdf", mimeType: "application/pdf" }],
      priority_id: "priority-001",
      twistInstanceId: null,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);
    expect(res.status).toBe(410);
  });

  it("returns 302 with Location and Content-Disposition for redirectUrl result", async () => {
    const redirectUrl = "https://cdn.example.com/signed/doc.pdf";
    runConnectorMethodMock.mockResolvedValue({ redirectUrl });

    const noteRow = {
      actions: [{ type: "fileRef", ref: "r1", fileName: "doc.pdf", mimeType: "application/pdf" }],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);

    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toBe(redirectUrl);
    expect(res.headers.get("Content-Disposition")).toMatch(/attachment/);
    expect(res.headers.get("Content-Disposition")).toMatch(/doc\.pdf/);
    expect(runConnectorMethodMock).toHaveBeenCalledWith("downloadAttachment", "r1");
  });

  it("returns 200 with body and headers for body result", async () => {
    const bodyBytes = new Uint8Array([1, 2, 3]);
    runConnectorMethodMock.mockResolvedValue({
      body: bodyBytes,
      mimeType: "application/pdf",
    });

    const noteRow = {
      actions: [{ type: "fileRef", ref: "r2", fileName: "report.pdf", mimeType: "application/pdf" }],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/pdf");
    expect(res.headers.get("Content-Disposition")).toMatch(/attachment/);
    expect(res.headers.get("Content-Disposition")).toMatch(/report\.pdf/);
    const buf = await res.arrayBuffer();
    expect(new Uint8Array(buf)).toEqual(bodyBytes);
  });

  it("returns 502 and calls captureException when runConnectorMethod throws", async () => {
    runConnectorMethodMock.mockRejectedValue(new Error("Source API error"));

    const noteRow = {
      actions: [{ type: "fileRef", ref: "r3", fileName: "fail.pdf", mimeType: "application/pdf" }],
      priority_id: "priority-001",
      twistInstanceId: TEST_TWIST_INSTANCE_ID,
    };
    const ctx = {
      user: { id: TEST_USER_ID },
      db: makeDb(noteRow),
      tracker: { captureException: captureExceptionMock },
    };
    const res = await get(`/files/ref/${TEST_NOTE_ID}/0`, ctx);

    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.message).toMatch(/unavailable/i);
    expect(captureExceptionMock).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({ context: "files:ref" }),
    );
  });
});
