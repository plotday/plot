import LinkifyIt from "linkify-it";

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

import { createLogger } from "@plotday/worker-util";
import { rpc } from "../../../rpc";
import { addContacts } from "./contacts";
import type { Plot } from "./index";

/** Type alias for thread insert operations (DB table is now "thread") */
type ActivityInsert = Database["public"]["Tables"]["thread"]["Insert"];
type ActivityUpdate = Database["public"]["Tables"]["thread"]["Update"];

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
 * - DbError (unexpected): Logs with full context and stack trace, then throws generic error
 * - Regular Error (expected): Re-throws unchanged for caller to handle
 */
export function handleDbOperationError(
  error: unknown,
  operation: string,
  twistInstanceId: string,
  context: Record<string, unknown>
): never {
  if (error instanceof DbError) {
    // Log full error with stack trace for debugging (PostHog/console)
    const logger = createLogger({ twist_instance_id: twistInstanceId });

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
    // Sanitize: throw generic error to caller
    throw new Error("Something went wrong");
  }
  // Expected errors (validation, not found, etc.) pass through unchanged
  throw error;
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
 */
function stripHtmlToText(html: string): string {
  let text = html;
  // Remove doctype, head, style, script blocks entirely
  text = text.replace(/<!DOCTYPE[^>]*>/gi, "");
  text = text.replace(/<head[^>]*>[\s\S]*?<\/head>/gi, "");
  text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "");
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "");
  // Convert <br>, <p>, <div>, <tr>, <li> to newlines
  text = text.replace(/<br\s*\/?>/gi, "\n");
  text = text.replace(/<\/(?:p|div|tr|li|h[1-6])>/gi, "\n");
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
 * Cleans up Markdown produced by ai.toMarkdown() from HTML (especially email HTML).
 * Aggressively flattens layout tables to paragraphs, drops empty rows, collapses
 * excessive horizontal rules / blank lines, and strips orphan pipe rows.
 */
function cleanConvertedMarkdown(markdown: string): string {
  // ai.toMarkdown() sometimes joins paragraphs on one line with double spaces
  // instead of proper newlines. Convert inline double-space separators to paragraph breaks.
  // Exclude pipes from both sides so we don't shred table rows like `|  | cell |`.
  markdown = markdown.replace(/([^\s|])  +(?=[^\s|])/g, "$1\n\n");

  const lines = markdown.split("\n");
  const cleaned: string[] = [];

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
        if (cleaned.length > 0 && cleaned[cleaned.length - 1] !== "") {
          cleaned.push("");
        }
        cleaned.push(flat);
      }
      i++;
      continue;
    }

    // Remove empty blockquote lines (just ">" with optional whitespace)
    if (/^\s*>\s*$/.test(line)) {
      i++;
      continue;
    }

    // Collapse consecutive horizontal rules to at most one
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

    cleaned.push(line);
    i++;
  }

  let result = cleaned.join("\n");
  result = result.replace(/\n{3,}/g, "\n\n");

  return result.trim();
}

/**
 * Pre-processes email HTML before ai.toMarkdown() runs. Unwraps layout tables
 * (almost all email tables are layout, not data) so the AI converter produces
 * clean paragraphs instead of Markdown tables riddled with pipes. Also drops
 * <style>, <script>, and <head> blocks that carry no useful note content.
 *
 * Uses Cloudflare's built-in HTMLRewriter — no extra dependency.
 */
async function preprocessEmailHtml(html: string): Promise<string> {
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
          return stripHtmlToText(preprocessed);
        }

        // Fallback for unexpected format
        const logger = createLogger();
        logger.error("Unexpected toMarkdown response format", { result });
        return stripHtmlToText(note);
      } catch (error) {
        // If conversion fails, strip HTML tags as fallback
        const logger = createLogger();
        logger.error("Failed to convert HTML to Markdown", error as Error);
        return stripHtmlToText(note);
      }
    }

    case "text": {
      // Decode HTML entities
      let converted = note
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'")
        .replace(/&nbsp;/g, " ");

      // Auto-link URLs using linkify-it for robust URL detection
      const linkify = new LinkifyIt();
      const matches = linkify.match(converted);

      if (matches) {
        // Process matches in reverse order to preserve string positions
        for (let i = matches.length - 1; i >= 0; i--) {
          const match = matches[i];
          const markdownLink = `[${match.raw}](${match.url})`;
          converted =
            converted.substring(0, match.index) +
            markdownLink +
            converted.substring(match.lastIndex);
        }
      }

      // Preserve line breaks by converting single newlines to double newlines
      // This ensures text line breaks are preserved in Markdown rendering
      converted = converted.replace(/\n/g, "\n\n");

      return converted;
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
    // For source-only contacts, query their external account mapping
    const sourceOnlyActorIds = actors
      .filter((a) => !a.email)
      .map((a) => a.id);
    if (sourceOnlyActorIds.length > 0) {
      const mappings = await plot.db
        .selectFrom("contact_external_account")
        .select(["contact_id", "provider", "account_id"])
        .where("contact_id", "in", sourceOnlyActorIds)
        .execute();
      for (const m of mappings) {
        actorBySource.set(
          `${m.provider}:${m.account_id}`,
          m.contact_id as ActorId
        );
      }
    }
    // Map each newContact index to its created actor
    for (let i = 0; i < newContacts.length; i++) {
      const contact = newContacts[i];
      const byEmail =
        contact.email && actorByEmail.get(contact.email.toLowerCase());
      const bySource =
        contact.source &&
        actorBySource.get(`${contact.source.provider}:${contact.source.accountId}`);
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
 * @returns PreparedThread containing all data needed for insertion
 */
export async function prepareThreadForDb(
  plot: Plot,
  activity: NewThread | NewThreadWithNotes
): Promise<PreparedThread> {
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

  if ("priority" in activity && activity.priority?.id) {
    targetPriorityId = activity.priority.id;
  } else {
    // Classify via user-defined priority rules.
    const ownerUserId = await plot.getUserId();

    const matched = await rpc(plot.db, "classify_thread_for_user", {
      p_user_id: ownerUserId,
      p_embedding: embeddingJson ?? null,
    });

    const matchedPriorityId =
      typeof matched === "string"
        ? matched
        : Array.isArray(matched)
          ? (matched[0] as string | undefined)
          : (matched as string | null | undefined);
    targetPriorityId =
      matchedPriorityId ?? (await plot.getDefaultPriorityId());
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

  // Resolve accessContacts from NewContact[] (emails) to ActorId[]
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
