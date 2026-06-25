import { beforeEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import filesApp from "./files";

const rpcUserMock = vi.fn(async () => true);
vi.mock("../rpc", () => ({
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  rpcUser: (...args: unknown[]) => (rpcUserMock as (...a: unknown[]) => unknown)(...args),
}));

const TEST_USER_ID = "user-uuid-001";
const TEST_FILE_ID = "file-uuid-001";
const OBJECT_KEY = `files/${TEST_FILE_ID}/photo.png`;

// Chainable Kysely-like builder resolving to `row` on executeTakeFirst().
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

const transformMock = vi.fn();
const outputMock = vi.fn();

function makeEnv(opts: {
  object?: { contentType?: string; bytes?: Uint8Array; priorityId?: string } | null;
  variantBytes?: Uint8Array;
  variantContentType?: string;
  transformThrows?: boolean;
} = {}) {
  const objectBytes =
    opts.object === null ? null : (opts.object?.bytes ?? new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
  const object =
    opts.object === null
      ? null
      : {
          body: objectBytes,
          arrayBuffer: async () => objectBytes!.buffer,
          httpMetadata: { contentType: opts.object?.contentType ?? "image/png" },
          customMetadata: { priorityId: opts.object?.priorityId ?? "priority-001" },
        };

  const FILES_BUCKET = {
    list: vi.fn(async () => ({ objects: object ? [{ key: OBJECT_KEY }] : [] })),
    get: vi.fn(async () => object),
  };

  // input(stream) -> transformer with chainable transform() and async output()
  const transformer: any = {};
  transformer.transform = transformMock.mockImplementation(() => transformer);
  transformer.output = outputMock.mockImplementation(async () => {
    if (opts.transformThrows) throw new Error("transform failed");
    const bytes = opts.variantBytes ?? new Uint8Array([1, 2, 3]);
    const ct = opts.variantContentType ?? "image/webp";
    return {
      response: () => new Response(bytes, { headers: { "Content-Type": ct } }),
      contentType: () => ct,
      image: () => null,
    };
  });
  const inputMock = vi.fn(() => transformer);
  const IMAGES = { input: inputMock };

  return { FILES_BUCKET, IMAGES, _inputMock: inputMock };
}

const captureExceptionMock = vi.fn();

async function get(
  path: string,
  ctx: { user: { id: string } | null; db: any; tracker?: any },
  env: any = {},
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
  return app.fetch(req, env, { waitUntil: () => {}, passThroughOnException: () => {} } as any);
}

describe("GET /files/:fileId with ?w (image preview)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    rpcUserMock.mockResolvedValue(true);
  });

  it("returns a webp variant smaller than the original when ?w is present", async () => {
    const env = makeEnv({});
    const res = await get(`/files/${TEST_FILE_ID}?w=800`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/webp");
    expect(res.headers.get("Content-Disposition")).toBe("inline");
    const buf = new Uint8Array(await res.arrayBuffer());
    expect(buf).toEqual(new Uint8Array([1, 2, 3])); // smaller than the 10-byte original
    expect(env._inputMock).toHaveBeenCalledTimes(1);
    expect(transformMock).toHaveBeenCalledWith(
      expect.objectContaining({ width: 800, height: 800, fit: "scale-down" }),
    );
    expect(outputMock).toHaveBeenCalledWith(
      expect.objectContaining({ format: "image/webp", quality: 80 }),
    );
  });

  it("returns the original (attachment) when ?w is absent", async () => {
    const env = makeEnv({});
    const res = await get(`/files/${TEST_FILE_ID}`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/png");
    expect(res.headers.get("Content-Disposition")).toMatch(/attachment/);
    const buf = new Uint8Array(await res.arrayBuffer());
    expect(buf.length).toBe(10);
    expect(env._inputMock).not.toHaveBeenCalled();
  });

  it("returns 403 and never transforms when access is denied", async () => {
    rpcUserMock.mockResolvedValue(false);
    const env = makeEnv({});
    const res = await get(`/files/${TEST_FILE_ID}?w=800`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env);

    expect(res.status).toBe(403);
    expect(env._inputMock).not.toHaveBeenCalled();
  });

  it("falls back to the original for a non-image object with ?w", async () => {
    const env = makeEnv({ object: { contentType: "application/pdf" } });
    const res = await get(`/files/${TEST_FILE_ID}?w=800`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/pdf");
    expect(res.headers.get("Content-Disposition")).toMatch(/attachment/);
    expect(env._inputMock).not.toHaveBeenCalled();
  });

  it("falls back to the original and captures when the transform throws", async () => {
    const env = makeEnv({ transformThrows: true });
    const res = await get(`/files/${TEST_FILE_ID}?w=800`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
      tracker: { captureException: captureExceptionMock },
    }, env);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/png");
    expect(captureExceptionMock).toHaveBeenCalledWith(
      expect.any(Error),
      expect.objectContaining({ context: "files:image-transform" }),
    );
    // Fallback must serve the complete original bytes (not a consumed/empty stream)
    const buf = new Uint8Array(await res.arrayBuffer());
    expect(buf).toEqual(new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));
  });

  it("clamps ?w to the nearest allowed bucket", async () => {
    const env = makeEnv({});
    await get(`/files/${TEST_FILE_ID}?w=600`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env);
    expect(transformMock).toHaveBeenCalledWith(expect.objectContaining({ width: 800 }));

    transformMock.mockClear();
    const env2 = makeEnv({});
    await get(`/files/${TEST_FILE_ID}?w=100`, {
      user: { id: TEST_USER_ID },
      db: makeDb({ priority_id: "priority-001" }),
    }, env2);
    expect(transformMock).toHaveBeenCalledWith(expect.objectContaining({ width: 400 }));
  });

  it("returns 404 when the object is missing and not attached to a note", async () => {
    const env = makeEnv({ object: null });
    const res = await get(`/files/${TEST_FILE_ID}?w=800`, {
      user: { id: TEST_USER_ID },
      db: makeDb(undefined),
    }, env);
    expect(res.status).toBe(404);
  });
});
