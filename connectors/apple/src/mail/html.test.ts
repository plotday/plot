import { describe, expect, it } from "vitest";

import { looksLikeHtml } from "./html";

describe("looksLikeHtml", () => {
  it("detects a doctype / html / body / common block tags", () => {
    expect(looksLikeHtml("<!DOCTYPE html><html><body>hi</body></html>")).toBe(true);
    expect(looksLikeHtml("<div class='x'>hi</div>")).toBe(true);
    expect(looksLikeHtml("<p>hello <a href='#'>link</a></p>")).toBe(true);
    expect(looksLikeHtml("<table><tr><td>x</td></tr></table>")).toBe(true);
  });

  it("treats plain text (even with a stray angle bracket) as not html", () => {
    expect(looksLikeHtml("Hi Kris,\n\nCan we meet at 3pm? Thanks.")).toBe(false);
    expect(looksLikeHtml("a < b and c > d")).toBe(false);
    expect(looksLikeHtml("")).toBe(false);
  });
});
