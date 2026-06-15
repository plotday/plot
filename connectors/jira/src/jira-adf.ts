/**
 * Symmetric Atlassian Document Format (ADF) text transforms.
 *
 * Jira stores rich text (issue descriptions, comments) as ADF — a nested JSON
 * document. Plot threads carry plain-text/markdown bodies, so the connector
 * converts in both directions on every round-trip:
 *
 *   - write-back: Plot body  → ADF  (`textToADF`)  → stored in Jira
 *   - sync-in:    Jira ADF    → text (`adfToText`)  → Plot note content
 *
 * For the runtime's sync-baseline preservation to work, these two functions
 * MUST round-trip exactly:
 *
 *     adfToText(textToADF(s)) === s.trim()
 *
 * That equality is what lets `onNoteCreated` / `onNoteUpdated` / `onCreateLink`
 * return an `externalContent` baseline (`adfToText(textToADF(body))`) that
 * matches what the next sync-in emits (`adfToText(incomingADF)`) for the same
 * content — so an unchanged note isn't clobbered with its round-tripped form.
 *
 * The earlier inline implementation was asymmetric: `textToADF` split on blank
 * lines (`\n\n`) but `extractTextFromADF` appended a single `\n` after each
 * paragraph, so two paragraphs round-tripped to `a\nb` instead of `a\n\nb`.
 * This module fixes that by having both sides agree that a paragraph boundary
 * is a blank line (`\n\n`).
 */

/** Minimal ADF document shape we read/write. */
export type ADFDoc = {
  version: 1;
  type: "doc";
  content: ADFNode[];
};

type ADFNode = {
  type: string;
  text?: string;
  content?: ADFNode[];
};

/**
 * Convert plain text into an ADF document. Each blank-line-delimited block
 * becomes a single paragraph. The input is trimmed first so leading/trailing
 * blank lines don't create empty paragraphs — keeping the round-trip equal to
 * `text.trim()`.
 */
export function textToADF(text: string): ADFDoc {
  const paragraphs = text
    .trim()
    .split(/\n\n+/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);

  return {
    version: 1,
    type: "doc",
    content: paragraphs.map((paragraph) => ({
      type: "paragraph",
      content: [{ type: "text", text: paragraph }],
    })),
  };
}

/**
 * Extract plain text from an ADF document. Text within a paragraph is
 * concatenated; paragraphs are joined with a blank line (`\n\n`) so the
 * result mirrors `textToADF`'s blank-line block model. The result is trimmed.
 *
 * Accepts `unknown` because inbound ADF can arrive as a string (legacy
 * plain-text bodies) or a malformed/absent value; those yield `""`.
 */
export function adfToText(adf: unknown): string {
  if (!adf || typeof adf !== "object") {
    return "";
  }

  const paragraphs: string[] = [];

  // Collect the text of one block-level node (paragraph/heading) by
  // concatenating all descendant text nodes.
  const collectText = (node: ADFNode): string => {
    let text = node.type === "text" ? (node.text ?? "") : "";
    if (Array.isArray(node.content)) {
      for (const child of node.content) {
        text += collectText(child);
      }
    }
    return text;
  };

  const root = adf as ADFNode;
  if (Array.isArray(root.content)) {
    for (const node of root.content) {
      // Top-level block nodes become their own joined-by-blank-line paragraph.
      paragraphs.push(collectText(node));
    }
  } else {
    // Fallback: a bare node with no top-level content array.
    paragraphs.push(collectText(root));
  }

  return paragraphs
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
    .join("\n\n")
    .trim();
}
