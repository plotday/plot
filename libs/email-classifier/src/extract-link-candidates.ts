export type LinkCandidate = { text: string; href: string };

const ANCHOR_RE = /<a\b[^>]*?\bhref\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi;
const TAG_RE = /<[^>]+>/g;

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&nbsp;/gi, " ");
}

/** Extract visible-text → href pairs from email HTML. http(s) only. */
export function extractLinkCandidates(html: string): LinkCandidate[] {
  if (!html) return [];
  const out: LinkCandidate[] = [];
  for (const m of html.matchAll(ANCHOR_RE)) {
    const href = decodeEntities((m[2] ?? m[3] ?? m[4] ?? "").trim());
    if (!/^https?:\/\//i.test(href)) continue;
    const text = decodeEntities(m[5].replace(TAG_RE, " "))
      .replace(/\s+/g, " ")
      .trim();
    out.push({ text, href });
  }
  return out;
}
