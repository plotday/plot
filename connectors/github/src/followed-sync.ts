import type { NewLinkWithNotes } from "@plotday/twister";
import type { GitHubNotification } from "./github";
import { convertIssueToLink } from "./issue-sync";
import { convertPRToThread } from "./pr-sync";

/** A followed issue/PR resolved from a notification, ready to fetch + sync. */
export interface FollowedRef {
  owner: string;
  repo: string;
  repositoryId: string;
  number: number;
  type: "issue" | "pull_request";
}

/** Notifications per page. */
const PAGE_SIZE = 50;
/** Initial-sync lookback cap (the max plan window; server drops the rest). */
const INITIAL_LOOKBACK_MS = 365 * 24 * 60 * 60 * 1000;
/** Incremental fallback lookback when no prior poll timestamp is stored. */
const INCREMENTAL_FALLBACK_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Minimal duck-typed view of the GitHub connector that followed sync needs.
 * Mirrors the `source` pattern used by issue-sync/pr-sync so the orchestrator
 * is unit-testable with a plain fake.
 */
export interface FollowedSource {
  getAccountToken(): Promise<string | null>;
  githubFetch(token: string, path: string): Promise<Response>;
  saveLink(link: NewLinkWithNotes): Promise<void>;
  listStoreKeys(prefix: string): Promise<string[]>;
  get<T>(key: string): Promise<T | null>;
  set<T>(key: string, value: T): Promise<void>;
  // Used transitively by the converters:
  userToContact(user: { id: number; login: string }): unknown;
}

/**
 * Turn a page of notifications into the issues/PRs worth syncing:
 * only Issue/PullRequest subjects, excluding repos already synced as channels,
 * deduped by repo + number.
 */
export function parseFollowedNotifications(
  notifications: GitHubNotification[],
  isRepoEnabled: (repositoryId: string) => boolean,
): FollowedRef[] {
  const seen = new Set<string>();
  const refs: FollowedRef[] = [];

  for (const n of notifications) {
    const kind =
      n.subject.type === "Issue"
        ? "issue"
        : n.subject.type === "PullRequest"
          ? "pull_request"
          : null;
    if (!kind) continue;

    const repositoryId = n.repository.full_name;
    if (isRepoEnabled(repositoryId)) continue;

    const url = n.subject.url;
    if (!url) continue;
    const numberStr = url.split("/").pop();
    const number = numberStr ? Number(numberStr) : NaN;
    if (!Number.isInteger(number)) continue;

    const key = `${repositoryId}#${number}`;
    if (seen.has(key)) continue;
    seen.add(key);

    refs.push({
      owner: n.repository.owner.login,
      repo: n.repository.name,
      repositoryId,
      number,
      type: kind,
    });
  }

  return refs;
}

/**
 * Poll the GitHub Notifications API for followed issues/PRs and sync them,
 * skipping any repo already covered by an enabled channel. Self-determines
 * initial vs incremental sync via the `followed_initial_done` flag, so it is
 * robust to being called before any channel token exists (it simply retries as
 * initial on the next run).
 */
export async function syncFollowedItems(source: FollowedSource): Promise<void> {
  const token = await source.getAccountToken();
  if (!token) {
    // No enabled channel to borrow the account token from yet. The recurring
    // poll will retry; the initial flag stays unset so the retry is initial.
    console.warn("GitHub followed sync: no account token available yet; skipping");
    return;
  }

  const initialDone = await source.get<boolean>("followed_initial_done");
  const initialSync = !initialDone;

  const sinceIso = initialSync
    ? new Date(Date.now() - INITIAL_LOOKBACK_MS).toISOString()
    : ((await source.get<string>("followed_poll_since")) ??
      new Date(Date.now() - INCREMENTAL_FALLBACK_MS).toISOString());
  const runStartIso = new Date().toISOString();

  // Build the enabled-repo predicate from stored channel state (direct repos
  // and org-provisioned repos both set `sync_enabled_<owner/repo>`).
  const enabledKeys = await source.listStoreKeys("sync_enabled_");
  const enabledRepos = new Set(enabledKeys.map((k) => k.replace("sync_enabled_", "")));
  const isRepoEnabled = (repositoryId: string) => enabledRepos.has(repositoryId);

  // Paginate notifications.
  const notifications: GitHubNotification[] = [];
  let page = 1;
  while (true) {
    const response = await source.githubFetch(
      token,
      `/notifications?all=true&since=${encodeURIComponent(sinceIso)}&per_page=${PAGE_SIZE}&page=${page}`,
    );
    if (!response.ok) {
      throw new Error(
        `Failed to fetch notifications: ${response.status} ${await response.text()}`,
      );
    }
    const batch: GitHubNotification[] = await response.json();
    notifications.push(...batch);
    if (batch.length < PAGE_SIZE) break;
    page++;
  }

  const refs = parseFollowedNotifications(notifications, isRepoEnabled);

  for (const ref of refs) {
    const path =
      ref.type === "issue"
        ? `/repos/${ref.owner}/${ref.repo}/issues/${ref.number}`
        : `/repos/${ref.owner}/${ref.repo}/pulls/${ref.number}`;
    const itemResponse = await source.githubFetch(token, path);
    if (!itemResponse.ok) continue; // item may be gone or inaccessible; skip
    const item = await itemResponse.json();

    const link =
      ref.type === "issue"
        ? await convertIssueToLink(
            source as any,
            token,
            ref.owner,
            ref.repo,
            item,
            ref.repositoryId,
            initialSync,
          )
        : await convertPRToThread(
            source as any,
            token,
            ref.owner,
            ref.repo,
            item,
            ref.repositoryId,
            initialSync,
          );

    if (link) {
      link.meta = {
        ...link.meta,
        syncProvider: "github",
        syncableId: "followed",
      };
      await source.saveLink(link);
    }
  }

  await source.set("followed_poll_since", runStartIso);
  if (initialSync) await source.set("followed_initial_done", true);
}
