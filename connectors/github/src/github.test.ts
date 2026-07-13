import { describe, expect, it, vi } from "vitest";
import { GitHub, parseRateLimit } from "./github";

/**
 * `onNoteCreated`/`onNoteUpdated` are real methods on the `GitHub` class,
 * but the class itself requires the twist runtime's `build()` machinery to
 * construct (tool wiring, etc.) — not available in a unit test. Since the
 * methods only touch `this.getToken` / `this.githubFetch` (both public,
 * duck-typed helpers) plus the imported pr-sync/issue-sync functions (which
 * themselves only need those same two methods on their `source` param), we
 * can invoke the unbound prototype methods against a plain fake object
 * implementing just `githubFetch` and `getToken`, per the pattern used
 * throughout `pr-sync.test.ts` / `reactions.test.ts`.
 */
function makeFakeSource(handleFetch: (path: string, options: any) => any) {
  return {
    getToken: async () => "fake-token",
    githubFetch: async (_token: string, path: string, options: any) =>
      handleFetch(path, options),
  } as any;
}

describe("onNoteCreated review-comment reply routing", () => {
  it("routes to addReviewCommentReply when reNoteKey is a review-comment key", async () => {
    let capturedPath = "";
    let capturedBody = "";
    const fakeSource = makeFakeSource((path, options) => {
      capturedPath = path;
      capturedBody = options.body;
      return { ok: true, json: async () => ({ id: 999, body: "Good point" }) };
    });

    const thread = {
      meta: { owner: "acme", repo: "repo", prNumber: 42, reNoteKey: "review-comment-555" },
    } as any;
    const note = { content: "Good point" } as any;

    const result = await GitHub.prototype.onNoteCreated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/pulls/42/comments");
    expect(JSON.parse(capturedBody)).toEqual({ body: "Good point", in_reply_to: 555 });
    expect(result).toEqual({ key: "review-comment-999", externalContent: "Good point" });
  });

  it("falls back to addPRComment when reNoteKey is absent", async () => {
    let capturedPath = "";
    const fakeSource = makeFakeSource((path) => {
      capturedPath = path;
      return { ok: true, json: async () => ({ id: 111, body: "Top-level comment" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { content: "Top-level comment" } as any;

    const result = await GitHub.prototype.onNoteCreated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/issues/42/comments");
    expect(result).toEqual({ key: "comment-111", externalContent: "Top-level comment" });
  });
});

describe("onNoteUpdated review-comment edit routing", () => {
  it("routes a review-comment- key to the pulls/comments PATCH endpoint", async () => {
    let capturedPath = "";
    let capturedMethod = "";
    const fakeSource = makeFakeSource((path, options) => {
      capturedPath = path;
      capturedMethod = options.method;
      return { ok: true, json: async () => ({ body: "Edited" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { key: "review-comment-555", content: "Edited" } as any;

    const result = await GitHub.prototype.onNoteUpdated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/pulls/comments/555");
    expect(capturedMethod).toBe("PATCH");
    expect(result).toEqual({ externalContent: "Edited" });
  });

  it("routes a comment- key to the issues/comments PATCH endpoint", async () => {
    let capturedPath = "";
    const fakeSource = makeFakeSource((path) => {
      capturedPath = path;
      return { ok: true, json: async () => ({ body: "Edited" }) };
    });

    const thread = { meta: { owner: "acme", repo: "repo", prNumber: 42 } } as any;
    const note = { key: "comment-777", content: "Edited" } as any;

    const result = await GitHub.prototype.onNoteUpdated.call(fakeSource, note, thread);

    expect(capturedPath).toBe("/repos/acme/repo/issues/comments/777");
    expect(result).toEqual({ externalContent: "Edited" });
  });
});

describe("default-enable everything", () => {
  it("marks every owner channel enabledByDefault: true", async () => {
    const fakeSource = {
      fetchAllRepos: async () => [
        { full_name: "acme/web", owner: { login: "acme" }, name: "web" },
        { full_name: "octo/dotfiles", owner: { login: "octo" }, name: "dotfiles" },
      ],
    } as any;

    const channels = await GitHub.prototype.getChannels.call(
      fakeSource,
      {} as any,
      { token: "fake-token" } as any,
    );

    expect(channels).toHaveLength(2);
    expect(channels.every((c: any) => c.enabledByDefault === true)).toBe(true);
  });
});

describe("getAccountToken", () => {
  it("returns the token from the first enabled channel", async () => {
    const fakeSource = {
      listStoreKeys: async (prefix: string) => [`${prefix}acme/web`, `${prefix}octo/dotfiles`],
      getToken: async (channelId: string) =>
        channelId === "acme/web" ? "tok-acme" : "tok-octo",
    } as any;
    const token = await GitHub.prototype.getAccountToken.call(fakeSource);
    expect(token).toBe("tok-acme");
  });

  it("returns null when no channel is enabled", async () => {
    const fakeSource = { listStoreKeys: async () => [] } as any;
    const token = await GitHub.prototype.getAccountToken.call(fakeSource);
    expect(token).toBeNull();
  });
});

describe("getToken account-token fallback", () => {
  it("borrows the account token for a repo with no enabled channel (e.g. a followed item)", async () => {
    const fakeSource: any = {
      get: async () => null, // no org_for_repo mapping
      tools: {
        integrations: {
          get: async (id: string) =>
            id === "acme/web" ? { token: "chan-tok" } : null,
        },
      },
      listStoreKeys: async (prefix: string) => [`${prefix}acme/web`],
    };
    // Wire the two interdependent prototype methods onto the fake so their
    // internal this.getToken / this.getAccountToken calls resolve.
    fakeSource.getToken = (GitHub.prototype as any).getToken;
    fakeSource.getAccountToken = (GitHub.prototype as any).getAccountToken;

    // octo/oss is NOT an enabled channel; getToken must borrow acme/web's token.
    const token = await fakeSource.getToken("octo/oss");
    expect(token).toBe("chan-tok");
  });
});

describe("onOptionsChanged followed toggle", () => {
  it("schedules the followed poll and runs an initial sync when turned on", async () => {
    const calls: string[] = [];
    const fakeSource = {
      tools: { store: { list: async () => [] } },
      listStoreKeys: async () => [],
      createCallback: async (_fn: any) => ({ cb: "followed" }),
      scheduleRecurring: async (key: string) => calls.push(`schedule:${key}`),
      cancelScheduledTask: async (key: string) => calls.push(`cancel:${key}`),
      runTask: async (_cb: any) => calls.push("runTask"),
      pollFollowed: async () => {},
      startFollowedPoll: (GitHub.prototype as any).startFollowedPoll,
    } as any;

    await GitHub.prototype.onOptionsChanged.call(
      fakeSource,
      { syncFollowed: false, syncPullRequests: true, syncIssues: true },
      { syncFollowed: true, syncPullRequests: true, syncIssues: true },
    );

    expect(calls).toContain("schedule:followed-poll");
    expect(calls).toContain("runTask");
  });

  it("cancels the followed poll when turned off", async () => {
    const calls: string[] = [];
    const fakeSource = {
      tools: { store: { list: async () => [] } },
      listStoreKeys: async () => [],
      createCallback: async (_fn: any) => ({ cb: "followed" }),
      scheduleRecurring: async (key: string) => calls.push(`schedule:${key}`),
      cancelScheduledTask: async (key: string) => calls.push(`cancel:${key}`),
      runTask: async (_cb: any) => calls.push("runTask"),
      pollFollowed: async () => {},
      startFollowedPoll: (GitHub.prototype as any).startFollowedPoll,
    } as any;

    await GitHub.prototype.onOptionsChanged.call(
      fakeSource,
      { syncFollowed: true, syncPullRequests: true, syncIssues: true },
      { syncFollowed: false, syncPullRequests: true, syncIssues: true },
    );

    expect(calls).toContain("cancel:followed-poll");
  });
});

function makeHeaders(entries: Record<string, string>) {
  return {
    get: (name: string) => entries[name.toLowerCase()] ?? null,
  } as any;
}

describe("parseRateLimit", () => {
  it("returns not-limited for a 200 response", () => {
    const response = { status: 200, headers: makeHeaders({}) } as any;
    expect(parseRateLimit(response)).toEqual({ limited: false, resetAt: null });
  });

  it("detects a primary rate limit from a 403 with remaining=0 and a reset time", () => {
    const unixSecs = Math.floor(Date.now() / 1000) + 3600;
    const response = {
      status: 403,
      headers: makeHeaders({
        "x-ratelimit-remaining": "0",
        "x-ratelimit-reset": String(unixSecs),
      }),
    } as any;
    const result = parseRateLimit(response);
    expect(result.limited).toBe(true);
    expect(result.resetAt).toEqual(new Date(unixSecs * 1000));
  });

  it("detects a secondary rate limit from a 429 with retry-after", () => {
    const response = {
      status: 429,
      headers: makeHeaders({ "retry-after": "30" }),
    } as any;
    const result = parseRateLimit(response);
    expect(result.limited).toBe(true);
    expect(result.resetAt).toBeInstanceOf(Date);
    expect(result.resetAt!.getTime()).toBeGreaterThan(Date.now());
  });

  it("does not treat a permission 403 (remaining > 0) as rate-limited", () => {
    const response = {
      status: 403,
      headers: makeHeaders({ "x-ratelimit-remaining": "17" }),
    } as any;
    expect(parseRateLimit(response)).toEqual({ limited: false, resetAt: null });
  });

  it("reports limited with a null resetAt when remaining=0 but no reset header", () => {
    const response = {
      status: 403,
      headers: makeHeaders({ "x-ratelimit-remaining": "0" }),
    } as any;
    // A missing reset header must yield null (not epoch-0 from Number(null)).
    expect(parseRateLimit(response)).toEqual({ limited: true, resetAt: null });
  });
});

describe("setupWebhook no-admin skip", () => {
  it("returns early without POSTing a webhook when repo_no_admin_<id> is set", async () => {
    let postCalled = false;
    const fakeSource = {
      get: async (key: string) => (key === "repo_no_admin_acme/web" ? true : null),
      set: async () => {},
      getToken: async () => "fake-token",
      tools: {
        network: {
          createWebhook: async () => "https://example.com/hook",
        },
      },
      githubFetch: async () => {
        postCalled = true;
        return { ok: true, json: async () => ({ id: 1 }) };
      },
    } as any;

    await GitHub.prototype.setupWebhook.call(fakeSource, "acme/web");

    expect(postCalled).toBe(false);
  });
});

describe("pollFollowed overlap guard", () => {
  function guardFake(store: Record<string, unknown>) {
    let accountTokenCalls = 0;
    const fake: any = {
      get: async (k: string) => store[k] ?? null,
      set: async (k: string, v: unknown) => {
        store[k] = v;
      },
      // syncFollowedItems calls this first; returning null makes it a no-op
      // pass, so a single call is our proxy for "the drain actually ran".
      getAccountToken: async () => {
        accountTokenCalls++;
        return null;
      },
      listStoreKeys: async () => [],
      createCallback: async () => ({}),
      runTask: async () => {},
    };
    return { fake, calls: () => accountTokenCalls };
  }

  it("skips a recurring tick while a drain is in flight (cursor + fresh heartbeat)", async () => {
    const { fake, calls } = guardFake({
      followed_sync_state: { page: 2 },
      followed_poll_heartbeat: new Date().toISOString(),
    });
    await GitHub.prototype.pollFollowed.call(fake);
    expect(calls()).toBe(0); // guarded: the drain (→ getAccountToken) never ran
  });

  it("does not skip a continuation call even with a cursor + fresh heartbeat", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { fake, calls } = guardFake({
      followed_sync_state: { page: 2 },
      followed_poll_heartbeat: new Date().toISOString(),
    });
    await GitHub.prototype.pollFollowed.call(fake, true);
    warn.mockRestore();
    expect(calls()).toBe(1); // continuation bypasses the guard and proceeds
  });

  it("does not skip when the heartbeat is stale (a crashed chain)", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { fake, calls } = guardFake({
      followed_sync_state: { page: 2 },
      followed_poll_heartbeat: new Date(Date.now() - 31 * 60 * 1000).toISOString(),
    });
    await GitHub.prototype.pollFollowed.call(fake);
    warn.mockRestore();
    expect(calls()).toBe(1); // stale heartbeat → resume the pass
  });
});
