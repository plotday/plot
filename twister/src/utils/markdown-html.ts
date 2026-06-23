/**
 * Render Plot Markdown note content to HTML, for connectors that send the
 * note out to a system whose native format is HTML email (Gmail, Outlook
 * Mail). Kept separate from {@link markdownToPlainText} so connectors that
 * only need the plain-text path don't pull the Markdown parser into their
 * bundle (`sideEffects: false` lets the unused module tree-shake away).
 */
import { marked } from "marked";

/**
 * Convert Markdown to an HTML fragment suitable for an email body.
 *
 * - Plot mentions `[Name](#@UUID)` render as plain `@Name` text rather than a
 *   broken link to the internal `#@UUID` href.
 * - GitHub-flavoured Markdown is enabled, and single newlines become `<br>`
 *   (`breaks: true`) so a message reads the way the author wrote it — the same
 *   convention chat-style products (Slack, GitHub comments) use.
 *
 * Returns an HTML fragment (e.g. `<p>…</p>`), not a full document; the caller
 * wraps it for its transport (a `text/html` MIME part, a Graph `body`, etc.).
 * Empty/blank input yields an empty string.
 */
export function markdownToHtml(markdown: string | null | undefined): string {
  if (!markdown || markdown.trim() === "") return "";

  // Render mentions as "@Name" text before parsing so marked doesn't emit an
  // anchor pointing at the internal "#@UUID" href.
  const withMentions = markdown.replace(
    /\[([^\]]+)\]\(#@[^)]+\)/g,
    (_m, name: string) => `@${name}`
  );

  const html = marked.parse(withMentions, {
    async: false,
    gfm: true,
    breaks: true,
  });

  return (html as string).trim();
}
