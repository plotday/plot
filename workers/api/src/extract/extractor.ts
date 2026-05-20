// Browser-DOM shim required to run `defuddle` inside workerd. See
// docs/read-later-extraction.md for the full backstory — three globals are
// expected by defuddle's main entry and turndown's browser build, and they
// must be present BEFORE defuddle is imported. We use a dynamic import below
// to enforce that ordering (static imports hoist).
//
// Conditional assignment so the module is idempotent: in the workerd runtime
// none of these globals exist; in node-based tests (linkedom is the same
// package either way) some may already be set by other tests, and we
// shouldn't clobber them.
import { parseHTML, DOMParser as LDDOMParser } from "linkedom";

const g = globalThis as any;
if (!g.document) {
  const seed = parseHTML("<!doctype html><html><body></body></html>");
  g.document = seed.document;
}
if (!g.DOMParser) g.DOMParser = LDDOMParser;
if (!g.window) g.window = globalThis;
if (!g.getComputedStyle) {
  g.getComputedStyle = () => ({ getPropertyValue: () => "" });
}

// linkedom documents don't expose `document.styleSheets`, so defuddle's
// `_evaluateMediaQueries` step throws on the iterator call. Patch the
// per-document prototype to return an empty iterable.
function ensureStyleSheets(doc: any): void {
  if (doc && !doc.styleSheets) doc.styleSheets = [];
}
ensureStyleSheets(g.document);

const { default: Defuddle } = await import("defuddle");
// `defuddle/markdown` isn't in defuddle's package.json exports map, so we
// resolve it via the wrangler alias (see workers/api/wrangler.jsonc) and
// declare the surface we use locally — TypeScript otherwise routes the deep
// import back to the main entry, which doesn't expose createMarkdownContent.
const { createMarkdownContent } = (await import(
  "defuddle/markdown" as any
)) as {
  createMarkdownContent: (content: string, url: string) => string;
};

export type ExtractResult = {
  title: string;
  author: string;
  description: string;
  md: string;
};

/**
 * Run defuddle + the markdown converter against a raw HTML string. Both
 * defuddle.parse() and createMarkdownContent() are synchronous.
 */
export function extractMarkdown(url: string, html: string): ExtractResult {
  const { document } = parseHTML(html);
  ensureStyleSheets(document);
  const result = new Defuddle(document, { url }).parse();
  const md = createMarkdownContent(result.content, url);
  return {
    title: result.title ?? "",
    author: result.author ?? "",
    description: result.description ?? "",
    md,
  };
}

/**
 * Defuddle catches its own Turndown errors and returns a string starting
 * with this prefix. Treat as a soft failure — we have a partial conversion
 * that's not safe to surface as the article body.
 */
export const PARTIAL_CONVERSION_PREFIX =
  "Partial conversion completed with errors";

/**
 * Below this length, the extracted markdown almost certainly means we hit a
 * JS-rendered SPA or a bot interstitial — the article body never made it
 * into the raw HTML we fetched. See the research doc failure-mode table.
 */
export const MIN_MARKDOWN_LENGTH = 200;
