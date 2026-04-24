/**
 * Conversion helpers for connectors that bridge Plot markdown to external
 * systems that store content as plain text (Google Drive comments, Todoist
 * comments, Airtable cells, Attio notes, etc.).
 *
 * Both functions are pure and run in-process inside the connector's twist
 * runtime — no RPC boundary is crossed, so they are cheap to call on every
 * `onNoteCreated` / `onNoteUpdated`.
 */

/**
 * Render Markdown as plain text while preserving document structure.
 *
 * Numbered lists authored as `1. / 1. / 1.` in markdown are renumbered to
 * `1. / 2. / 3.` so the plain-text reader sees real numbers. Bullet
 * markers, headings content, blockquotes, and paragraph breaks survive;
 * emphasis markers, code fences, and image syntax are dropped.
 *
 * Mentions `[Name](#@UUID)` render as `@Name`. Links `[text](url)`
 * collapse to their label, falling back to the URL when the label is
 * empty or identical to the URL.
 *
 * Use this when writing a Plot note to an external API that stores
 * content verbatim as plain text. Pair the result with a matching
 * `NoteWriteBackResult.externalContent` so the sync baseline round-trips.
 */
export function markdownToPlainText(markdown: string): string {
  let text = markdown;

  text = text.replace(/```[a-zA-Z0-9]*\n([\s\S]*?)```/g, "$1");
  text = text.replace(/`([^`]+)`/g, "$1");

  text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, "");

  text = text.replace(/\[([^\]]+)\]\(#@[^)]+\)/g, "@$1");

  text = text.replace(/\[([^\]]*)\]\(<?([^>)]+)>?\)/g, (_, label, url) => {
    if (!label) return url;
    if (label === url) return url;
    return label;
  });

  text = text.replace(/^\s{0,3}#{1,6}\s+/gm, "");
  text = text.replace(/^\s{0,3}>\s?/gm, "");

  text = text.replace(/(\*\*|__)(.+?)\1/g, "$2");
  text = text.replace(/(?<![*_])([*_])([^*_\n]+)\1(?![*_])/g, "$2");
  text = text.replace(/~~(.+?)~~/g, "$1");

  text = text.replace(/^\s{0,3}(?:-\s?){3,}\s*$/gm, "");
  text = text.replace(/^\s{0,3}(?:\*\s?){3,}\s*$/gm, "");
  text = text.replace(/^\s{0,3}(?:_\s?){3,}\s*$/gm, "");

  text = renumberNumberedLists(text);

  text = text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");

  text = text.replace(/\n{3,}/g, "\n\n");

  return text.trim();
}

function renumberNumberedLists(text: string): string {
  const lines = text.split("\n");
  const numberedRe = /^(\s*)(\d+)\.(\s+)(.*)$/;

  let currentIndent: string | null = null;
  let counter = 0;

  for (let i = 0; i < lines.length; i++) {
    const match = numberedRe.exec(lines[i]);
    if (!match) {
      currentIndent = null;
      counter = 0;
      continue;
    }
    const [, indent, , space, content] = match;
    if (indent !== currentIndent) {
      currentIndent = indent;
      counter = 1;
    } else {
      counter += 1;
    }
    lines[i] = `${indent}${counter}.${space}${content}`;
  }

  return lines.join("\n");
}
