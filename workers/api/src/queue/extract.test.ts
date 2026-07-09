import { beforeEach, describe, expect, it, vi } from "vitest";

import { processExtractions } from "./extract";
import type { ExtractMessage } from "../env";

// Mocks are hoisted by vitest; the imports above still run after the mock
// factories register, so the module-under-test sees the mocked deps.

const extractMarkdownMock = vi.fn();
vi.mock("../extract/extractor", () => ({
  extractMarkdown: (...args: unknown[]) => extractMarkdownMock(...args),
  PARTIAL_CONVERSION_PREFIX: "Partial conversion completed with errors",
  MIN_MARKDOWN_LENGTH: 200,
}));

const renderHtmlWithBrowserMock = vi.fn();
vi.mock("../extract/browser", () => ({
  // Browser Rendering is treated as configured iff env.BROWSER is bound.
  getBrowserBinding: (env: any) => env?.BROWSER ?? null,
  renderHtmlWithBrowser: (...args: unknown[]) =>
    renderHtmlWithBrowserMock(...args),
  BrowserRenderingError: class extends Error {
    constructor(msg: string) {
      super(msg);
      this.name = "BrowserRenderingError";
    }
  },
}));

const fulfillArticleInjectionMock = vi.fn();
vi.mock("../extract/inject", () => ({
  fulfillArticleInjection: (...args: unknown[]) =>
    fulfillArticleInjectionMock(...args),
}));

type DbCall = { kind: string; args: unknown };
let dbCalls: DbCall[];
let claimableIds: Set<string>;

function makeFakeDb() {
  const builder: any = {
    _table: "",
    _setValues: undefined,
    _whereId: undefined,
    _whereStatus: undefined,
    set(values: unknown) {
      this._setValues = values;
      return this;
    },
    where(col: string, _op: string, val: unknown) {
      if (col === "id") this._whereId = val;
      else if (col === "status") this._whereStatus = val;
      return this;
    },
    returning() {
      return this;
    },
    async executeTakeFirst() {
      dbCalls.push({
        kind: "claim",
        args: { id: this._whereId, status: this._whereStatus, set: this._setValues },
      });
      // Only the first UPDATE in runOne calls executeTakeFirst (the claim).
      // Honour the claimable set so tests can simulate already-claimed rows.
      if (
        Array.isArray(this._whereStatus) &&
        claimableIds.has(String(this._whereId))
      ) {
        return { id: String(this._whereId) };
      }
      return undefined;
    },
    async execute() {
      dbCalls.push({
        kind: "update",
        args: { id: this._whereId, set: this._setValues },
      });
    },
  };
  return {
    updateTable() {
      return Object.create(builder);
    },
    async destroy() {},
  };
}

vi.mock("../db", () => ({
  createDb: () => makeFakeDb(),
}));

// ── Test helpers ────────────────────────────────────────────────────────────

type StoredR2 = {
  key: string;
  body: Uint8Array;
  contentType?: string;
  customMetadata?: Record<string, string>;
};

function makeR2(): { put: ReturnType<typeof vi.fn>; objects: StoredR2[] } {
  const objects: StoredR2[] = [];
  const put = vi.fn(async (key: string, body: Uint8Array, opts: any) => {
    objects.push({
      key,
      body,
      contentType: opts?.httpMetadata?.contentType,
      customMetadata: opts?.customMetadata,
    });
  });
  return { put, objects };
}

function makeMessage(body: Partial<ExtractMessage>): {
  body: ExtractMessage;
  ack: ReturnType<typeof vi.fn>;
  retry: ReturnType<typeof vi.fn>;
} {
  return {
    body: {
      type: "extract",
      id: 1,
      url: "https://example.com/article",
      urlHash: "deadbeef".repeat(8),
      ...body,
    },
    ack: vi.fn(),
    retry: vi.fn(),
  };
}

function makeEnv(
  r2: ReturnType<typeof makeR2>,
  withBrowser = false
): any {
  const env: any = { ARTICLES_BUCKET: { put: r2.put } };
  if (withBrowser) {
    // Tests don't drive the binding themselves — renderHtmlWithBrowser is
    // mocked above — but the `getBrowserBinding` shim only requires that
    // env.BROWSER be truthy to claim the binding is configured.
    env.BROWSER = { fetch: vi.fn() };
  }
  return env;
}

const fakeCtx = {} as any;
const fakePostHog = { captureException: vi.fn() } as any;

const longBody = "x".repeat(500);

beforeEach(() => {
  dbCalls = [];
  claimableIds = new Set(["1"]);
  extractMarkdownMock.mockReset();
  renderHtmlWithBrowserMock.mockReset();
  fulfillArticleInjectionMock.mockReset();
  fakePostHog.captureException.mockReset();
  vi.unstubAllGlobals();
});

// ── Tests ───────────────────────────────────────────────────────────────────

describe("processExtractions", () => {
  it("happy path: claims, fetches, extracts, writes R2, marks completed", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html>hi</html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "Hello",
      author: "Ada",
      description: "A page",
      md: `# Hello\n\n${longBody}`,
    });

    const r2 = makeR2();
    const msg = makeMessage({ id: 1, urlHash: "abc" });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(fakePostHog.captureException).not.toHaveBeenCalled();
    expect(r2.objects).toHaveLength(1);
    expect(r2.objects[0].key).toBe("abc.md");
    expect(r2.objects[0].contentType).toBe("text/markdown; charset=utf-8");
    expect(r2.objects[0].customMetadata?.url).toBe(
      "https://example.com/article"
    );

    const completed = dbCalls.find(
      (c) =>
        c.kind === "update" &&
        (c.args as any).set?.status === "completed"
    );
    expect(completed).toBeDefined();
    expect((completed!.args as any).set.title).toBe("Hello");
    expect((completed!.args as any).set.r2_key).toBe("abc.md");
    expect((completed!.args as any).set.byte_size).toBeGreaterThan(0);
  });

  it("fulfills waiting article injections after a completed extraction", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html>hi</html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "Hello",
      author: "",
      description: "",
      md: `# Hello\n\n${longBody}`,
    });
    const r2 = makeR2();
    const msg = makeMessage({ id: 1, urlHash: "abc" });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(fulfillArticleInjectionMock).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      "abc"
    );
  });

  it("marks row failed when fetch is non-2xx, no R2 write", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("nope", { status: 503 }))
    );

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(r2.objects).toHaveLength(0);
    expect(extractMarkdownMock).not.toHaveBeenCalled();

    const failed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "failed"
    );
    expect(failed).toBeDefined();
    expect((failed!.args as any).set.error_code).toBe("fetch_failed");
    // ExtractionFailure is expected — should NOT page PostHog.
    expect(fakePostHog.captureException).not.toHaveBeenCalled();
  });

  it("marks row failed when extracted markdown is below the length floor", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html></html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "",
      author: "",
      description: "",
      md: "tiny",
    });

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(r2.objects).toHaveLength(0);
    const failed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "failed"
    );
    expect((failed!.args as any).set.error_code).toBe("content_too_short");
  });

  it("marks row failed when defuddle reports a partial Turndown conversion", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html></html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "X",
      author: "",
      description: "",
      md:
        "Partial conversion completed with errors. Original HTML:\n\n" +
        "x".repeat(500),
    });

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(r2.objects).toHaveLength(0);
    const failed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "failed"
    );
    expect((failed!.args as any).set.error_code).toBe("partial_conversion");
  });

  it("falls back to browser rendering when raw HTML is too short and config is present", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html><body></body></html>", { status: 200 }))
    );
    // First call: raw HTML → too short. Second call: browser HTML → success.
    extractMarkdownMock
      .mockReturnValueOnce({ title: "", author: "", description: "", md: "tiny" })
      .mockReturnValueOnce({
        title: "Hello",
        author: "",
        description: "",
        md: `# Hello\n\n${longBody}`,
      });
    renderHtmlWithBrowserMock.mockResolvedValue("<html>rendered</html>");

    const r2 = makeR2();
    const msg = makeMessage({ id: 1, urlHash: "abc" });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2, /* withBrowser */ true),
      fakeCtx,
      fakePostHog
    );

    expect(renderHtmlWithBrowserMock).toHaveBeenCalledOnce();
    expect(extractMarkdownMock).toHaveBeenCalledTimes(2);
    expect(r2.objects).toHaveLength(1);
    expect(r2.objects[0].customMetadata?.renderedWith).toBe("browser");

    const completed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "completed"
    );
    expect(completed).toBeDefined();
    expect((completed!.args as any).set.title).toBe("Hello");
    expect(fakePostHog.captureException).not.toHaveBeenCalled();
  });

  it("records renderedWith: 'raw' on the happy path", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html>hi</html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "Hello",
      author: "",
      description: "",
      md: `# Hello\n\n${longBody}`,
    });

    const r2 = makeR2();
    const msg = makeMessage({ id: 1, urlHash: "abc" });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2, /* withBrowser */ true),
      fakeCtx,
      fakePostHog
    );

    expect(r2.objects[0].customMetadata?.renderedWith).toBe("raw");
    expect(renderHtmlWithBrowserMock).not.toHaveBeenCalled();
  });

  it("skips the browser fallback when Browser Rendering is not configured", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html></html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "",
      author: "",
      description: "",
      md: "tiny",
    });

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2, /* withBrowser */ false),
      fakeCtx,
      fakePostHog
    );

    expect(renderHtmlWithBrowserMock).not.toHaveBeenCalled();
    expect(r2.objects).toHaveLength(0);
    const failed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "failed"
    );
    expect((failed!.args as any).set.error_code).toBe("content_too_short");
  });

  it("marks browser_render_failed when raw is short and the browser call throws", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html></html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "",
      author: "",
      description: "",
      md: "tiny",
    });
    renderHtmlWithBrowserMock.mockRejectedValue(
      new Error("upstream Browser Rendering 502")
    );

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2, /* withBrowser */ true),
      fakeCtx,
      fakePostHog
    );

    expect(r2.objects).toHaveLength(0);
    const failed = dbCalls.find(
      (c) => c.kind === "update" && (c.args as any).set?.status === "failed"
    );
    expect((failed!.args as any).set.error_code).toBe("browser_render_failed");
    expect((failed!.args as any).set.error_message).toMatch(/Browser Rendering/);
    // ExtractionFailure → expected, not paged.
    expect(fakePostHog.captureException).not.toHaveBeenCalled();
  });

  it("maps HTTP 401 to terminal status 'auth_required' (not 'failed')", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("Sign in", { status: 401 }))
    );

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(r2.objects).toHaveLength(0);
    expect(extractMarkdownMock).not.toHaveBeenCalled();

    const update = dbCalls.find(
      (c) =>
        c.kind === "update" &&
        (c.args as any).set?.status === "auth_required"
    );
    expect(update, "expected a status='auth_required' update").toBeDefined();
    expect((update!.args as any).set.error_code).toBe("http_401");
    // Auth-restricted is a known terminal outcome, not a bug — don't page.
    expect(fakePostHog.captureException).not.toHaveBeenCalled();
  });

  it("maps HTTP 403 to terminal status 'auth_required'", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("forbidden", { status: 403 }))
    );

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    const update = dbCalls.find(
      (c) =>
        c.kind === "update" &&
        (c.args as any).set?.status === "auth_required"
    );
    expect(update).toBeDefined();
    expect((update!.args as any).set.error_code).toBe("http_403");
  });

  it("skips and does not write R2 when the row is not claimable", async () => {
    claimableIds = new Set(); // nothing is claimable
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const r2 = makeR2();
    const msg = makeMessage({ id: 1 });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(extractMarkdownMock).not.toHaveBeenCalled();
    expect(r2.objects).toHaveLength(0);
  });
});
