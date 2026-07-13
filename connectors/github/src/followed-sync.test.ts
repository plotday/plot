import { describe, expect, it } from "vitest";
import { parseFollowedNotifications, syncFollowedItems, type FollowedSource } from "./followed-sync";
import type { GitHubNotification } from "./github";

function makeNotification(
  overrides: Omit<Partial<GitHubNotification>, "subject"> & {
    subject?: Partial<GitHubNotification["subject"]>;
  } = {},
): GitHubNotification {
  const { subject, ...rest } = overrides;
  return {
    id: "1",
    reason: "subscribed",
    updated_at: "2026-07-10T00:00:00Z",
    repository: { full_name: "acme/web", owner: { login: "acme" }, name: "web" },
    subject: {
      title: "A bug",
      url: "https://api.github.com/repos/acme/web/issues/42",
      latest_comment_url: null,
      type: "Issue",
      ...subject,
    },
    ...rest,
  };
}

describe("parseFollowedNotifications", () => {
  const noneEnabled = () => false;

  it("maps an Issue notification to an issue ref", () => {
    const refs = parseFollowedNotifications([makeNotification()], noneEnabled);
    expect(refs).toEqual([
      { owner: "acme", repo: "web", repositoryId: "acme/web", number: 42, type: "issue" },
    ]);
  });

  it("maps a PullRequest notification to a pull_request ref", () => {
    const refs = parseFollowedNotifications(
      [
        makeNotification({
          subject: {
            type: "PullRequest",
            url: "https://api.github.com/repos/acme/web/pulls/7",
          },
        }),
      ],
      noneEnabled,
    );
    expect(refs).toEqual([
      { owner: "acme", repo: "web", repositoryId: "acme/web", number: 7, type: "pull_request" },
    ]);
  });

  it("skips non-issue/PR subject types", () => {
    const refs = parseFollowedNotifications(
      [makeNotification({ subject: { type: "Release" } })],
      noneEnabled,
    );
    expect(refs).toEqual([]);
  });

  it("skips notifications whose repo is already an enabled channel", () => {
    const refs = parseFollowedNotifications(
      [makeNotification()],
      (id) => id === "acme/web",
    );
    expect(refs).toEqual([]);
  });

  it("dedupes the same item appearing twice", () => {
    const refs = parseFollowedNotifications(
      [makeNotification({ id: "1" }), makeNotification({ id: "2" })],
      noneEnabled,
    );
    expect(refs).toHaveLength(1);
  });

  it("skips notifications with an unparseable subject url", () => {
    const refs = parseFollowedNotifications(
      [makeNotification({ subject: { url: null } })],
      noneEnabled,
    );
    expect(refs).toEqual([]);
  });
});

function makeFakeSource(opts: {
  token?: string | null;
  notifications?: GitHubNotification[];
  enabled?: string[];
  store?: Record<string, unknown>;
}): {
  source: FollowedSource;
  saved: any[];
  store: Record<string, unknown>;
  paths: string[];
} {
  const store: Record<string, unknown> = { ...(opts.store ?? {}) };
  const saved: any[] = [];
  const paths: string[] = [];
  const source = {
    getAccountToken: async () => (opts.token === undefined ? "fake-token" : opts.token),
    githubFetch: async (_token: string, path: string) => {
      paths.push(path);
      if (path.startsWith("/notifications")) {
        // single page
        return { ok: true, json: async () => (path.includes("page=1") ? opts.notifications ?? [] : []) } as any;
      }
      if (path.includes("/comments")) {
        // converters fetch comments (with a `?per_page=...` query string) and
        // iterate the result as an array — return empty. `.includes` (not
        // `.endsWith`) is required because the query string follows.
        return { ok: true, json: async () => [] } as any;
      }
      // issue/PR fetch: return a minimal item the converters accept
      return {
        ok: true,
        json: async () => ({
          id: 1,
          number: Number(path.split("/").pop()),
          title: "Item",
          body: "",
          state: "open",
          html_url: "https://github.com/acme/web/issues/42",
          created_at: "2026-07-01T00:00:00Z",
          updated_at: "2026-07-01T00:00:00Z",
          closed_at: null,
          merged_at: null,
          user: { id: 1, login: "octocat" },
          assignee: null,
          assignees: [],
          draft: false,
          base: { repo: { full_name: "acme/web", owner: { login: "acme" }, name: "web" } },
        }),
      } as any;
    },
    saveLink: async (link: any) => {
      saved.push(link);
    },
    listStoreKeys: async (prefix: string) =>
      (opts.enabled ?? []).map((r) => `${prefix}${r}`),
    get: async <T>(key: string) => (store[key] as T) ?? null,
    set: async <T>(key: string, value: T) => {
      store[key] = value;
    },
    userToContact: (user: { id: number; login: string }) => ({
      email: `${user.id}@users.noreply.github.com`,
      name: user.login,
      source: { accountId: String(user.id) },
    }),
  } as FollowedSource;
  return { source, saved, store, paths };
}

describe("syncFollowedItems", () => {
  it("no-ops without saving or marking initial done when no token", async () => {
    const { source, saved, store } = makeFakeSource({ token: null });
    await syncFollowedItems(source);
    expect(saved).toEqual([]);
    expect(store.followed_initial_done).toBeUndefined();
  });

  it("syncs a followed issue and tags it syncableId=followed", async () => {
    const { source, saved, store } = makeFakeSource({
      notifications: [
        {
          id: "1",
          reason: "subscribed",
          updated_at: "2026-07-10T00:00:00Z",
          repository: { full_name: "acme/web", owner: { login: "acme" }, name: "web" },
          subject: {
            title: "A bug",
            url: "https://api.github.com/repos/acme/web/issues/42",
            latest_comment_url: null,
            type: "Issue",
          },
        },
      ],
    });
    await syncFollowedItems(source);
    expect(saved).toHaveLength(1);
    expect(saved[0].meta.syncableId).toBe("followed");
    expect(saved[0].unread).toBe(false); // initial sync => window-filterable
    expect(store.followed_initial_done).toBe(true);
  });

  it("skips a followed item whose repo is already an enabled channel", async () => {
    const { source, saved } = makeFakeSource({
      enabled: ["acme/web"],
      notifications: [
        {
          id: "1",
          reason: "subscribed",
          updated_at: "2026-07-10T00:00:00Z",
          repository: { full_name: "acme/web", owner: { login: "acme" }, name: "web" },
          subject: {
            title: "A bug",
            url: "https://api.github.com/repos/acme/web/issues/42",
            latest_comment_url: null,
            type: "Issue",
          },
        },
      ],
    });
    await syncFollowedItems(source);
    expect(saved).toEqual([]);
  });
});
