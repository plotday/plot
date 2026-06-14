import { describe, expect, it } from "vitest";
import { extractLinkCandidates } from "./extract-link-candidates";

describe("extractLinkCandidates", () => {
  it("pairs anchor text with href", () => {
    const html = `<p>Hi</p><a href="https://acme.com/confirm?t=abc">Confirm email</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "Confirm email", href: "https://acme.com/confirm?t=abc" },
    ]);
  });
  it("collapses inner tags and whitespace in anchor text", () => {
    const html = `<a href="https://x.io/v"><b>Verify</b>\n  account</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "Verify account", href: "https://x.io/v" },
    ]);
  });
  it("ignores anchors without an href and non-http schemes", () => {
    const html = `<a>nope</a><a href="mailto:x@y.z">mail</a><a href="https://ok.io/c">go</a>`;
    expect(extractLinkCandidates(html)).toEqual([
      { text: "go", href: "https://ok.io/c" },
    ]);
  });
  it("returns [] for empty/no-anchor html", () => {
    expect(extractLinkCandidates("<p>no links</p>")).toEqual([]);
    expect(extractLinkCandidates("")).toEqual([]);
  });
});
