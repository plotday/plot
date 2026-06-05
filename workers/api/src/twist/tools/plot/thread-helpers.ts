import LinkifyIt from "linkify-it";
import { PostHog } from "posthog-node";

import { type Database, DbError } from "@plotday/db";
import type {
  ActorId,
  ActorType,
  Contact,
  NewThread,
  NewThreadWithNotes,
  NewActor,
  NewContact,
} from "@plotday/twister/plot";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";
import { createLogger } from "@plotday/worker-util";
import { classifyThreadForUser } from "../../../state/classify-thread";
import { addContacts } from "./contacts";
import type { Plot } from "./index";

export { markdownToPlainText };

/** Type alias for thread insert operations (DB table is now "thread").
 * `seq` and `last_note_seq` are xid8 (typed as `unknown` by the schema
 * generator) and maintained by triggers — never set by application code.
 */
type ActivityInsert = Omit<Database["public"]["Tables"]["thread"]["Insert"], "seq" | "last_note_seq">;
type ActivityUpdate = Omit<Database["public"]["Tables"]["thread"]["Update"], "seq" | "last_note_seq">;

/**
 * Resolves contact UUIDs to Contact objects with email/name.
 * Used for both thread.contacts and note.access_contacts.
 */
export async function resolveAccessContacts(
  plot: Plot,
  ids: string[] | null | undefined
): Promise<Contact[]> {
  if (!ids || ids.length === 0) return [];
  const contacts = await plot.db
    .selectFrom("contact")
    .select(["id", "name", "email"])
    .where("id", "in", ids)
    .execute();
  return contacts.map((c) => ({
    id: c.id as ActorId,
    name: c.name ?? null,
    email: c.email ?? null,
  }));
}

/**
 * Handles errors from database operations:
 * - DbError (unexpected): Logs, reports to PostHog Error Tracking, then throws generic error
 * - Regular Error (expected): Re-throws unchanged for caller to handle
 */
export async function handleDbOperationError(
  error: unknown,
  operation: string,
  plot: Plot,
  context: Record<string, unknown>
): Promise<never> {
  if (error instanceof DbError) {
    // Log full error with stack trace for debugging (PostHog/console)
    const logger = createLogger({ twist_instance_id: plot.twistInstanceId });

    // Extract PostgrestError from cause for full debugging info
    const cause = error.cause as
      | { code?: string; hint?: string; details?: string }
      | undefined;

    logger.error(`Unexpected database error in ${operation}`, error as Error, {
      operation,
      ...context,
      // Include PostgreSQL-specific error details
      db_code: cause?.code,
      db_hint: cause?.hint,
      db_details: cause?.details,
    });

    // Surface to PostHog Error Tracking. logger.error only emits a console
    // log (shipped to PostHog Logs via OTel) — it does NOT raise an Error
    // Tracking issue. Unexpected DB failures in this privileged runtime
    // (e.g. a schedule write rejected by a stale trigger) were therefore
    // invisible in Error Tracking and went unnoticed for a week. Report
    // them explicitly. Never let a reporting failure mask the original error.
    try {
      const postHog = new PostHog(plot.env.POSTHOG_API_KEY, {
        host: plot.env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      const userId = await plot.getUserId().catch(() => undefined);
      postHog.captureException(error as Error, userId, {
        context: `plot:${operation}`,
        twist_instance_id: plot.twistInstanceId,
        db_code: cause?.code,
        db_hint: cause?.hint,
        db_details: cause?.details,
        ...context,
      });
      await postHog.shutdown();
    } catch (reportError) {
      logger.error(
        `Failed to report ${operation} DB error to PostHog`,
        reportError as Error
      );
    }

    // Sanitize: throw generic error to caller
    throw new Error("Something went wrong");
  }
  // Expected errors (validation, not found, etc.) pass through unchanged
  throw error;
}

/**
 * Marker error thrown when a team-connector tries to file a thread for a user
 * who is not in the connector's team (no matching team priority for them).
 * This is a normal "skip" condition — the runtime suppresses it from the
 * twist error log and PostHog Error Tracking so it doesn't masquerade as a bug.
 *
 * Why: A team-scoped twist_instance can outlive the user's team membership
 * (e.g. they were removed from the team). Webhooks for that connector still
 * dispatch to the user's twist_instance, but the user has nowhere to file the
 * resulting thread. Throwing aborts the per-user filing without polluting
 * error reporting.
 */
export class ThreadFilingSkippedError extends Error {
  constructor(message = "Cannot file thread: user is not in the team associated with this connector.") {
    super(message);
    this.name = "ThreadFilingSkippedError";
  }
}

/**
 * Converts ActorType enum to database actor type string.
 */
export function actorTypeToString(type: ActorType): string {
  switch (type) {
    case 0: // ActorType.User
      return "user";
    case 1: // ActorType.Contact
      return "contact";
    case 2: // ActorType.Twist
      return "twist_instance";
    default:
      return "user";
  }
}

/**
 * Fallback HTML-to-text conversion when ai.toMarkdown() fails.
 * Strips tags, decodes entities, and preserves readable text content.
 *
 * The output is passed through `cleanConvertedMarkdown` at the call site so
 * the fallback path gets the same blank-line collapsing and empty-link
 * stripping as the AI success path.
 */
function stripHtmlToText(html: string): string {
  // Normalize line endings up front. Outlook/Exchange HTML commonly mixes
  // \r\n with \n inside text content; the `\n{3,}` collapse below (and the
  // line-by-line cleanup in cleanConvertedMarkdown) only sees \n, so an
  // unnormalized `\r\n\r\n\r\n` run survives as multiple blank paragraphs.
  let text = html.replace(/\r\n?/g, "\n");
  // Remove doctype, head, style, script blocks entirely
  text = text.replace(/<!DOCTYPE[^>]*>/gi, "");
  text = text.replace(/<head[^>]*>[\s\S]*?<\/head>/gi, "");
  text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "");
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "");
  // Convert headings to Markdown-style prefixes so the AI-fallback path
  // preserves the heading hierarchy when the structured converter fails.
  text = text.replace(
    /<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi,
    (_, level: string, inner: string) => {
      const flat = inner.replace(/\s+/g, " ").trim();
      if (!flat) return "";
      return `\n\n${"#".repeat(Number(level))} ${flat}\n\n`;
    }
  );
  // Convert <br>, <p>, <div>, <tr>, <li> to newlines
  text = text.replace(/<br\s*\/?>/gi, "\n");
  text = text.replace(/<\/(?:p|div|tr|li)>/gi, "\n");
  // Convert <a href="url">text</a> to [text](url)
  text = text.replace(/<a[^>]+href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, "[$2]($1)");
  // Remove all remaining HTML tags
  text = text.replace(/<[^>]+>/g, "");
  // Decode common HTML entities
  text = text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(parseInt(code)));
  // Collapse whitespace within lines
  text = text.replace(/[ \t]+/g, " ");
  // Collapse 3+ blank lines to 2
  text = text.replace(/\n{3,}/g, "\n\n");
  return text.trim();
}

/**
 * Splits a pipe-delimited table row into trimmed cells.
 * Escaped pipes (`\|`) are left intact.
 */
function parseTableCells(row: string): string[] {
  const stripped = row.trim().replace(/^\||\|$/g, "");
  // Split on unescaped pipes
  const cells = stripped.split(/(?<!\\)\|/).map((c) => c.replace(/\\\|/g, "|").trim());
  return cells;
}

/** Is this line a Markdown table separator row (e.g. `| --- | :---: |`)? */
function isSeparatorRow(line: string): boolean {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

/**
 * Flattens a collected block of table lines into either a cleaned Markdown table
 * (if it looks like real tabular data) or a sequence of paragraphs (if it looks
 * like a layout table, which is almost always the case for email HTML).
 */
function emitTable(tableLines: string[], out: string[]): void {
  // Parse rows, dropping separator rows and all-empty rows.
  const rows: string[][] = [];
  for (const tl of tableLines) {
    if (isSeparatorRow(tl)) continue;
    const cells = parseTableCells(tl);
    if (cells.every((c) => !c)) continue;
    rows.push(cells);
  }

  if (rows.length === 0) return;

  const columnCount = Math.max(...rows.map((r) => r.length));

  // Flatten if it looks like prose/layout rather than tabular data:
  //   - Single-column tables are always layout artifacts.
  //   - Any cell that contains a Markdown link, a list marker, or long text
  //     is a strong signal that this is a layout table, not data.
  const looksLikeProse =
    columnCount <= 1 ||
    rows.some((row) =>
      row.some(
        (cell) => cell.length > 30 || /\[[^\]]*\]\(/.test(cell) || /\n/.test(cell)
      )
    );

  if (looksLikeProse) {
    for (const row of rows) {
      const text = row.filter((c) => c).join(" ").trim();
      if (text) {
        if (out.length > 0 && out[out.length - 1] !== "") out.push("");
        out.push(text);
      }
    }
    return;
  }

  // Real data table — emit cleaned form.
  const header = rows[0];
  const paddedHeader = [...header, ...Array(columnCount - header.length).fill("")];
  out.push("| " + paddedHeader.join(" | ") + " |");
  out.push("|" + " --- |".repeat(columnCount));
  for (let r = 1; r < rows.length; r++) {
    const padded = [...rows[r], ...Array(columnCount - rows[r].length).fill("")];
    out.push("| " + padded.join(" | ") + " |");
  }
}

/**
 * Flattens an orphan pipe-delimited row (a `|...|` line that is not part of a
 * valid Markdown table) to plain text. ai.toMarkdown sometimes emits these when
 * a layout table gets split across a blank line.
 */
function flattenOrphanPipeRow(line: string): string {
  const cells = parseTableCells(line).filter((c) => c);
  return cells.join(" ");
}

/**
 * Characters that are visually invisible or zero-width. Email HTML often uses
 * runs of these (especially soft hyphens and combining grapheme joiners) as
 * preheader padding; left in place they render as large blocks of whitespace.
 */
const INVISIBLE_CHARS_RE =
  /[\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\u3164\uFEFF]/g;

/** Line contains no visible content (whitespace, invisibles, or empty). */
function isVisuallyEmpty(line: string): boolean {
  return line.replace(INVISIBLE_CHARS_RE, "").trim() === "";
}

/**
 * A Markdown block whose only textual content would render as empty — e.g.
 * `####` (empty heading), `-` / `*` (empty list item), `>` (empty blockquote),
 * `**` (empty emphasis). These survive from empty tags like `<h4></h4>` in
 * email HTML and produce vertical whitespace with no content.
 */
function isEmptyMarkdownBlock(line: string): boolean {
  const stripped = line.replace(INVISIBLE_CHARS_RE, "").trim();
  if (stripped === "") return false; // pure whitespace handled separately
  return /^(?:#{1,6}|[-*+]|\d+\.|>|\*+|_+|~+)\s*$/.test(stripped);
}

/**
 * Cleans up Markdown produced by ai.toMarkdown() from HTML (especially email HTML).
 * Aggressively flattens layout tables to paragraphs, drops empty rows, collapses
 * excessive horizontal rules / blank lines, and strips orphan pipe rows.
 *
 * Paragraphs are separated by a single blank line so super_editor renders them
 * as distinct paragraph nodes. Empty/whitespace-only lines and empty Markdown
 * blocks (empty headings, list items, emphasis, blockquotes) are dropped so they
 * never produce stray empty paragraphs in the rendered output.
 */
export function cleanConvertedMarkdown(markdown: string): string {
  // Strip invisible/zero-width characters used as email preheader padding.
  // Leave regular whitespace alone so real paragraph spacing survives.
  markdown = markdown.replace(INVISIBLE_CHARS_RE, "");

  // Drop empty-alt images like `![](url)`. Common for email logos, spacers,
  // and tracking pixels where the source <img> has no alt attribute. Must run
  // before the empty-text-link cleanup below so a nested `[![](logo)](link)`
  // collapses cleanly to `` instead of leaving a stray `!` inside the link.
  markdown = markdown.replace(/!\[\s*\]\([^)]*\)/g, "");

  // Drop empty-text links like `[](http://...)`. Email signatures wrap social
  // icons in `<a><img></a>`; once images are stripped these collapse to empty
  // links that no Markdown renderer can show as clickable.
  markdown = markdown.replace(/\[\s*\]\([^)]*\)/g, "");

  // Drop standalone image-links: a whole line whose only content is
  // `[ ![alt](image-src) ](link-url)`. These are pure decoration in emails —
  // header logos linking to the brand homepage, footer rows of social icons,
  // poster thumbnails alongside article text, avatar links next to a name.
  // In super_editor they render as image blocks whose URLs typically fail
  // (CSP-blocked, expired CDN tokens) and leave tall empty rectangles that
  // read as "blank space" in the note. The surrounding prose already carries
  // the meaning, so dropping the decoration cleans up the rendering.
  markdown = markdown.replace(
    /^[ \t]*\[[ \t]*!\[[^\]]*\]\([^)]+\)[ \t]*\]\([^)]+\)[ \t]*$/gm,
    ""
  );

  // ai.toMarkdown() sometimes joins paragraphs on one line with double spaces
  // instead of proper newlines. Convert inline double-space separators to paragraph breaks.
  // Exclude pipes from both sides so we don't shred table rows like `|  | cell |`.
  markdown = markdown.replace(/([^\s|])  +(?=[^\s|])/g, "$1\n\n");

  // Flatten multi-line link text. ai.toMarkdown() sometimes emits links as:
  //   [
  //
  //   Link Text ](url)
  // A blank line inside link text is not valid CommonMark, so renderers fall
  // back to showing the raw `[...](url)` characters. Collapse internal
  // whitespace to a single space. Nested brackets are excluded so image-links
  // like `[ ![alt](src) ](url)` are left untouched.
  markdown = markdown.replace(
    /\[([^[\]]*?\n[^[\]]*?)\]\(([^)]+)\)/g,
    (_, label: string, url: string) => {
      const flat = label.replace(/\s+/g, " ").trim();
      return flat ? `[${flat}](${url})` : "";
    }
  );

  // Restore whitespace that ai.toMarkdown() drops between adjacent inline
  // elements. The converter emits a link/bold run glued to the next word or
  // element — `[a](u)and[b](u)`, `**bold**word` — instead of keeping the space
  // that was in the source HTML. Besides reading wrong, the missing space can
  // break rendering: a Markdown renderer that isn't strict CommonMark shows the
  // literal `**` for `**bold**word`.
  //
  // We anchor on the glued *boundary* (a link close, a word-before-link, a bold
  // close) rather than matching a whole `**…**`/`[…](…)` span — span matching
  // can't tell an opening delimiter from a closing one and would pair the
  // closing `**` of one bold run with the opening `**` of the next (turning
  // `**a**. Then **b**` into `**a**. Then ** b**`). A space is inserted only
  // when the neighbour is a word character or another inline element, so
  // punctuation stays attached (`[x](u).`, `**x**,`) and already-spaced input
  // is unchanged (idempotent). The link sub-patterns forbid newlines so a
  // malformed link can't swallow the rest of the document. Turndown (the
  // read-later path) keeps these spaces, so this only ever rewrites
  // ai.toMarkdown output.
  markdown = markdown
    // link close `](url)` glued to a following word or inline element
    .replace(/(\]\([^)\n]*\))(?=[A-Za-z0-9[])/g, "$1 ")
    // word glued to a following link `[label](url)` — images `![alt](src)` are
    // safe because the character before `[` is `!`, not a word character
    .replace(/([A-Za-z0-9])(\[[^\]\n]*\]\([^)\n]*\))/g, "$1 $2")
    // bold close `**` glued to a following word or inline element
    .replace(/([A-Za-z0-9])\*\*(?=[A-Za-z0-9[])/g, "$1** ");

  const lines = markdown.split("\n");
  const cleaned: string[] = [];

  /** Append a blank separator unless we're at the start or already blank. */
  const pushBlankLine = () => {
    if (cleaned.length > 0 && cleaned[cleaned.length - 1] !== "") {
      cleaned.push("");
    }
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i].replace(/^\s+/, ""); // trim leading whitespace

    // Detect Markdown tables: header row followed by a separator row.
    if (
      line.startsWith("|") &&
      i + 1 < lines.length &&
      isSeparatorRow(lines[i + 1])
    ) {
      const tableLines: string[] = [];
      while (i < lines.length && lines[i].trimStart().startsWith("|")) {
        tableLines.push(lines[i]);
        i++;
      }
      emitTable(tableLines, cleaned);
      continue;
    }

    // Orphan pipe row: `|...|` line with no surrounding table structure.
    // Flatten to plain text so users don't see literal pipes. Separate from
    // adjacent content with a blank line so flattened rows become paragraphs
    // rather than a single run-on paragraph.
    if (line.startsWith("|") && line.replace(/\s/g, "").length > 1) {
      const flat = flattenOrphanPipeRow(line);
      if (flat) {
        pushBlankLine();
        cleaned.push(flat);
      }
      i++;
      continue;
    }

    // Drop empty Markdown blocks (empty heading/list/quote/emphasis).
    if (isEmptyMarkdownBlock(line)) {
      i++;
      continue;
    }

    // Visually-empty line → a single blank separator, never consecutive.
    if (isVisuallyEmpty(line)) {
      pushBlankLine();
      i++;
      continue;
    }

    // Collapse consecutive horizontal rules to at most one.
    if (/^\s*(?:---+|\*\*\*+|___+)\s*$/.test(line)) {
      let prevNonEmpty: string | undefined;
      for (let j = cleaned.length - 1; j >= 0; j--) {
        if (cleaned[j].trim() !== "") {
          prevNonEmpty = cleaned[j];
          break;
        }
      }
      if (
        prevNonEmpty &&
        /^\s*(?:---+|\*\*\*+|___+)\s*$/.test(prevNonEmpty)
      ) {
        i++;
        continue;
      }
    }

    // Trim trailing whitespace — `"foo   "` would otherwise create a
    // Markdown hard break via the "two trailing spaces" rule, AND so
    // super_editor_markdown's _endsWithHardLineBreak() check doesn't pull
    // the next blank line into the current paragraph.
    cleaned.push(line.replace(/\s+$/, ""));
    i++;
  }

  // Drop leading/trailing blank separators.
  while (cleaned.length > 0 && cleaned[0] === "") cleaned.shift();
  while (cleaned.length > 0 && cleaned[cleaned.length - 1] === "") cleaned.pop();

  return cleaned.join("\n");
}

/**
 * Pre-processes email HTML before ai.toMarkdown() runs. Unwraps layout tables
 * (almost all email tables are layout, not data) so the AI converter produces
 * clean paragraphs instead of Markdown tables riddled with pipes. Also drops
 * <style>, <script>, and <head> blocks that carry no useful note content.
 *
 * Uses Cloudflare's built-in HTMLRewriter — no extra dependency.
 */
export async function preprocessEmailHtml(html: string): Promise<string> {
  const response = new Response(html, {
    headers: { "Content-Type": "text/html" },
  });
  const remove = { element: (el: Element) => { el.remove(); } };
  const unwrap = { element: (el: Element) => { el.removeAndKeepContent(); } };
  const toDiv = { element: (el: Element) => { el.tagName = "div"; } };
  const rewriter = new HTMLRewriter()
    .on("style", remove)
    .on("script", remove)
    .on("head", remove)
    .on("table", unwrap)
    .on("tbody", unwrap)
    .on("thead", unwrap)
    .on("tfoot", unwrap)
    .on("tr", toDiv)
    .on("td", toDiv)
    .on("th", toDiv);
  const transformed = rewriter.transform(response);
  return await transformed.text();
}

/**
 * Shorten a long URL label to `host.com/...`. The underlying href is kept
 * intact; only what the reader sees is trimmed.
 */
function shortenUrlLabel(raw: string, url: string): string {
  if (raw.length <= 60) return raw;
  try {
    return `${new URL(url).host}/...`;
  } catch {
    return `${raw.slice(0, 57)}...`;
  }
}

/** A line that looks like a Markdown list item (bulleted or numbered). */
function isListLine(line: string): boolean {
  return /^\s*(?:[-*+]|\d+\.)\s/.test(line);
}

/**
 * Insert paragraph breaks between adjacent non-blank lines that aren't part
 * of the same tight list block, and collapse runs of blank lines to one.
 *
 * Preserves list structure — consecutive `- `/`* `/`1. ` lines stay
 * separated by a single newline so Markdown renders them as a tight list —
 * while giving plain-text prose the double-newline separator it needs for
 * Markdown paragraph rendering.
 */
function normalizeMarkdownParagraphs(text: string): string {
  const lines = text.split("\n");
  const expanded: string[] = [];

  for (let i = 0; i < lines.length; i++) {
    expanded.push(lines[i]);
    if (i === lines.length - 1) break;
    const cur = lines[i];
    const next = lines[i + 1];
    if (cur.trim() === "" || next.trim() === "") continue;
    if (isListLine(cur) && isListLine(next)) continue;
    expanded.push("");
  }

  const out: string[] = [];
  let prevBlank = false;
  for (const line of expanded) {
    if (line === "") {
      if (!prevBlank) out.push("");
      prevBlank = true;
    } else {
      out.push(line);
      prevBlank = false;
    }
  }
  return out.join("\n");
}

/**
 * Convert a plaintext note to Markdown.
 *
 * Handles:
 * - HTML entity decoding (&amp;, &lt;, etc.)
 * - Unescaping common over-escaped Markdown punctuation (`\[`, `\]`, `1\.`)
 *   that external services apply when round-tripping markdown through a
 *   plain-text comment store (Google Drive, etc.)
 * - Outlook-style "Label<https://url>" links → [Label](url)
 * - Long autolinked URLs displayed as `host.com/...`
 * - Horizontal-rule lines (10+ underscores/dashes/equals) normalized to `---`,
 *   with consecutive HRs collapsed
 * - Paragraph breaks via a blank line between adjacent non-list lines;
 *   consecutive list-item lines stay tight so lists render as one block
 */
export function plainTextToMarkdown(note: string): string {
  let converted = note
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");

  // Drop over-escaping that external services apply when round-tripping
  // markdown through a plain-text comment store. `\[Name\]` / `1\.` in
  // plain prose is noise; legitimate plain text never writes these.
  converted = converted
    .replace(/\\([[\]()*_~`>#+=!-])/g, "$1")
    .replace(/(^|\s)(\d+)\\\./gm, "$1$2.");

  // Outlook/Teams plaintext link format: "Manage Booking<https://...>"
  converted = converted.replace(
    /([^<\n]*?\S)[ \t]*<(https?:\/\/[^>\s]+)>/g,
    (_, label: string, url: string) => `[${label}](${url})`
  );

  // Normalize decorative bars (e.g. "________________________________") to ---
  converted = converted.replace(/^[ \t]*[_\-=]{10,}[ \t]*$/gm, "---");
  // Collapse runs of consecutive HRs (separated only by blank lines) into one
  converted = converted.replace(/(?:^---[ \t]*\n\s*)+(?=^---[ \t]*$)/gm, "");

  // Mask existing markdown links so linkify doesn't re-process their hrefs
  const masked: string[] = [];
  converted = converted.replace(/\[[^\]]*\]\([^)]+\)/g, (m) => {
    const idx = masked.push(m) - 1;
    return `LINK${idx}`;
  });

  const linkify = new LinkifyIt();
  const matches = linkify.match(converted);
  if (matches) {
    for (let i = matches.length - 1; i >= 0; i--) {
      const match = matches[i];
      const label = shortenUrlLabel(match.raw, match.url);
      converted =
        converted.substring(0, match.index) +
        `[${label}](${match.url})` +
        converted.substring(match.lastIndex);
    }
  }

  converted = converted.replace(
    // eslint-disable-next-line no-control-regex
    /LINK(\d+)/g,
    (_, idx: string) => masked[Number(idx)]
  );

  return normalizeMarkdownParagraphs(converted);
}

// `markdownToPlainText` lives in @plotday/twister/utils/markdown so
// connectors can call it in-process without crossing the RPC boundary.
// It is re-exported from this file for convenience of existing callers.

/**
 * Converts note content to Markdown based on the specified contentType.
 *
 * @param ai - The Cloudflare Workers AI binding
 * @param note - The note content to convert
 * @param contentType - The format of the input note ('text', 'markdown', 'html', or null)
 * @returns The note content converted to Markdown
 */
export async function convertNoteToMarkdown(
  ai: Ai,
  note: string | null | undefined,
  contentType?: "text" | "markdown" | "html"
): Promise<string | null> {
  if (!note) return null;

  // Default to 'markdown' if contentType is not specified
  const type = contentType ?? "markdown";

  switch (type) {
    case "html": {
      // Convert HTML to Markdown using Cloudflare Workers AI.
      // Pre-process to flatten layout tables (which are used for presentation
      // in virtually all HTML email) so we get clean paragraphs instead of
      // Markdown tables with spurious pipes and tiny-scaled cell content.
      const preprocessed = await preprocessEmailHtml(note);
      try {
        const result = await ai.toMarkdown({
          name: "note.html",
          blob: new Blob([preprocessed], { type: "text/html" }),
        });

        // Check if conversion was successful
        if (result.format === "markdown") {
          return cleanConvertedMarkdown(result.data);
        }

        // Handle error case (format === "error")
        if ("error" in result) {
          const logger = createLogger();
          logger.error(
            "Failed to convert HTML to Markdown",
            new Error(String(result.error))
          );
          return cleanConvertedMarkdown(stripHtmlToText(preprocessed));
        }

        // Fallback for unexpected format
        const logger = createLogger();
        logger.error("Unexpected toMarkdown response format", { result });
        return cleanConvertedMarkdown(stripHtmlToText(note));
      } catch (error) {
        // If conversion fails, strip HTML tags as fallback
        const logger = createLogger();
        logger.error("Failed to convert HTML to Markdown", error as Error);
        return cleanConvertedMarkdown(stripHtmlToText(note));
      }
    }

    case "text": {
      return plainTextToMarkdown(note);
    }

    case "markdown":
    default:
      // Already in Markdown format, return as-is
      return note;
  }
}

/**
 * Creates a preview string from markdown content.
 * Strips markdown formatting, newlines, and truncates to 100 characters.
 *
 * @param markdown - The markdown content to create a preview from
 * @returns A plain text preview (max 100 characters) or null if input is empty
 */

/** Strips markdown formatting from text, keeping plain text content. */
export function stripMarkdown(text: string): string {
  let result = text;

  // Remove zero-width / invisible format characters. Newsletters pad their
  // preheader with these (e.g. U+034F combining grapheme joiner + U+200B
  // zero-width space, repeated) to push later content out of the inbox
  // snippet. They are not matched by \s, so they survive whitespace collapse
  // and render as a long run of blank space before the truncation ellipsis.
  // Keep in sync with createPreviewFromMarkdown in apps/plot/lib/store/thread.dart.
  result = result.replace(
    /[\u00AD\u034F\u061C\u200B-\u200F\u2060-\u2064\u206A-\u206F\uFEFF]/g,
    ""
  );

  // Strip HTML tags (keep inner text)
  result = result.replace(/<(?!https?:\/\/)[^>]+>/g, "");

  // Decode common HTML entities
  result = result
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");

  // Remove code blocks
  result = result.replace(/```[\s\S]*?```/g, "");
  result = result.replace(/`[^`]+`/g, "");

  // Remove headers
  result = result.replace(/^#+\s+/gm, "");

  // Remove images (before links so ![alt](url) doesn't become [alt](url))
  result = result.replace(/!\[([^\]]*)\]\([^)]+\)/g, "");

  // Remove links: keep descriptive text, extract domain for URL-only or empty link text.
  // Handles mentions [Name](#@UUID) and Linear-style autolinks [url](<url>).
  // Keep in sync with displayPreview in apps/plot/lib/store/thread.dart.
  result = result.replace(/\[([^\]]*)\]\(<?([^>)]+)>?\)/g, (_, text, url) => {
    if (text && !/^https?:\/\//.test(text)) return text;
    // Extract domain from URL (try url first, fall back to text)
    const source = url || text;
    const domainMatch = source.match(/^https?:\/\/(?:www\.)?([^/\s]+)(\/\S*)?/);
    if (!domainMatch) return text || '';
    return domainMatch[2] ? `${domainMatch[1]}/\u2026` : domainMatch[1];
  });

  // Remove bold/italic
  result = result.replace(/(\*\*|__)(.*?)\1/g, "$2");
  result = result.replace(/(\*|_)(.*?)\1/g, "$2");

  // Remove strikethrough
  result = result.replace(/~~(.*?)~~/g, "$1");

  // Remove blockquotes
  result = result.replace(/^>\s+/gm, "");

  // Remove horizontal rules
  result = result.replace(/^[-*_]{3,}$/gm, "");

  // Remove list markers
  result = result.replace(/^[\s]*[-*+]\s+/gm, "");
  result = result.replace(/^[\s]*\d+\.\s+/gm, "");

  return result;
}

/**
 * Strips markdown formatting from a title.
 * "Complete [GTM Module 4 assignments](https://example.com)" → "Complete GTM Module 4 assignments"
 */
export function cleanTitle(title: string): string {
  return stripMarkdown(title).replace(/\s+/g, " ").trim();
}

/**
 * Derives a display title from content. Strips markdown, takes the first line,
 * truncates at word boundary if > 60 chars.
 */
export function titleFromContent(content: string | null | undefined): string | null {
  if (!content?.trim()) return null;
  const stripped = stripMarkdown(content).replace(/\s+/g, " ").trim();
  const firstLine = stripped.split("\n")[0].trim();
  if (!firstLine) return null;
  if (firstLine.length <= 60) return firstLine;
  const lastSpace = firstLine.lastIndexOf(" ", 60);
  if (lastSpace > 0) {
    return firstLine.substring(0, lastSpace) + "\u2026";
  }
  return firstLine.substring(0, 59) + "\u2026";
}

export function createPreviewFromMarkdown(
  markdown: string | null | undefined
): string | null {
  if (!markdown) return null;

  let preview = stripMarkdown(markdown);

  // Strip raw URLs (standalone URLs not part of markdown links)
  preview = preview.replace(/https?:\/\/[^\s)>\]]+/g, "");

  // Replace newlines with " / " separator
  preview = preview.replace(/\n+/g, " / ");

  // Replace multiple spaces with single space
  preview = preview.replace(/\s+/g, " ");

  // Clean up separator artifacts (e.g. "/ /" or leading/trailing " / ").
  // Require whitespace on at least one side so path slashes (e.g. "domain.com/…") aren't affected.
  preview = preview.replace(/(\s+\/\s*|\s*\/\s+)+/g, " / ");

  // Trim whitespace and separators
  preview = preview.replace(/^[\s/]+|[\s/]+$/g, "");

  // Truncate to 100 characters
  if (preview.length > 100) {
    preview = preview.substring(0, 100).trim() + "…";
  }

  return preview || null;
}

/**
 * Processes a NewActor (either an existing actor ID or a new contact) and returns the actor ID.
 * If the NewActor is a NewContact, it will be upserted and linked to the priority.
 *
 * @param plot - The Plot instance
 * @param newActor - The NewActor to process (can be { id } or NewContact)
 * @param priorityId - The priority ID to link new contacts to
 * @returns The actor ID, or null if newActor is undefined/null
 */
export async function processNewActor(
  plot: Plot,
  newActor: NewActor | undefined | null,
  priorityId: string
): Promise<string | null> {
  if (!newActor) return null;

  // Use batched version for single actor
  const result = await processNewActorArray(plot, [newActor], priorityId);
  return result.length > 0 ? result[0] : null;
}

/**
 * Processes an array of NewActors and returns an array of actor IDs.
 * Batches all database operations for efficiency.
 * Filters out any null/undefined results.
 *
 * @param plot - The Plot instance
 * @param newActors - Array of NewActors to process
 * @param priorityId - The priority ID to link new contacts to
 * @returns Array of actor IDs (nulls filtered out)
 */
export async function processNewActorArray(
  plot: Plot,
  newActors: NewActor[],
  _priorityId: string
): Promise<ActorId[]> {
  if (newActors.length === 0) return [];

  // Separate existing actor IDs from new contacts
  const existingActorIds: ActorId[] = [];
  const newContacts: NewContact[] = [];
  const actorOrder: Array<{ type: "existing" | "new"; index: number }> = [];

  for (const newActor of newActors) {
    if (!newActor) continue;

    if ("id" in newActor) {
      // Existing actor reference
      actorOrder.push({ type: "existing", index: existingActorIds.length });
      existingActorIds.push(newActor.id as ActorId);
    } else {
      // New contact by email
      actorOrder.push({ type: "new", index: newContacts.length });
      newContacts.push(newActor);
    }
  }

  // Batch upsert all new contacts at once, building a lookup map
  // addContacts may return fewer results than inputs due to email deduplication
  // and dropped contacts (no email + no source), so we can't use positional indexing
  const createdActorMap = new Map<number, ActorId>();
  if (newContacts.length > 0) {
    const actors = await addContacts(plot, newContacts);
    // Build lookup by email and source accountId to map back to original indices
    const actorByEmail = new Map<string, ActorId>();
    const actorBySource = new Map<string, ActorId>();
    for (const actor of actors) {
      if (actor.email) actorByEmail.set(actor.email.toLowerCase(), actor.id);
    }
    // For source-only contacts, query their external account mapping.
    // Rows are scoped to this connector's twist_instance_id, so account_id
    // alone is unique within this query.
    const sourceOnlyActorIds = actors
      .filter((a) => !a.email)
      .map((a) => a.id);
    if (sourceOnlyActorIds.length > 0) {
      const mappings = await plot.db
        .selectFrom("contact_external_account")
        .select(["contact_id", "account_id"])
        .where("twist_instance_id", "=", plot.twistInstanceId)
        .where("contact_id", "in", sourceOnlyActorIds)
        .execute();
      for (const m of mappings) {
        actorBySource.set(m.account_id, m.contact_id as ActorId);
      }
    }
    // Map each newContact index to its created actor
    for (let i = 0; i < newContacts.length; i++) {
      const contact = newContacts[i];
      const byEmail =
        contact.email && actorByEmail.get(contact.email.toLowerCase());
      const bySource =
        contact.source && actorBySource.get(contact.source.accountId);
      const actorId = byEmail || bySource;
      if (actorId) createdActorMap.set(i, actorId);
    }
  }

  // Build the final actor IDs array in original order, skipping unresolved contacts
  const actorIds: ActorId[] = actorOrder
    .map((order) => {
      if (order.type === "existing") {
        return existingActorIds[order.index];
      } else {
        return createdActorMap.get(order.index) ?? null;
      }
    })
    .filter((id): id is ActorId => id !== null);

  // Contact visibility is handled by user_contact rows.
  // No batch upsert needed — contacts become visible to users through
  // thread_contacts_sync triggers and connection ingestion.

  return actorIds;
}

/**
 * Processes all tags for an activity, batching all actor operations across all tags.
 * This is more efficient than calling processNewActorArray per tag.
 *
 * @param plot - The Plot instance
 * @param tags - Record of tag IDs to NewActor arrays
 * @param priorityId - The priority ID to link new contacts to
 * @returns Record of tag IDs to ActorId arrays
 */
export async function processTagsActors(
  plot: Plot,
  tags: Partial<Record<number, NewActor[]>>,
  priorityId: string
): Promise<Partial<Record<number, ActorId[]>>> {
  // Collect all actors from all tags
  const allNewActors: NewActor[] = [];
  const tagActorMapping: Array<{
    tagId: number;
    startIdx: number;
    count: number;
  }> = [];

  for (const [tagIdStr, newActors] of Object.entries(tags)) {
    if (newActors && newActors.length > 0) {
      tagActorMapping.push({
        tagId: parseInt(tagIdStr),
        startIdx: allNewActors.length,
        count: newActors.length,
      });
      allNewActors.push(...newActors);
    }
  }

  if (allNewActors.length === 0) return {};

  // Process all actors in one batch
  const allActorIds = await processNewActorArray(
    plot,
    allNewActors,
    priorityId
  );

  // Map back to tag structure
  const result: Partial<Record<number, ActorId[]>> = {};
  for (const mapping of tagActorMapping) {
    const tagActorIds = allActorIds.slice(
      mapping.startIdx,
      mapping.startIdx + mapping.count
    );
    if (tagActorIds.length > 0) {
      result[mapping.tagId] = tagActorIds;
    }
  }

  return result;
}

/**
 * Result of preparing an activity for database insertion/upsert.
 */
export type PreparedThread = (
  | {
      /** Row to insert */
      insert: ActivityInsert;
    }
  | {
      /** Row to upsert */
      upsert: ActivityUpdate;
      /** Defaults to merge with upsert for the insert portion of the upsert */
      defaults: ActivityInsert;
    }
) & {
  priorityId: string;

  /** The resolved author contact ID (or twistInstanceId if no author specified) */
  authorId: string;
};

/**
 * Marks an activity as "read" for a note/activity author, if the author's
 * contact is linked to a user.
 *
 * Before upserting activity_read, checks whether there are unread notes from
 * other authors (using author_id). If so, the activity stays unread so the
 * user sees there is new content from others.
 *
 * Early returns (no-op) when:
 * - authorId is the twistInstanceId (no real author, just the twist default)
 * - author contact has no linked user_id
 * - there are unread notes from other authors since the user's last read_at
 *
 * @param plot - The Plot instance
 * @param authorId - The resolved author contact ID
 * @param activityId - The activity to mark as read
 * @param timestamp - The read_at timestamp to use
 */
export async function markThreadReadForAuthor(
  plot: Plot,
  authorId: string,
  activityId: string,
  timestamp: string
): Promise<void> {
  // No real author — just the twist itself
  if (authorId === plot.twistInstanceId) {
    return;
  }

  try {
    // Look up whether this contact is linked to a user
    const contact = await plot.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", authorId)
      .executeTakeFirst();

    const userId = contact?.user_id;
    if (!userId) {
      return;
    }

    // Check if there are unread notes from other authors since this user's
    // last read_at — mirrors the DB trigger logic but uses author_id (the real
    // author) instead of created_by (which is the twist for synced notes).
    const existingRead = await plot.db
      .selectFrom("thread_read")
      .select("read_at")
      .where("user_id", "=", userId)
      .where("thread_id", "=", activityId)
      .executeTakeFirst();

    const lastReadAt = existingRead?.read_at ?? null;

    let unreadFromOthersQuery = plot.db
      .selectFrom("note")
      .select("id")
      .where("thread_id", "=", activityId)
      .where("draft", "=", false)
      .where("archived_at", "is", null)
      .where((eb) =>
        eb.or([
          eb("author_id", "is", null),
          eb("author_id", "!=", authorId),
        ])
      )
      .limit(1);

    if (lastReadAt) {
      const readAtDate =
        lastReadAt instanceof Date
          ? lastReadAt
          : new Date(lastReadAt);
      unreadFromOthersQuery = unreadFromOthersQuery.where(
        "source_created_at",
        ">",
        readAtDate
      );
    }

    const unreadFromOthers = await unreadFromOthersQuery.executeTakeFirst();

    if (unreadFromOthers) {
      // There are unread notes from other authors — keep activity unread
      return;
    }

    // Upsert a single activity_read entry for the author
    try {
      await plot.db
        .insertInto("thread_read")
        .values({
          thread_id: activityId,
          user_id: userId,
          read_at: timestamp,
        })
        .onConflict((oc) =>
          oc.columns(["user_id", "thread_id"]).doUpdateSet((eb) => ({
            read_at: eb.ref("excluded.read_at"),
          }))
        )
        .execute();
    } catch (upsertError) {
      const logger = createLogger({
        twist_instance_id: plot.twistInstanceId,
      });
      logger.error(
        "Failed to auto-mark activity as read for author",
        upsertError as Error,
        { thread_id: activityId, user_id: userId }
      );
    }
  } catch (error) {
    // Log but don't throw — read status is non-critical
    const logger = createLogger({
      twist_instance_id: plot.twistInstanceId,
    });
    logger.error(
      "Error in markThreadReadForAuthor",
      error as Error,
      { thread_id: activityId, author_id: authorId }
    );
  }
}

/**
 * Prepares a NewThread for database insertion, handling all common preparation logic:
 * - Priority resolution via classify_thread_for_user (rule-based)
 * - Embedding generation from title + first note content
 * - Preview generation from notes
 * - Author and assignee processing
 * - Database object construction
 *
 * For non-source activities, this function derives the default assignee for actions.
 * For source-based activities, the assignee is only processed if explicit (the RPC derives default).
 *
 * @param plot - The Plot instance
 * @param activity - The NewThread or NewThreadWithNotes to prepare
 * @returns PreparedThread containing all data needed for insertion, or null
 *   if the thread cannot be filed for the owner user (e.g. team-connector thread
 *   with no matching team priority for this user).
 */
export async function prepareThreadForDb(
  plot: Plot,
  activity: NewThread | NewThreadWithNotes
): Promise<PreparedThread | null> {
  // Activity exceptions are handled via occurrences[] array
  if ("recurrence" in activity || "occurrence" in activity) {
    throw new Error(
      "Activity exceptions should use the occurrences[] array field, not recurrence/occurrence fields"
    );
  }

  await plot.validateActivityCreateAccess(activity);

  // Generate embedding from title + first note content for content-based matching.
  // Hoisted so it can be stored on the thread row regardless of priority resolution path.
  let embeddingJson: string | undefined;

  // Determine target priority
  let targetPriorityId: string;

  // Generate embedding for all threads (used for future content-based rule matching).
  {
    const firstNote =
      "notes" in activity && activity.notes?.[0]?.content
        ? activity.notes[0].content
        : null;
    const textToEmbed = [activity.title, firstNote]
      .filter(Boolean)
      .join("\n");

    if (textToEmbed.trim().length > 0) {
      try {
        const embedding = await plot.ai.embed(textToEmbed);
        embeddingJson = JSON.stringify(embedding);
      } catch (error) {
        const logger = createLogger({
          twist_instance_id: plot.twistInstanceId,
        });
        logger.warn(
          "Failed to generate embedding for thread",
          {
            error_message:
              error instanceof Error ? error.message : String(error),
          }
        );
      }
    }
  }

  if ("focus" in activity && activity.focus?.id) {
    targetPriorityId = activity.focus.id;
  } else {
    // Classify via the production hybrid-LLM classifier. Pre-insert
    // case: no threadId yet, only the embedding is available. On
    // transient classifier failure, classifyThreadForUser files at
    // root and reports `pending: true` — the twist-created thread is
    // still inserted there, and the consumer Worker (driven by the
    // dispatch enqueue path) re-files when classification recovers.
    const ownerUserId = await plot.getUserId();
    // Classify via the production hybrid-LLM cascade. Pre-insert: no
    // threadId yet, only embedding is available. classifyThreadForUser
    // always returns a non-null priorityId (root if the cascade has no
    // better match) and a `pending` flag set on transient failure —
    // currently dropped here per the twist-path acceptable-degradation
    // note in the production-wiring spec §14 followups.
    const matched = await classifyThreadForUser(plot.db, plot.env, {
      userId: ownerUserId,
      embedding: embeddingJson ?? null,
    });

    // Focuses are team-agnostic: file wherever the classifier landed. Team
    // scope is enforced by the `set_thread_team_and_external` insert trigger
    // (which stamps thread.team_id from the creator connection) plus the
    // user.thread visibility firewall on thread.team_id — not by which
    // priority the thread is filed under.
    targetPriorityId = matched.priorityId;
  }

  await plot.validatePriorityAccess(targetPriorityId);

  // Generate preview from explicit preview field or fall back to notes
  let previewText: string | null = null;

  if ("preview" in activity && activity.preview !== undefined) {
    if (activity.preview === null) {
      previewText = null;
    } else {
      previewText = createPreviewFromMarkdown(activity.preview);
    }
  } else if (
    "notes" in activity &&
    activity.notes &&
    activity.notes.length > 0
  ) {
    const firstNoteWithContent = activity.notes.find((note) => note.content);
    if (firstNoteWithContent && firstNoteWithContent.content) {
      const markdown = await convertNoteToMarkdown(
        plot.env.AI,
        firstNoteWithContent.content,
        firstNoteWithContent.contentType
      );
      previewText = createPreviewFromMarkdown(markdown);
    }
  }

  // Resolve thread-level author for read-marking.
  // The author field comes from NewLink.author (passed via createLink → createThread).
  // created_by in the DB remains plot.twistInstanceId (the twist created it).
  let authorId = plot.twistInstanceId;
  if ("author" in activity && (activity as any).author) {
    const resolvedAuthorId = await processNewActor(
      plot,
      (activity as any).author,
      targetPriorityId
    );
    if (resolvedAuthorId) {
      authorId = resolvedAuthorId as ActorId;
    }
  }

  // Resolve accessContacts from NewContact[] (emails) to ActorId[].
  let resolvedAccessContacts: ActorId[] | undefined;
  if (activity.accessContacts && activity.accessContacts.length > 0) {
    const actors = await addContacts(plot, activity.accessContacts as NewContact[]);
    resolvedAccessContacts = actors.map((a) => a.id);
  } else if (
    activity.accessContacts === undefined &&
    activity.access === "private" &&
    !activity.archived
  ) {
    // Default to owner for new private threads (not cancellations/archives)
    const owner = await plot.getOwner();
    resolvedAccessContacts = [owner.id];
  }

  // Build defaults object for INSERT
  const defaults: ActivityInsert = {
    created_by: plot.twistInstanceId,
    // Who CAUSED the thread: the resolved external author (above), or the
    // twist instance itself when no author was supplied. upsert_thread reads
    // this from p_defaults (source path) and the direct insert writes the row.
    author_id: authorId,
    updated_by: plot.getUpdatedBy(),
    title: cleanTitle(activity.title?.trim() || "Untitled"),
    preview: previewText,
    draft: false,
    contacts: resolvedAccessContacts ?? [],
    sync_depth: plot.syncDepth + 1,
    ...(activity.archived !== undefined
      ? { archived_at: activity.archived ? new Date().toISOString() : null }
      : {}),
    ...("id" in activity && activity.id ? { id: activity.id } : {}),
    ...("key" in activity && (activity as any).key !== undefined
      ? { key: (activity as any).key }
      : {}),
    // Map SDK 'type' field to database 'icon' column, with 'icon' as fallback for internal callers
    ...("type" in activity && (activity as any).type !== undefined
      ? { icon: (activity as any).type }
      : "icon" in activity && (activity as any).icon !== undefined
        ? { icon: (activity as any).icon }
        : {}),
    // Store content embedding for future priority rule matching
    ...(embeddingJson ? { embedding: embeddingJson } : {}),
  };

  // Source-based threads use upsert, non-source use insert
  const hasSource = "source" in activity && activity.source;

  if (hasSource) {
    const upsertFields: ActivityUpdate = {
      updated_by: plot.getUpdatedBy(),
      sync_depth: plot.syncDepth + 1,
      ...(activity.archived !== undefined
        ? { archived_at: activity.archived ? new Date().toISOString() : null }
        : {}),
      // key must be in upsert (p_thread) so upsert_thread can look up
      // existing threads by (key, priority_id) for database-level dedup
      ...("key" in activity && (activity as any).key !== undefined
        ? { key: (activity as any).key }
        : {}),
    };

    if (activity.title !== undefined) {
      // Only include title in upsert if it's non-empty.
      // Cancelled/deleted events (e.g. Google Calendar) send title: null,
      // which would violate thread_title_required_when_not_draft constraint.
      if (activity.title && activity.title.trim() !== "") {
        upsertFields.title = cleanTitle(activity.title);
      }
    }
    if ("preview" in activity && activity.preview !== undefined) {
      upsertFields.preview = previewText;
    }
    if (resolvedAccessContacts !== undefined) {
      upsertFields.contacts = resolvedAccessContacts;
    }
    if ("type" in activity && (activity as any).type !== undefined) {
      upsertFields.icon = (activity as any).type;
    } else if ("icon" in activity && (activity as any).icon !== undefined) {
      upsertFields.icon = (activity as any).icon;
    }

    return {
      upsert: upsertFields,
      defaults,
      priorityId: targetPriorityId,
      authorId,
    };
  } else {
    return {
      insert: defaults,
      priorityId: targetPriorityId,
      authorId,
    };
  }
}

/** @deprecated Use markThreadReadForAuthor */
export const markActivityReadForAuthor = markThreadReadForAuthor;
/** @deprecated Use prepareThreadForDb */
export const prepareActivityForDb = prepareThreadForDb;
/** @deprecated Use PreparedThread */
export type PreparedActivity = PreparedThread;
