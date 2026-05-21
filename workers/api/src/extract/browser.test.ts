import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { Bindings } from "../env";
import {
  BrowserRenderingError,
  getBrowserBinding,
  renderHtmlWithBrowser,
} from "./browser";

// ── Mocks ───────────────────────────────────────────────────────────────────
// vi.mock factories are hoisted by vitest, so the imports above still resolve
// to the mocked module at test time.

// Track what puppeteer-driven calls happen, and let tests script the outcome.
const launchMock = vi.fn();
const closeMock = vi.fn();
const newPageMock = vi.fn();
const gotoMock = vi.fn();
const contentMock = vi.fn();
const setRequestInterceptionMock = vi.fn();
const requestHandlers: ((req: any) => void)[] = [];

function resetMocks() {
  launchMock.mockReset();
  closeMock.mockReset();
  newPageMock.mockReset();
  gotoMock.mockReset();
  contentMock.mockReset();
  setRequestInterceptionMock.mockReset();
  requestHandlers.length = 0;

  // Default: a working browser session.
  contentMock.mockResolvedValue("<html>rendered</html>");
  gotoMock.mockResolvedValue(undefined);
  setRequestInterceptionMock.mockResolvedValue(undefined);
  closeMock.mockResolvedValue(undefined);

  const page = {
    setRequestInterception: setRequestInterceptionMock,
    on: (event: string, cb: (req: any) => void) => {
      if (event === "request") requestHandlers.push(cb);
    },
    goto: gotoMock,
    content: contentMock,
  };
  newPageMock.mockResolvedValue(page);
  launchMock.mockResolvedValue({
    newPage: newPageMock,
    close: closeMock,
  });
}

vi.mock("@cloudflare/puppeteer", () => ({
  default: {
    launch: (...args: unknown[]) => launchMock(...args),
  },
}));

beforeEach(resetMocks);
afterEach(() => {
  vi.restoreAllMocks();
});

// ── Tests ───────────────────────────────────────────────────────────────────

describe("getBrowserBinding", () => {
  it("returns null when BROWSER is not bound", () => {
    expect(getBrowserBinding({} as Bindings)).toBeNull();
  });

  it("returns the binding when it is present", () => {
    const fake = { fetch: vi.fn() } as unknown as Fetcher;
    const result = getBrowserBinding({ BROWSER: fake } as unknown as Bindings);
    expect(result).toBe(fake);
  });
});

describe("renderHtmlWithBrowser", () => {
  const binding = { fetch: vi.fn() } as unknown as Fetcher;

  it("launches the browser, navigates, returns rendered HTML, then closes", async () => {
    const html = await renderHtmlWithBrowser(binding, "https://example.com/x");

    expect(html).toBe("<html>rendered</html>");
    expect(launchMock).toHaveBeenCalledOnce();
    expect(launchMock).toHaveBeenCalledWith(binding);
    expect(gotoMock).toHaveBeenCalledWith(
      "https://example.com/x",
      expect.objectContaining({ waitUntil: "networkidle0" })
    );
    expect(closeMock).toHaveBeenCalledOnce();
  });

  it("blocks cosmetic resource types via the request interceptor", async () => {
    await renderHtmlWithBrowser(binding, "https://example.com/x");

    expect(setRequestInterceptionMock).toHaveBeenCalledWith(true);
    // We registered exactly one request handler. Drive a few synthetic
    // requests through it to confirm the policy.
    const handler = requestHandlers[0];
    expect(handler).toBeDefined();

    const cases: { type: string; expect: "abort" | "continue" }[] = [
      { type: "image", expect: "abort" },
      { type: "stylesheet", expect: "abort" },
      { type: "font", expect: "abort" },
      { type: "media", expect: "abort" },
      { type: "document", expect: "continue" },
      { type: "script", expect: "continue" },
      { type: "xhr", expect: "continue" },
    ];

    for (const c of cases) {
      const abort = vi.fn();
      const cont = vi.fn();
      handler({
        resourceType: () => c.type,
        abort,
        continue: cont,
      });
      if (c.expect === "abort") {
        expect(abort, c.type).toHaveBeenCalledOnce();
        expect(cont, c.type).not.toHaveBeenCalled();
      } else {
        expect(cont, c.type).toHaveBeenCalledOnce();
        expect(abort, c.type).not.toHaveBeenCalled();
      }
    }
  });

  it("wraps goto failures in BrowserRenderingError and still closes", async () => {
    gotoMock.mockRejectedValue(new Error("ERR_TIMED_OUT"));

    await expect(
      renderHtmlWithBrowser(binding, "https://example.com/x")
    ).rejects.toThrow(BrowserRenderingError);
    await expect(
      renderHtmlWithBrowser(binding, "https://example.com/x")
    ).rejects.toThrow(/ERR_TIMED_OUT/);

    // Two failed attempts → two close attempts.
    expect(closeMock).toHaveBeenCalledTimes(2);
  });

  it("does not surface a secondary failure from browser.close()", async () => {
    gotoMock.mockRejectedValue(new Error("primary failure"));
    closeMock.mockRejectedValue(new Error("close blew up too"));

    await expect(
      renderHtmlWithBrowser(binding, "https://example.com/x")
    ).rejects.toThrow(/primary failure/);
  });
});
