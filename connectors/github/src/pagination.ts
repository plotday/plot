/**
 * Bounded pagination for GitHub list endpoints (issue/PR comments, reviews).
 *
 * A single item conversion (`convertIssueToLink` / `convertPRToThread`) can be
 * invoked up to 50 times per connector execution (a full channel-sync batch or
 * a full followed-items notifications page), and every `githubFetch` counts
 * against the runtime's per-execution request budget (~1000 requests; see
 * `twister/docs/RUNTIME.md`). An item with thousands of comments must therefore
 * not fetch one request per 100 comments unbounded — a handful of such items
 * would exhaust the budget and kill the execution.
 *
 * `fetchPagedList` caps the pages fetched per list at `MAX_COMMENT_PAGES`. Items
 * under the cap fetch everything (the loop stops on the first short page, so the
 * common case — well under 100 comments — is a single request). Items over it
 * keep the first `MAX_COMMENT_PAGES` pages; callers order the endpoint
 * newest-first (`sort=created&direction=desc`) where the API supports it so the
 * retained pages are the most recent, most relevant comments.
 */

/**
 * Max pages (100 items each) fetched per comment/review list, per item. 3 → up
 * to 300 of each list type. This bounds a single execution's request count:
 * worst case 50 items × (3 lists × 3 pages) ≈ 450 comment requests for PRs,
 * well under the ~1000 budget.
 */
export const MAX_COMMENT_PAGES = 3;

/**
 * Fetch up to `maxPages` pages (100 items each) from a GitHub list endpoint,
 * concatenated in fetch order. `pathForPage(page)` builds the request path for
 * a given 1-based page number.
 *
 * Stops early on the first short page (fewer than 100 items = the last page).
 * On a non-OK response, returns the items gathered so far — partial comments
 * are better than none, matching the converters' pre-existing best-effort
 * behavior when a comment fetch fails mid-item.
 */
export async function fetchPagedList<T>(
  source: { githubFetch(token: string, path: string): Promise<Response> },
  token: string,
  pathForPage: (page: number) => string,
  maxPages: number = MAX_COMMENT_PAGES,
): Promise<T[]> {
  const items: T[] = [];
  for (let page = 1; page <= maxPages; page++) {
    const response = await source.githubFetch(token, pathForPage(page));
    if (!response.ok) break;
    const batch: T[] = await response.json();
    items.push(...batch);
    if (batch.length < 100) break;
  }
  return items;
}
