# Read-later HTML→Markdown extraction (Defuddle + linkedom in CF Workers)

Handoff notes for implementing the read-later scrape queue. Stack chosen after benchmarking five
libraries against eight representative articles — see conversation log for the comparison.

## Stack

- **`defuddle`** (main entry) — content extraction
- **`defuddle/markdown`** (deep-imported, see alias below) — HTML→markdown with custom Turndown
  rules (code-fence languages, citation footnotes, table handling, KaTeX, callouts)
- **`linkedom`** — DOM parser; workerd-compatible

Bundle: **~168 KiB gzipped**. Well under the 1 MiB free-tier limit.

## Do not use `defuddle/node`

It hardcodes JSDOM, which does not run in workerd. You will see
`TypeError: generatedInterface.install is not a function` at first request. The main `defuddle`
entry is intended for browsers, but works in workerd with the shims below.

## Required globals — shim BEFORE importing defuddle

Three things will explode without shims:

| Missing                                        | Used by                                             | Error                                     |
| ---------------------------------------------- | --------------------------------------------------- | ----------------------------------------- |
| `window.getComputedStyle`                      | `Defuddle.findTableBasedContent`                    | `e3.getComputedStyle is not a function`   |
| `document.styleSheets` (iterable)              | `Defuddle._evaluateMediaQueries`                    | `undefined is not iterable`               |
| `globalThis.document` + `globalThis.DOMParser` | Turndown's browser build inside `defuddle/markdown` | `ReferenceError: document is not defined` |

The shim — set globals first, then dynamic-import defuddle so the imports load after the globals
exist (static imports hoist and would run too early):

```ts
import { DOMParser as LDDOMParser, parseHTML } from "linkedom";

const seed = parseHTML("<!doctype html><html><body></body></html>");
globalThis.document = seed.document;
globalThis.DOMParser = LDDOMParser;
globalThis.window = globalThis;
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "" });

const { default: Defuddle } = await import("defuddle");
const { createMarkdownContent } = await import("defuddle/markdown");
```

The dynamic import only runs once at module load, not per request.

## Wrangler alias

`defuddle/markdown` is not in defuddle's `exports` map. Bundlers reject the deep import by default.
Add to the worker's `wrangler.toml`:

```toml
[alias]
"defuddle/markdown" = "./node_modules/defuddle/dist/markdown.js"
```

## Extract function

```ts
export function extract(url: string, html: string) {
  const { document } = parseHTML(html);
  const result = new Defuddle(document, { url }).parse();
  const md = createMarkdownContent(result.content, url);
  return {
    title: result.title, // string
    author: result.author, // string, often ""
    description: result.description, // string, often ""
    md, // string — full markdown
  };
}
```

`Defuddle.parse()` and `createMarkdownContent()` are both synchronous.

## Failure modes the queue must handle

1. **JS-rendered pages** (Next.js, modern SPAs): raw HTML has no article body. Defuddle returns ~60
   chars or throws. Stripe's blog and Cloudflare's blog both hit this. **Detect with
   `md.length < 200`** and either fall back to Browser Rendering or mark the job failed with a
   reason the UI can show.
2. **Bot-blocked / interstitial pages**: same `md.length < 200` check catches these. Consider
   retrying with a different User-Agent before giving up.
3. **`<table>`-layout sites** (Paul Graham's essays, very old web): without real `getComputedStyle`,
   Defuddle leaks some nav cruft into the output. Content is still present, just noisier. Tolerable;
   no detection needed.
4. **Defuddle throws**: `createMarkdownContent` catches its own Turndown errors and returns
   `"Partial conversion completed with errors. Original HTML:\n\n..."` — treat that prefix as a
   failure signal.
5. **Fetches**: send a real `User-Agent` (`Mozilla/5.0 ...`); many sites return empty bodies
   otherwise. Cap response size before parsing (recommend 5 MB) — pages above that are vanishingly
   rare and parse times grow superlinearly.

## Performance (measured in local workerd)

| HTML size                    | parseHTML | Defuddle | markdown | total CPU |
| ---------------------------- | --------- | -------- | -------- | --------- |
| 6 KB (PG essay)              | 0ms       | 6ms      | 0ms      | **8ms**   |
| 43 KB (Fowler article)       | 5ms       | 39ms     | 5ms      | **49ms**  |
| 99 KB (LWN article)          | 4ms       | 51ms     | 1ms      | **59ms**  |
| 135 KB (overreacted blog)    | 3ms       | 70ms     | 6ms      | **83ms**  |
| 218 KB (MDN docs)            | 9ms       | 76ms     | 13ms     | **100ms** |
| 194 KB (Wikipedia: Markdown) | 14ms      | 150ms    | 30ms     | **188ms** |
| 610 KB (Wikipedia: Python)   | 30ms      | 525ms    | 225ms    | **635ms** |
| 1.2 MB (Wikipedia: WWII)     | 85ms      | 1500ms   | 450ms    | **~1.9s** |

Defuddle is 70–90% of CPU time. Fetch is independent (~200–500ms wall clock) and doesn't count
against CPU. Workers Paid gives 30s CPU per request — even pathological pages fit comfortably.

## Output quality notes

Things Defuddle gets right that plain Readability+Turndown does not, and that we should not lose if
the implementation is changed later:

- Code fences carry the language: ` ```js ` rather than ` js\n\n```\n ` (broken)
- Wikipedia infoboxes, `[edit]` links, "Jump to content" nav are stripped
- Citation footnotes converted: `[1]` → `[^1]` with footnote definitions appended
- Title and publication date appear at the top of the document
- Tables with `colspan`/`rowspan`, KaTeX/math blocks, `<figure>` with captions, and callouts have
  dedicated rules

## Versions tested

- `defuddle@0.6.6`
- `linkedom@0.18.5`

Pin both. Add a smoke test that re-extracts an MDN page and a Wikipedia page and checks for a
` ```js ` fence and a `[^1]` footnote respectively — these catch the most common regression
(Turndown rule registration silently failing).
