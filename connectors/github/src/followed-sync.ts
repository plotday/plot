import type { NewLinkWithNotes } from "@plotday/twister";
import type { GitHubNotification } from "./github";
import { parseRateLimit } from "./github";
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

/**
 * Notifications per page — exactly one page is processed per execution.
 *
 * This bounds an execution's WALL-CLOCK, which is a separate constraint from
 * the per-execution request budget that `pagination.ts` bounds. Every ref on a
 * page is processed strictly serially, and each one costs several sequential
 * round-trips (1 item fetch + 1-3 comment/review list fetches + 1 saveLink), so
 * a page of PRs is roughly `PAGE_SIZE * 5` sequential hops at minimum. At 50 a
 * page took ~60s of wall-clock — comfortably inside the ~1000-request budget,
 * but long enough that the platform reset the Durable Object underneath the
 * execution and the run-queue message exhausted its retries. 10 keeps a page
 * near ~12s.
 *
 * Throughput is unchanged: a full page schedules a `runTask` continuation, so
 * a large backlog still drains — just across more, shorter executions.
 *
 * If you raise this, re-check the duration, not just the request count.
 */
export const PAGE_SIZE = 10;
/** Initial-sync lookback cap (the max plan window; server drops the rest). */
const INITIAL_LOOKBACK_MS = 365 * 24 * 60 * 60 * 1000;
/** Incremental fallback lookback when no prior poll timestamp is stored. */
const INCREMENTAL_FALLBACK_MS = 7 * 24 * 60 * 60 * 1000;
/** Store key for the cross-execution batch cursor. */
const SYNC_STATE_KEY = "followed_sync_state";

/** Cross-execution cursor for the followed-items poll. */
interface FollowedSyncState {
  /** 1-based notifications page to fetch next. */
  page: number;
  /** `since` bound frozen at the start of this pass (stable across pages). */
  sinceIso: string;
  /** True for the first-ever sync pass (drives `unread:false` windowing). */
  initialSync: boolean;
  /** Wall-clock start of this pass; becomes `followed_poll_since` on completion. */
  runStartIso: string;
}

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
  clear(key: string): Promise<void>;
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
 * Process ONE page of followed notifications per call, so a large followed
 * backlog (e.g. the 365-day initial pass) never exceeds the connector runtime's
 * per-execution request budget. The cursor is checkpointed in
 * `followed_sync_state` between pages; the caller re-invokes (via `runTask`)
 * while `done` is false, so progress survives an execution that dies mid-pass.
 *
 * Initial vs incremental is derived from the `followed_initial_done` flag when a
 * pass begins, so the poll is robust to running before any channel token exists
 * (no token → returns done with nothing written, retried on the next poll).
 *
 * Returns `{ done }`: false means more pages remain and the caller should
 * re-invoke; true means this pass is complete (or there was nothing to do).
 */
export async function syncFollowedItems(
  source: FollowedSource,
): Promise<{ done: boolean; retryAt?: Date }> {
  const token = await source.getAccountToken();
  if (!token) {
    // No enabled channel to borrow the account token from yet. The recurring
    // poll will retry; the initial flag stays unset so the retry is initial.
    console.warn("GitHub followed sync: no account token available yet; skipping");
    return { done: true };
  }

  // Resume an in-progress pass, or start a fresh one (freezing `sinceIso` and
  // `runStartIso` so they stay stable across every page of the pass).
  let state = await source.get<FollowedSyncState>(SYNC_STATE_KEY);
  if (!state) {
    const initialDone = await source.get<boolean>("followed_initial_done");
    const initialSync = !initialDone;
    const sinceIso = initialSync
      ? new Date(Date.now() - INITIAL_LOOKBACK_MS).toISOString()
      : ((await source.get<string>("followed_poll_since")) ??
        new Date(Date.now() - INCREMENTAL_FALLBACK_MS).toISOString());
    state = {
      page: 1,
      sinceIso,
      initialSync,
      runStartIso: new Date().toISOString(),
    };
  }

  // Build the enabled-repo predicate from stored channel state (direct repos
  // and org-provisioned repos both set `sync_enabled_<owner/repo>`).
  const enabledKeys = await source.listStoreKeys("sync_enabled_");
  const enabledRepos = new Set(enabledKeys.map((k) => k.replace("sync_enabled_", "")));
  const isRepoEnabled = (repositoryId: string) => enabledRepos.has(repositoryId);

  // Fetch a single page of notifications.
  const response = await source.githubFetch(
    token,
    `/notifications?all=true&since=${encodeURIComponent(state.sinceIso)}&per_page=${PAGE_SIZE}&page=${state.page}`,
  );
  if (!response.ok) {
    const rl = parseRateLimit(response);
    if (rl.limited) {
      // Back off until the limit resets, then resume from the unchanged cursor.
      // The caller reschedules at `retryAt` rather than waiting for the next
      // recurring tick. Not an error.
      const retryAt =
        rl.resetAt && rl.resetAt.getTime() > Date.now()
          ? rl.resetAt
          : new Date(Date.now() + 60 * 1000);
      return { done: true, retryAt };
    }
    // Transient server error (5xx): GitHub's backend briefly failed — e.g. the
    // "Unicorn!" overload page returned as a 503. Like a rate-limit, this
    // self-resolves, so back off and resume from the unchanged cursor instead
    // of throwing. Throwing here surfaces the whole HTML error page as an
    // exception message on every retry — noise, not a bug the caller can fix.
    if (response.status >= 500) {
      return { done: true, retryAt: new Date(Date.now() + 60 * 1000) };
    }
    throw new Error(
      `Failed to fetch notifications: ${response.status} ${await response.text()}`,
    );
  }
  const batch: GitHubNotification[] = await response.json();

  const refs = parseFollowedNotifications(batch, isRepoEnabled);
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
            state.initialSync,
          )
        : await convertPRToThread(
            source as any,
            token,
            ref.owner,
            ref.repo,
            item,
            ref.repositoryId,
            state.initialSync,
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

  // A full page implies more may remain — advance the cursor and ask to continue.
  if (batch.length === PAGE_SIZE) {
    await source.set(SYNC_STATE_KEY, { ...state, page: state.page + 1 });
    return { done: false };
  }

  // Last page: clear the cursor and checkpoint so the next pass is incremental.
  await source.clear(SYNC_STATE_KEY);
  await source.set("followed_poll_since", state.runStartIso);
  if (state.initialSync) await source.set("followed_initial_done", true);
  return { done: true };
}
