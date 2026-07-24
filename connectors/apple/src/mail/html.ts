/**
 * Heuristic: does this body string look like HTML rather than plain text?
 *
 * Used only for single-part message bodies where the IMAP tool couldn't
 * determine the content type (BODY[TEXT] omits the Content-Type header). Multi-
 * part messages already resolve text vs html correctly upstream. A false
 * positive is low-harm (the server converts html→markdown either way); a false
 * negative would render raw tags, so we bias toward detecting real markup.
 */
export function looksLikeHtml(s: string): boolean {
  if (!s) return false;
  // A doctype or <html>/<body> is conclusive.
  if (/<!doctype html|<html[\s>]|<body[\s>]/i.test(s)) return true;
  // Otherwise require a real, closed block/inline tag we'd expect in email HTML.
  return /<(div|p|br|table|tr|td|span|a|img|ul|ol|li|h[1-6]|blockquote)(\s[^<>]*)?\/?>/i.test(
    s
  );
}
