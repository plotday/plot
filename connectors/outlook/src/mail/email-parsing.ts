// Quote-stripping helpers shared with the Gmail connector (copied from
// gmail/src/gmail-api.ts — keep in sync).

/**
 * Locates the start of an Outlook-style "From: / Sent: / To: / Subject:"
 * reply header even when the field labels are not wrapped in `<b>` or
 * `<strong>` — e.g. corporate Exchange / Outlook variants that put the
 * label in a `<span style="font-weight:bold">`, a `<font>` tag, or a
 * plain `MsoNormal` paragraph with no inline bold at all.
 *
 * Strategy: replace every HTML tag with a same-length run of spaces so
 * character offsets in the stripped text still map 1:1 back to the
 * original. Then require each label to start at a structural boundary
 * (start of string, a real newline, or 3+ whitespace chars — the smallest
 * gap any HTML block tag produces when replaced). That anchor is what
 * keeps user-written prose from false-matching.
 *
 * Returns the index of "From:" in the original content, or -1 if no
 * Outlook reply header is found.
 */
export function findOutlookHeaderTagAgnostic(content: string): number {
  const flat = content.replace(/<[^>]*>/g, (m) => " ".repeat(m.length));
  const re =
    /(?<=^|\n|[ \t]{3,})From:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})Sent:[\s\S]{0,800}?(?<=\n|[ \t]{3,})To:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})Subject:/i;
  const m = flat.match(re);
  return m?.index ?? -1;
}

/**
 * Strips quoted reply content from an email body.
 * Since Plot shows each message as a separate note in a thread,
 * the quoted previous messages are redundant noise.
 */
export function stripQuotedReply(
  content: string,
  contentType: "text" | "html"
): string {
  if (!content) return content;

  // Forwarded messages: the forwarded email IS the content the user wants to
  // read. Gmail/Apple Mail wrap a forward in the same quote container Gmail uses
  // for reply quotes, so the reply-stripping below would delete the whole body
  // and leave an empty note. Keep the content as-is when it's a forward whose
  // marker precedes any reply boundary.
  if (isForwardedMessage(content)) return content;

  if (contentType === "html") {
    // Different mail clients wrap quoted history in different containers.
    // Collect every recognized quote boundary and cut at the EARLIEST one:
    // once the first boundary is reached, everything after it is quoted
    // history, even if it contains nested markers from a different client
    // (e.g. an Apple Mail reply whose quote embeds the Gmail original, which
    // still carries its own `gmail_quote` div deeper in the byte stream).
    const candidates: number[] = [];

    // Gmail wraps quoted replies in <div class="gmail_quote">.
    const gmailQuoteIdx = content.search(
      /<div[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (gmailQuoteIdx !== -1) candidates.push(gmailQuoteIdx);

    // Some clients use <blockquote> with the gmail_quote class.
    const gmailBlockquoteIdx = content.search(
      /<blockquote[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (gmailBlockquoteIdx !== -1) candidates.push(gmailBlockquoteIdx);

    // Apple Mail (Mail.app / iPhone Mail) wraps the "On <date>, <name>
    // wrote:" attribution and the quoted history in <blockquote type="cite">.
    const appleCiteIdx = content.search(
      /<blockquote[^>]*type\s*=\s*["']cite["'][^>]*>/i
    );
    if (appleCiteIdx !== -1) candidates.push(appleCiteIdx);

    // Yahoo Mail wraps quoted history in <div class="yahoo_quoted"> /
    // <div id="yahoo_quoted_...">.
    const yahooQuotedIdx = content.search(/<div[^>]*yahoo_quoted/i);
    if (yahooQuotedIdx !== -1) candidates.push(yahooQuotedIdx);

    // Microsoft Outlook-style: <div id="appendonsend"></div> or
    // <div id="divRplyFwdMsg"> before the quoted content.
    const outlookDivIdx = content.search(
      /<div[^>]*id\s*=\s*["'](?:appendonsend|divRplyFwdMsg)["'][^>]*>/i
    );
    if (outlookDivIdx !== -1) candidates.push(outlookDivIdx);

    // Outlook (desktop, OWA, and corporate Exchange clients) wraps replies
    // with a "From: / Sent: / To: / Subject:" header block. The markup
    // varies — sometimes `<b>` or `<strong>`, sometimes `<span
    // style="font-weight:bold">`, sometimes a `MsoNormal` paragraph with
    // no inline bold at all (Gowling-style corporate Exchange). Try the
    // tight bold-wrapped pattern first, then fall back to a tag-agnostic
    // boundary match.
    const outlookHeaderRe =
      /<(b|strong)[^>]*>\s*From:?\s*<\/\1>[\s\S]{0,1000}<(b|strong)[^>]*>\s*Sent:?\s*<\/\2>[\s\S]{0,1000}<(b|strong)[^>]*>\s*To:?\s*<\/\3>[\s\S]{0,1000}<(b|strong)[^>]*>\s*Subject:?\s*<\/\4>/i;
    const outlookHeaderMatch = content.match(outlookHeaderRe);
    const fromIdx =
      outlookHeaderMatch?.index ?? findOutlookHeaderTagAgnostic(content);
    if (fromIdx !== -1) {
      const lookbackStart = Math.max(0, fromIdx - 1000);
      const lookback = content.substring(lookbackStart, fromIdx);
      // Prefer the latest structural divider (border-top div or <hr>)
      // before the From: tag — that's the user/quoted boundary in
      // Outlook's standard reply format.
      const dividerRe =
        /<hr\b[^>]*>|<div[^>]*style\s*=\s*["'][^"']*border-top\s*:[^"']*["'][^>]*>/gi;
      let lastDivider = -1;
      let match: RegExpExecArray | null;
      while ((match = dividerRe.exec(lookback)) !== null) {
        lastDivider = match.index;
      }
      let cut = fromIdx;
      if (lastDivider !== -1) {
        cut = lookbackStart + lastDivider;
      } else {
        // No divider — cut at the start of the wrapping <p> or <div>.
        const lastP = lookback.lastIndexOf("<p");
        const lastDiv = lookback.lastIndexOf("<div");
        const wrapper = Math.max(lastP, lastDiv);
        if (wrapper !== -1) {
          cut = lookbackStart + wrapper;
        }
      }
      candidates.push(cut);
    }

    if (candidates.length > 0) {
      return content.substring(0, Math.min(...candidates)).trim();
    }

    return content;
  }

  // Plain text: look for "On ... wrote:" followed by quoted lines
  const lines = content.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // "On [date], [name] wrote:" or "On [date], [name] <email> wrote:"
    if (/^On .+ wrote:\s*$/.test(line)) {
      // Verify next non-empty line starts with ">" (actual quoted content)
      const nextContentLine = lines.slice(i + 1).find((l) => l.trim() !== "");
      if (nextContentLine && nextContentLine.trim().startsWith(">")) {
        return lines
          .slice(0, i)
          .join("\n")
          .trim();
      }
    }
  }

  return content;
}

/**
 * Detects a forwarded message so {@link stripQuotedReply} can preserve it.
 * Matches Gmail's dashed "---------- Forwarded message ---------" marker and
 * Apple Mail's "Begin forwarded message:". Returns false when a reply boundary
 * ("On … wrote:") precedes the forward marker — that's a reply quoting a
 * forward, which the reply-stripper should still trim.
 */
function isForwardedMessage(content: string): boolean {
  const fwdIdx = content.search(
    /(-{2,}\s*Forwarded message\s*-{2,}|Begin forwarded message:)/i
  );
  if (fwdIdx === -1) return false;
  const replyIdx = content.search(/On\s[\s\S]{0,200}?\swrote:/i);
  if (replyIdx !== -1 && replyIdx < fwdIdx) return false;
  return true;
}
