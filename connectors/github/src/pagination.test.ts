import { describe, expect, it } from "vitest";
import { fetchPagedList, MAX_COMMENT_PAGES } from "./pagination";

/** Build a page of `n` placeholder items. */
const page = (n: number) => Array.from({ length: n }, (_, i) => ({ id: i }));

/**
 * Fake source whose `githubFetch` serves a preconfigured list of pages,
 * indexed by the `page=` query param. An entry of `{ ok: false }` models a
 * non-OK response; anything else is served as a JSON array. Records the paths
 * requested so tests can assert the exact number of requests issued.
 */
function makeSource(pages: (unknown[] | { ok: false })[]): {
  source: { githubFetch(token: string, path: string): Promise<Response> };
  paths: string[];
} {
  const paths: string[] = [];
  const source = {
    githubFetch: async (_token: string, path: string) => {
      paths.push(path);
      const pageNum = Number(new URLSearchParams(path.split("?")[1]).get("page"));
      const entry = pages[pageNum - 1];
      if (!entry || (entry as { ok?: boolean }).ok === false) {
        return { ok: false, status: 403, json: async () => [] } as unknown as Response;
      }
      return { ok: true, json: async () => entry } as unknown as Response;
    },
  };
  return { source, paths };
}

describe("fetchPagedList", () => {
  it("exposes a comment-page cap of 3 (300 items per list)", () => {
    expect(MAX_COMMENT_PAGES).toBe(3);
  });

  it("returns everything and stops after one request when the first page is short", async () => {
    const { source, paths } = makeSource([page(30)]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?per_page=100&page=${p}`);
    expect(items).toHaveLength(30);
    expect(paths).toEqual(["/x?per_page=100&page=1"]);
  });

  it("returns an empty list (one request) when the first page is empty", async () => {
    const { source, paths } = makeSource([[]]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?page=${p}`);
    expect(items).toEqual([]);
    expect(paths).toHaveLength(1);
  });

  it("stops early on the first short page even below the cap", async () => {
    const { source, paths } = makeSource([page(100), page(50)]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?page=${p}`);
    expect(items).toHaveLength(150);
    expect(paths).toEqual(["/x?page=1", "/x?page=2"]);
  });

  it("caps at MAX_COMMENT_PAGES and never requests past it when every page is full", async () => {
    const { source, paths } = makeSource([page(100), page(100), page(100), page(100)]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?page=${p}`);
    expect(items).toHaveLength(300);
    // Never issued a 4th request despite a full 3rd page.
    expect(paths).toEqual(["/x?page=1", "/x?page=2", "/x?page=3"]);
  });

  it("respects an explicit maxPages argument", async () => {
    const { source, paths } = makeSource([page(100), page(100), page(100)]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?page=${p}`, 2);
    expect(items).toHaveLength(200);
    expect(paths).toHaveLength(2);
  });

  it("returns the pages fetched so far (best-effort) when a later page is non-OK", async () => {
    const { source, paths } = makeSource([page(100), { ok: false }]);
    const items = await fetchPagedList(source, "tok", (p) => `/x?page=${p}`);
    expect(items).toHaveLength(100);
    expect(paths).toEqual(["/x?page=1", "/x?page=2"]);
  });
});
