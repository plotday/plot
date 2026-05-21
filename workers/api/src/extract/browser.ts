import puppeteer from "@cloudflare/puppeteer";

import type { Bindings } from "../env";

export class BrowserRenderingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BrowserRenderingError";
  }
}

/**
 * Returns the `BROWSER` Fetcher binding if it's configured for this worker,
 * otherwise `null`. The queue consumer uses this to gate the fallback —
 * environments without Browser Rendering configured skip the retry and
 * mark the row failed with the original `content_too_short` code.
 */
export function getBrowserBinding(env: Bindings): Fetcher | null {
  return env.BROWSER ?? null;
}

/** Browser-Rendering navigation cap; SPAs sometimes idle into this. */
const NAV_TIMEOUT_MS = 45_000;

/**
 * Drive Cloudflare Browser Rendering through the `@cloudflare/puppeteer`
 * binding to fetch a fully-rendered HTML snapshot of `url`. Sessions are
 * billed per launch, so callers should only invoke this as a fallback after
 * the raw-HTML path produces unusable output.
 *
 * Returns the serialized DOM. Throws `BrowserRenderingError` on any
 * navigation or rendering failure — the queue consumer maps that to a
 * `browser_render_failed` row state.
 */
export async function renderHtmlWithBrowser(
  binding: Fetcher,
  url: string
): Promise<string> {
  let browser: Awaited<ReturnType<typeof puppeteer.launch>> | undefined;
  try {
    browser = await puppeteer.launch(binding);
    const page = await browser.newPage();
    // Drop cosmetic resources so the session ends faster. defuddle only
    // consumes the serialized HTML; images/fonts/stylesheets/media are
    // wasted browser time and bandwidth for us.
    await page.setRequestInterception(true);
    page.on("request", (req) => {
      const type = req.resourceType();
      if (
        type === "image" ||
        type === "stylesheet" ||
        type === "font" ||
        type === "media"
      ) {
        void req.abort();
      } else {
        void req.continue();
      }
    });
    await page.goto(url, {
      waitUntil: "networkidle0",
      timeout: NAV_TIMEOUT_MS,
    });
    return await page.content();
  } catch (e) {
    throw new BrowserRenderingError(
      e instanceof Error ? e.message : String(e)
    );
  } finally {
    if (browser) {
      try {
        await browser.close();
      } catch {
        // Closing a dead session can throw — we're already past the work,
        // so swallow the secondary failure rather than mask the original.
      }
    }
  }
}
