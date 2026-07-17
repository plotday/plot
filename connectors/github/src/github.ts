import {
  type Actor,
  type Link,
  type NewLinkWithNotes,
  type Note,
  type NoteWriteBackResult,
  Connector,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Options } from "@plotday/twister/options";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import {
  startPRBatchSync,
  syncPRBatch,
  handlePRWebhook,
  handleReviewWebhook,
  handlePRCommentWebhook,
  handlePRReviewCommentWebhook,
  addPRComment,
  addReviewCommentReply,
  updatePRStatus,
  updateReviewComment,
} from "./pr-sync";
import {
  startIssueBatchSync,
  syncIssueBatch,
  handleIssueWebhook,
  handleIssueCommentWebhook,
  updateIssue,
  addIssueComment,
  updateIssueComment,
} from "./issue-sync";
import {
  commentEndpointForKey,
  reactToComment,
  unreactToComment,
  pollOpenPRReactions,
} from "./reactions";
import { ALLOWED_REACTION_EMOJI } from "./github-emoji";
import { syncFollowedItems } from "./followed-sync";

// ---------- Exported types (used by pr-sync.ts and issue-sync.ts) ----------

export type GitHubUser = {
  id: number;
  login: string;
  avatar_url?: string;
  name?: string;
  email?: string;
};

export type GitHubPullRequest = {
  id: number;
  number: number;
  title: string;
  body: string | null;
  state: "open" | "closed";
  html_url: string;
  created_at: string;
  updated_at: string;
  closed_at: string | null;
  merged_at: string | null;
  user: GitHubUser;
  assignee: GitHubUser | null;
  draft: boolean;
  base: { repo: { full_name: string; owner: { login: string }; name: string } };
};

export type GitHubIssueComment = {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
  user: GitHubUser;
  html_url: string;
};

export interface GitHubNotificationSubject {
  title: string;
  url: string | null;
  latest_comment_url: string | null;
  type: string; // "Issue" | "PullRequest" | "Commit" | "Release" | ...
}

export interface GitHubNotification {
  id: string;
  reason: string;
  updated_at: string;
  subject: GitHubNotificationSubject;
  repository: { full_name: string; owner: { login: string }; name: string };
}

export type GitHubReview = {
  id: number;
  body: string;
  state: "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "DISMISSED" | "PENDING";
  submitted_at: string;
  user: GitHubUser;
  html_url: string;
};

export type GitHubReviewComment = {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
  user: GitHubUser;
  html_url: string;
  /** File path the comment is anchored to. */
  path: string;
  /** Line number in the file (the comment's current position after any diff updates). */
  line: number | null;
  /** Present when this comment is a reply within an existing review-comment thread. */
  in_reply_to_id?: number;
  pull_request_review_id: number;
};

/** GitHub rate-limit signal parsed from a response's status + headers. */
export interface RateLimitInfo {
  limited: boolean;
  /** Best-effort reset time; null if the response didn't say. */
  resetAt: Date | null;
}

/**
 * Detect GitHub primary/secondary rate limiting. Primary limits return 403/429
 * with `x-ratelimit-remaining: 0` and an `x-ratelimit-reset` (unix seconds).
 * Secondary limits return `retry-after` (seconds). Anything else is not a
 * rate-limit signal (e.g. a 403 for lacking permission).
 */
export function parseRateLimit(response: Response): RateLimitInfo {
  if (response.status !== 403 && response.status !== 429) {
    return { limited: false, resetAt: null };
  }
  const retryAfter = response.headers.get("retry-after");
  if (retryAfter) {
    const secs = Number(retryAfter);
    if (Number.isFinite(secs)) {
      return { limited: true, resetAt: new Date(Date.now() + secs * 1000) };
    }
  }
  if (response.headers.get("x-ratelimit-remaining") === "0") {
    // Guard the header presence explicitly: Number(null) === 0 would otherwise
    // report a bogus epoch-0 resetAt when the reset header is absent.
    const resetHeader = response.headers.get("x-ratelimit-reset");
    const reset = resetHeader != null ? Number(resetHeader) : NaN;
    return {
      limited: true,
      resetAt: Number.isFinite(reset) ? new Date(reset * 1000) : null,
    };
  }
  return { limited: false, resetAt: null };
}

/**
 * Channel ids in this connector are either an owner login (e.g. `microsoft`)
 * for an org/user-level toggle, or `owner/repo` for a single repository.
 * The `/` is the disambiguator — repo full names always contain one,
 * owner logins never do.
 */
function isRepoChannelId(channelId: string): boolean {
  return channelId.includes("/");
}

type GitHubRepo = {
  id: number;
  full_name: string;
  name: string;
  description: string | null;
  html_url: string;
  owner: { login: string };
  default_branch: string;
  private: boolean;
  permissions?: { admin?: boolean; push?: boolean; pull?: boolean };
};

/**
 * GitHub source — syncs pull requests and issues from GitHub repositories.
 *
 * Options:
 * - syncPullRequests: boolean (default: true) — sync PRs, reviews, and PR comments
 * - syncIssues: boolean (default: true) — sync issues and issue comments
 * - syncFollowed: boolean (default: true) — sync issues and PRs you follow in GitHub
 */
export class GitHub extends Connector<GitHub> {
  static readonly PROVIDER = AuthProvider.GitHub;
  static readonly SCOPES = ["repo"];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.GitHub;
  readonly channelNoun = { singular: "repository", plural: "repositories" };
  readonly scopes = GitHub.SCOPES;
  // New connections sync every repository by default; volume is bounded by the
  // plan's sync window (older issues/PRs are dropped server-side on save).
  // Newly discovered repositories should therefore auto-sync too.
  readonly autoEnableNewChannelsByDefault = true;
  readonly access = [
    "Reads your repositories' issues and pull requests",
    "Posts comments and updates you make in Plot",
    "Keeps Plot up to date as issues and pull requests change in GitHub",
  ];
  readonly linkTypes = [
    {
      type: "pull_request",
      label: "Pull Request",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      logo: "https://api.iconify.design/logos/github-icon.svg",
      logoDark: "https://api.iconify.design/simple-icons/github.svg?color=%23ffffff",
      logoMono: "https://api.iconify.design/simple-icons/github.svg",
      statuses: [
        { status: "open", label: "Open", icon: "todo" as StatusIcon },
        { status: "closed", label: "Closed", done: true, icon: "cancelled" as StatusIcon },
        { status: "merged", label: "Merged", done: true, icon: "done" as StatusIcon },
      ],
      supportsAssignee: true,
    },
    {
      type: "issue",
      label: "Issue",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      logo: "https://api.iconify.design/logos/github-icon.svg",
      logoDark: "https://api.iconify.design/simple-icons/github.svg?color=%23ffffff",
      logoMono: "https://api.iconify.design/simple-icons/github.svg",
      statuses: [
        { status: "open", label: "Open", icon: "todo" as StatusIcon },
        { status: "closed", label: "Closed", done: true, icon: "done" as StatusIcon },
      ],
      supportsAssignee: true,
    },
  ];
  readonly reactionCapabilities = {
    mode: "fixed" as const,
    allowed: ALLOWED_REACTION_EMOJI,
  };

  build(build: ToolBuilder) {
    return {
      options: build(Options, {
        syncPullRequests: {
          type: "boolean" as const,
          label: "Sync Pull Requests",
          description: "Sync pull requests, reviews, and PR comments",
          default: true,
        },
        syncIssues: {
          type: "boolean" as const,
          label: "Sync Issues",
          description: "Sync issues and issue comments",
          default: true,
        },
        syncFollowed: {
          type: "boolean" as const,
          label: "Sync followed items",
          description:
            "Sync issues and pull requests you follow in GitHub, even in repositories you don't sync",
          default: true,
        },
      }),
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.github.com/*"] }),
      tasks: build(Tasks),
    };
  }

  // ---------- Public helpers (used by pr-sync.ts / issue-sync.ts) ----------

  /**
   * Make an authenticated GitHub API request
   */
  async githubFetch(
    token: string,
    path: string,
    options?: RequestInit,
  ): Promise<Response> {
    return fetch(`https://api.github.com${path}`, {
      ...options,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": "2022-11-28",
        // GitHub requires a User-Agent on every request.
        "User-Agent": "Plot",
        ...options?.headers,
      },
    });
  }

  /**
   * Get an authenticated token for a channel.
   *
   * For org-managed repos (enabled via an owner-level channel), the
   * `channel_config` lives on the org channel, not the repo. Look that up
   * first so the right actor's token is selected, falling back to a direct
   * lookup for repos that were enabled on their own.
   */
  async getToken(channelId: string, allowAccountFallback = true): Promise<string> {
    if (isRepoChannelId(channelId)) {
      const orgId = await this.get<string>(`org_for_repo_${channelId}`);
      if (orgId) {
        const orgToken = await this.tools.integrations.get(orgId);
        if (orgToken) return orgToken.token;
      }
    }
    const authToken = await this.tools.integrations.get(channelId);
    if (authToken) return authToken.token;
    // Followed items live in repos with no enabled channel of their own; borrow
    // the account token from any enabled channel so their write-backs (comments,
    // reactions) still authenticate. GitHub uses one account OAuth token per
    // connection, so any enabled channel's token is the right one.
    if (allowAccountFallback) {
      const accountToken = await this.getAccountToken();
      if (accountToken) return accountToken;
    }
    throw new Error("No GitHub authentication token available");
  }

  /**
   * Resolve the account-level GitHub OAuth token by borrowing it from any
   * enabled channel — per-channel auth is just the user's account token, so any
   * enabled channel's token works (mirrors Gmail's findAnyAuthApi). Returns null
   * when no channel is enabled yet.
   */
  async getAccountToken(): Promise<string | null> {
    const enabledKeys = await this.listStoreKeys("sync_enabled_");
    for (const key of enabledKeys) {
      const channelId = key.replace("sync_enabled_", "");
      try {
        const token = await this.getToken(channelId, false);
        if (token) return token;
      } catch {
        // Channel unknown / token missing — try the next one.
      }
    }
    return null;
  }

  /**
   * Convert a GitHub user to a NewContact using noreply email
   */
  userToContact(user: GitHubUser): NewContact {
    return {
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      avatar: user.avatar_url ?? undefined,
      source: { accountId: String(user.id) },
    };
  }

  /**
   * Save a link via integrations
   */
  async saveLink(link: NewLinkWithNotes): Promise<void> {
    await this.tools.integrations.saveLink(link);
  }

  /**
   * Set the full reaction state for a note (public wrapper for the
   * protected `this.tools.integrations`, used by reactions.ts's poll job).
   */
  async setNoteReactions(
    thread: { id: string } | { source: string },
    key: string,
    reactions: import("@plotday/twister").NewReactions
  ): Promise<void> {
    await this.tools.integrations.setNoteReactions(thread as any, key, reactions);
  }

  /**
   * List stored keys by prefix (public wrapper for the protected
   * `this.tools.store.list`, used by reactions.ts's poll job).
   */
  async listStoreKeys(prefix: string): Promise<string[]> {
    return this.tools.store.list(prefix);
  }

  /**
   * Create a persistent callback (public wrapper for this.callback)
   */
  // @ts-ignore - simplified signature for public access
  async createCallback(fn: any, ...extraArgs: any[]): Promise<any> {
    return this.callback(fn, ...extraArgs);
  }

  // Public wrappers for protected Twist methods (used by helper files)
  override async get<T extends import("@plotday/twister").Serializable>(key: string): Promise<T | null> {
    return super.get(key);
  }
  override async set<T extends import("@plotday/twister").Serializable>(key: string, value: T): Promise<void> {
    return super.set(key, value);
  }
  override async clear(key: string): Promise<void> {
    return super.clear(key);
  }
  override async runTask(callback: any, options?: { runAt?: Date }): Promise<string | void> {
    return super.runTask(callback, options);
  }

  // ---------- Public batch sync entry points (called by helper files via callback) ----------

  /**
   * Callback entry point for PR batch sync
   */
  async syncPRBatch(repositoryId: string): Promise<void> {
    await syncPRBatch(this, repositoryId);
  }

  /**
   * Callback entry point for issue batch sync
   */
  async syncIssueBatch(repositoryId: string): Promise<void> {
    await syncIssueBatch(this, repositoryId);
  }

  /**
   * Callback entry point for the reaction poll (scheduleRecurring target).
   * Scoped to the single repo this task was registered for — each enabled
   * repo has its own recurring task, so this must not sweep other repos.
   */
  async pollReactions(repositoryId: string): Promise<void> {
    await pollOpenPRReactions(this, repositoryId);
  }

  /**
   * Callback entry point for the followed-items poll (scheduleRecurring target
   * AND the runTask continuation target). Account-wide, not per-channel.
   *
   * `syncFollowedItems` processes one notifications page per execution and
   * returns `{ done }`. While a pass has more pages (`done === false`), re-queue
   * ourselves via `runTask` so the backlog drains across executions without
   * exceeding the per-execution request budget. `done === true` only means
   * "stop chaining for now" (it is also returned when there is no account token
   * yet) — the recurring schedule re-drives the next incremental pass.
   */
  async pollFollowed(isContinuation = false): Promise<void> {
    // A recurring tick must not start a redundant pass while one is already in
    // progress — a continuation chain (via runTask) is scheduled to carry it
    // forward. Two independent signals mark "in progress":
    if (!isContinuation) {
      // 1. A rate-limit backoff: a continuation is scheduled for `retryAt`, so
      //    skip until then. This covers a page-1 rate limit, which leaves no
      //    cursor behind, and outlives the heartbeat window on long (hourly)
      //    primary limits.
      const retryAtStr = await this.get<string>("followed_retry_at");
      if (retryAtStr && Date.now() < new Date(retryAtStr).getTime()) return;

      // 2. A multi-page drain: the chain refreshes a heartbeat, so a fresh
      //    heartbeat with a live cursor means a drain is active. Staleness (a
      //    crashed chain) lets a later recurring tick resume the pass.
      const heartbeat = await this.get<string>("followed_poll_heartbeat");
      const cursor = await this.get<{ page: number }>("followed_sync_state");
      if (
        cursor &&
        heartbeat &&
        Date.now() - new Date(heartbeat).getTime() < 30 * 60 * 1000
      ) {
        return;
      }
    }
    await this.set("followed_poll_heartbeat", new Date().toISOString());

    // `get<T>`/`set<T>`'s generic constraints don't structurally match
    // FollowedSource's narrower signature; GitHub satisfies the contract
    // at runtime (see followed-sync.ts's FollowedSource doc comment).
    const { done, retryAt } = await syncFollowedItems(
      this as unknown as import("./followed-sync").FollowedSource,
    );
    if (retryAt) {
      // Rate-limited: record the backoff (the guard above honours it) and
      // resume the same cursor after the limit resets.
      await this.set("followed_retry_at", retryAt.toISOString());
      const followedCallback = await this.createCallback(this.pollFollowed, true);
      await this.runTask(followedCallback, { runAt: retryAt });
    } else {
      // Not rate-limited — clear any prior backoff marker.
      await this.clear("followed_retry_at");
      if (!done) {
        const followedCallback = await this.createCallback(this.pollFollowed, true);
        await this.runTask(followedCallback);
      }
    }
  }

  /**
   * Register the recurring followed poll. When `immediate` (the default, used by
   * `activate`/`onChannelEnabled`/`onOptionsChanged`), also kick a first run now.
   * `upgrade` passes `false` — a redeploy only needs to re-arm the schedule, not
   * fire an extra poll for every existing connection on every deploy.
   */
  private async startFollowedPoll(immediate = true): Promise<void> {
    const followedCallback = await this.createCallback(this.pollFollowed);
    await this.scheduleRecurring("followed-poll", followedCallback, {
      intervalMs: 15 * 60 * 1000,
    });
    if (immediate) await this.runTask(followedCallback);
  }

  // ---------- Channel lifecycle ----------

  /**
   * Fires on connection setup, independent of channels. Registers the recurring
   * followed-items poll (and kicks an immediate first run) when the option is on.
   */
  override async activate(): Promise<void> {
    const options = this.tools.options as {
      syncPullRequests: boolean;
      syncIssues: boolean;
      syncFollowed: boolean;
    };
    if (options.syncFollowed) {
      await this.startFollowedPoll();
    }
  }

  /**
   * Runs once per active instance when a new version deploys. Starts the
   * followed-items poll for connections that predate the feature (their option
   * defaults on but nothing scheduled the poll yet). Idempotent: scheduleRecurring
   * under the same key replaces any pending occurrence.
   */
  override async upgrade(): Promise<void> {
    const options = this.tools.options as {
      syncPullRequests: boolean;
      syncIssues: boolean;
      syncFollowed: boolean;
    };
    if (options.syncFollowed) {
      // Re-arm the recurring schedule only — no immediate kick on every deploy.
      await this.startFollowedPoll(false);
    }

    // One-time heal: earlier versions registered a fresh webhook on every
    // channel enable/recovery without removing the previous one, so repos
    // accumulated duplicate hooks with mismatched secrets (all but the newest
    // failed signature verification). Re-run the now-idempotent webhook setup
    // once per repo to converge each on a single verifiable hook. Gated behind
    // a flag so we don't re-sweep every repo on every subsequent deploy.
    if (!(await this.get<boolean>("hooks_reconciled_v1"))) {
      const enabledKeys = await this.listStoreKeys("sync_enabled_");
      for (const key of enabledKeys) {
        const channelId = key.replace("sync_enabled_", "");
        if (!isRepoChannelId(channelId)) continue;
        const webhookCallback = await this.callback(
          this.setupWebhook,
          channelId,
        );
        await this.runTask(webhookCallback);
      }
      await this.set("hooks_reconciled_v1", true);
    }
  }

  /**
   * Fetch every repository the authenticated user has access to.
   * Used by both `getChannels` and the org-level enable fan-out.
   */
  private async fetchAllRepos(token: string): Promise<GitHubRepo[]> {
    const repos: GitHubRepo[] = [];
    let page = 1;

    while (true) {
      const response = await fetch(
        `https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=${page}`,
        {
          headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${token}`,
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Plot",
          },
        },
      );

      if (!response.ok) break;

      const batch: GitHubRepo[] = await response.json();
      if (batch.length === 0) break;

      repos.push(...batch);
      if (batch.length < 100) break;
      page++;
    }

    return repos;
  }

  /**
   * Returns available GitHub repositories grouped by owner (user or
   * organization). Each owner is a parent channel whose children are the
   * repos the authenticated user has access to under that owner. Toggling
   * an owner enables sync for every repo it currently exposes; toggling
   * an individual repo enables only that repo.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken,
  ): Promise<Channel[]> {
    const repos = await this.fetchAllRepos(token.token);

    const byOwner = new Map<string, GitHubRepo[]>();
    for (const repo of repos) {
      const owner = repo.owner.login;
      const list = byOwner.get(owner) ?? [];
      list.push(repo);
      byOwner.set(owner, list);
    }

    const channels: Channel[] = [];
    for (const [owner, ownerRepos] of byOwner) {
      channels.push({
        id: owner,
        title: owner,
        // Enable every owner by default. Enabling an owner cascades to all its
        // repos, but per-item volume is bounded by the plan's sync window, so a
        // large org doesn't mean a large sync.
        enabledByDefault: true,
        children: ownerRepos.map((repo) => ({
          id: repo.full_name,
          title: repo.full_name,
        })),
      });
    }
    return channels;
  }

  /**
   * Called when a channel is enabled. Routes to repo- or org-level setup
   * based on whether the id is `owner/repo` or just `owner`.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    if (isRepoChannelId(channel.id)) {
      await this.onRepoEnabled(channel.id, context);
    } else {
      await this.onOrgEnabled(channel.id, context);
    }

    // A channel is now enabled, so an account token exists — ensure the followed
    // poll is running so the first followed sync doesn't wait for the next
    // recurring tick (on a fresh connection `activate` ran before any channel
    // was enabled, so its kick found no token). Idempotent; the poll's own
    // guard drops the kick if a drain is already in flight.
    const options = this.tools.options as {
      syncPullRequests: boolean;
      syncIssues: boolean;
      syncFollowed: boolean;
    };
    if (options.syncFollowed) {
      await this.startFollowedPoll();
    }
  }

  /**
   * Called when a channel is disabled. Org-level disables tear down every
   * repo we provisioned under that owner.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    if (isRepoChannelId(channel.id)) {
      await this.onRepoDisabled(channel.id);
    } else {
      await this.onOrgDisabled(channel.id);
    }
  }

  /**
   * Set up webhook + initial sync for a single repo. Used both for
   * directly-enabled repo channels and for repos provisioned under an
   * org-level enable.
   *
   * When `parentChannelId` is set, the initial-sync completion counter is
   * tracked on the parent (so the org channel's syncing indicator clears
   * once all of its repos finish), and `org_for_repo_<repo>` is recorded
   * so token lookups resolve via the parent.
   */
  private async provisionRepo(
    repositoryId: string,
    syncHistoryMin: Date | undefined,
    parentChannelId: string | null,
  ): Promise<{ pendingTypes: number }> {
    await this.set(`sync_enabled_${repositoryId}`, true);
    if (parentChannelId) {
      await this.set(`org_for_repo_${repositoryId}`, parentChannelId);
    }

    const webhookCallback = await this.callback(this.setupWebhook, repositoryId);
    await this.runTask(webhookCallback);

    const reactionPollCallback = await this.callback(this.pollReactions, repositoryId);
    await this.scheduleRecurring(`reaction-poll-${repositoryId}`, reactionPollCallback, {
      intervalMs: 15 * 60 * 1000,
    });

    const options = this.tools.options as {
      syncPullRequests: boolean;
      syncIssues: boolean;
      syncFollowed: boolean;
    };
    const pendingTypes =
      (options.syncPullRequests ? 1 : 0) + (options.syncIssues ? 1 : 0);

    if (options.syncPullRequests) {
      await startPRBatchSync(this, repositoryId, true, syncHistoryMin);
    }
    if (options.syncIssues) {
      await startIssueBatchSync(this, repositoryId, true, syncHistoryMin);
    }

    return { pendingTypes };
  }

  /**
   * Provision sync for a single repo enabled directly (not under an org).
   */
  private async onRepoEnabled(repositoryId: string, context?: SyncContext): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${repositoryId}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        await this.tools.integrations.channelSyncCompleted(repositoryId);
        return;
      }
      await this.set(`sync_history_min_${repositoryId}`, syncHistoryMin.toISOString());
    }

    const { pendingTypes } = await this.provisionRepo(repositoryId, syncHistoryMin, null);
    if (pendingTypes > 0) {
      await this.set(`pending_initial_sync_${repositoryId}`, pendingTypes);
    } else {
      await this.tools.integrations.channelSyncCompleted(repositoryId);
    }
  }

  /**
   * Provision sync for every repo currently visible under an owner.
   */
  private async onOrgEnabled(orgId: string, context?: SyncContext): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${orgId}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        await this.tools.integrations.channelSyncCompleted(orgId);
        return;
      }
      await this.set(`sync_history_min_${orgId}`, syncHistoryMin.toISOString());
    }

    await this.set(`org_enabled_${orgId}`, true);

    const token = await this.getToken(orgId);
    const allRepos = await this.fetchAllRepos(token);
    const orgRepos = allRepos.filter((r) => r.owner.login === orgId);
    const repoIds = orgRepos.map((r) => r.full_name);
    await this.set(`org_repos_${orgId}`, repoIds);

    for (const repo of orgRepos) {
      if (repo.permissions?.admin !== true) {
        await this.set(`repo_no_admin_${repo.full_name}`, true);
      }
    }

    if (repoIds.length === 0) {
      await this.tools.integrations.channelSyncCompleted(orgId);
      return;
    }

    let totalPending = 0;
    for (const repoId of repoIds) {
      const { pendingTypes } = await this.provisionRepo(repoId, syncHistoryMin, orgId);
      totalPending += pendingTypes;
    }

    if (totalPending > 0) {
      await this.set(`pending_initial_sync_${orgId}`, totalPending);
    } else {
      await this.tools.integrations.channelSyncCompleted(orgId);
    }
  }

  /**
   * Tear down a single repo's webhook + sync state. Shared by direct repo
   * disables and org-level disables (which iterate their managed repos).
   */
  private async teardownRepo(repositoryId: string): Promise<void> {
    await this.stopSync(repositoryId);
    await this.cancelScheduledTask(`reaction-poll-${repositoryId}`);
    await this.clear(`sync_enabled_${repositoryId}`);
    await this.clear(`org_for_repo_${repositoryId}`);
    await this.clear(`repo_no_admin_${repositoryId}`);
  }

  private async onRepoDisabled(repositoryId: string): Promise<void> {
    await this.teardownRepo(repositoryId);
    await this.clear(`pending_initial_sync_${repositoryId}`);
    await this.clear(`sync_history_min_${repositoryId}`);
  }

  private async onOrgDisabled(orgId: string): Promise<void> {
    const repoIds = (await this.get<string[]>(`org_repos_${orgId}`)) ?? [];
    for (const repoId of repoIds) {
      await this.teardownRepo(repoId);
    }
    await this.clear(`org_repos_${orgId}`);
    await this.clear(`org_enabled_${orgId}`);
    await this.clear(`pending_initial_sync_${orgId}`);
    await this.clear(`sync_history_min_${orgId}`);
  }

  /**
   * Decrements the pending-initial-sync counter for a channel. When it hits
   * zero (all initial sync chains complete), calls
   * `integrations.channelSyncCompleted` so the Flutter app clears the
   * syncing indicator. No-op when the counter is missing (i.e. this wasn't
   * an initial sync).
   *
   * For repos provisioned under an org-level enable, the counter lives on
   * the parent org channel — sync chains pass the repo id, so we redirect
   * here.
   */
  async markInitialSyncTypeDone(channelId: string): Promise<void> {
    const orgId = await this.get<string>(`org_for_repo_${channelId}`);
    const counterChannelId = orgId ?? channelId;

    const key = `pending_initial_sync_${counterChannelId}`;
    const remaining = await this.get<number>(key);
    if (remaining == null) return;
    const next = remaining - 1;
    if (next <= 0) {
      await this.clear(key);
      await this.tools.integrations.channelSyncCompleted(counterChannelId);
    } else {
      await this.set(key, next);
    }
  }

  /**
   * Called when options are changed (e.g. toggling PR or issue sync).
   * Starts sync for newly enabled types on all active channels.
   * Disabled types simply stop receiving webhook events — existing items remain.
   */
  async onOptionsChanged(
    oldOptions: Record<string, any>,
    newOptions: Record<string, any>,
  ): Promise<void> {
    // Followed items: independent account-wide sync, toggled on/off here.
    if (!oldOptions.syncFollowed && newOptions.syncFollowed) {
      await this.startFollowedPoll();
    } else if (oldOptions.syncFollowed && !newOptions.syncFollowed) {
      await this.cancelScheduledTask("followed-poll");
      // Already-synced followed threads are left in place, not deleted.
    }

    // Find all enabled channels
    const channelKeys = await this.tools.store.list("sync_enabled_");

    for (const key of channelKeys) {
      const channelId = key.replace("sync_enabled_", "");

      // PRs toggled on → start PR sync
      if (!oldOptions.syncPullRequests && newOptions.syncPullRequests) {
        await startPRBatchSync(this, channelId, true);
      }

      // Issues toggled on → start issue sync
      if (!oldOptions.syncIssues && newOptions.syncIssues) {
        await startIssueBatchSync(this, channelId, true);
      }
    }
  }

  // ---------- Write-back hooks ----------

  /**
   * Called when a link created by this source is updated by the user.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    if (link.type === "pull_request") {
      await updatePRStatus(this, link);
    } else if (link.type === "issue") {
      await updateIssue(this, link);
    }
  }

  /**
   * Called when a note is created on a thread owned by this source.
   *
   * Replies within an existing inline (code-line) review-comment thread —
   * identified via `thread.meta.reNoteKey`, the key of the note being
   * replied to — route to GitHub's review-comment reply endpoint instead of
   * the top-level conversation-comment endpoint, since GitHub only accepts
   * inline comments through `pulls/comments` with an `in_reply_to` id.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime sets the note's
   * key to `comment-<githubCommentId>` / `review-comment-<githubCommentId>`
   * (matching what sync-in uses) and records the external sync baseline.
   * GitHub stores comment bodies as markdown and returns the stored body
   * verbatim, so the hashed baseline matches what the next incremental sync
   * will surface.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const body = note.content ?? "";

    const reNoteKey = meta.reNoteKey as string | undefined;
    const reviewParent = commentEndpointForKey(reNoteKey ?? null);
    if (reviewParent?.kind === "review") {
      const result = await addReviewCommentReply(this, meta, Number(reviewParent.commentId), body);
      if (!result) return;
      return {
        key: `review-comment-${result.id}`,
        externalContent: result.body,
      };
    }

    if (meta.prNumber) {
      const result = await addPRComment(this, meta, body);
      if (!result) return;
      return {
        key: `comment-${result.id}`,
        externalContent: result.body,
      };
    } else if (meta.issueNumber) {
      const result = await addIssueComment(this, meta, body);
      if (!result) return;
      return {
        key: `comment-${result.id}`,
        externalContent: result.body,
      };
    }
  }

  /**
   * Called when a Plot user edits an existing note on a GitHub-owned thread.
   *
   * `review-comment-*` keys route to `updateReviewComment` (GitHub's inline
   * review-comment edit endpoint, `pulls/comments/{id}`) since it differs
   * from the top-level conversation-comment endpoint
   * (`issues/comments/{id}`) that `comment-*` keys use via
   * `updateIssueComment`. Refreshes the sync baseline from GitHub's stored
   * markdown body in either case.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    if (!note.key) return;
    if (!meta.prNumber && !meta.issueNumber) return;

    const reviewMatch = note.key.match(/^review-comment-(\d+)$/);
    if (reviewMatch) {
      const commentId = Number(reviewMatch[1]);
      if (!Number.isFinite(commentId)) return;
      const result = await updateReviewComment(this, meta, commentId, note.content ?? "");
      if (!result) return;
      return {
        externalContent: result.body,
      };
    }

    const match = note.key.match(/^comment-(\d+)$/);
    if (!match) return;
    const commentId = Number(match[1]);
    if (!Number.isFinite(commentId)) return;

    const body = note.content ?? "";
    const result = await updateIssueComment(this, meta, commentId, body);
    if (!result) return;
    return {
      externalContent: result.body,
    };
  }

  /**
   * Push a single emoji add/remove to GitHub. Dispatched on the reacting
   * user's own GitHub connector instance, so `getToken` resolves to their
   * token and the reaction is attributed to their GitHub account.
   */
  async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: Actor,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const owner = meta.owner as string | undefined;
    const repo = meta.repo as string | undefined;
    if (!owner || !repo || !note.key) return;

    const syncableId = `${owner}/${repo}`;
    let token: string;
    try {
      token = await this.getToken(syncableId);
    } catch {
      return; // no connection for this user — stays Plot-only, per SDK contract
    }

    if (added) {
      await reactToComment(this, token, owner, repo, note.key, emoji);
    } else {
      await unreactToComment(this, token, owner, repo, note.key, emoji);
    }
  }

  // ---------- Webhook ----------

  /**
   * Set up (or reconcile) the GitHub webhook for real-time updates.
   * Subscribes to all event types regardless of options, so toggling one on
   * later works without re-creating the webhook.
   *
   * This method is idempotent and self-healing. It runs on every channel
   * enable and on recovery re-dispatch, so it must NOT blindly register a new
   * webhook each time: doing so left a repo with multiple live hooks, each
   * signed with a different secret, while only the most recent secret was
   * stored — so GitHub fanned every event out to all of them and every
   * delivery except the newest failed HMAC verification. Instead:
   *
   *  - If we already registered a hook that is still live on GitHub, keep it
   *    (and its stored secret) and only prune any *other* Plot hooks left over
   *    from earlier registrations.
   *  - Otherwise register a fresh hook, after first removing any stale Plot
   *    hooks so the repo converges on exactly one hook whose secret we hold.
   */
  async setupWebhook(repositoryId: string): Promise<void> {
    if (await this.get<boolean>(`repo_no_admin_${repositoryId}`)) {
      // No admin rights on this repo — creating a webhook would 403. Skip the
      // wasted request; the repo still gets initial sync and reaction polling.
      return;
    }

    try {
      const token = await this.getToken(repositoryId);
      const [owner, repo] = repositoryId.split("/");

      // Fast, idempotent path: if a previously-registered hook is still live on
      // GitHub, keep it (and its secret). Only prune duplicate Plot hooks.
      const storedId = await this.get<string>(`webhook_id_${repositoryId}`);
      const storedSecret = await this.get<string>(
        `webhook_secret_${repositoryId}`,
      );
      if (storedId && storedSecret) {
        const existing = await this.githubFetch(
          token,
          `/repos/${owner}/${repo}/hooks/${storedId}`,
        );
        if (existing.ok) {
          const hook = (await existing.json()) as {
            config?: { url?: string };
          };
          const url = hook?.config?.url;
          if (typeof url === "string") {
            await this.removeStalePlotWebhooks(
              token,
              owner,
              repo,
              this.plotWebhookOrigin(url),
              storedId,
            );
          }
          return;
        }
        if (existing.status !== 404) {
          // Transient failure (rate limit, 5xx) — don't churn the registration;
          // the next enable/recovery pass will retry.
          console.warn(
            "GitHub webhook health check failed, will retry later:",
            existing.status,
          );
          return;
        }
        // 404: the stored registration is gone. Fall through to recreate.
      }

      // (Re)create path.
      const secret = crypto.randomUUID();

      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        repositoryId,
      );

      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      // Remove any previously-registered Plot hooks (whose secrets we no longer
      // store) before creating the replacement, so GitHub isn't left fanning
      // events out to a hook we can no longer verify.
      await this.removeStalePlotWebhooks(
        token,
        owner,
        repo,
        this.plotWebhookOrigin(webhookUrl),
        null,
      );

      await this.set(`webhook_secret_${repositoryId}`, secret);

      const response = await this.githubFetch(
        token,
        `/repos/${owner}/${repo}/hooks`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            name: "web",
            active: true,
            events: [
              "pull_request",
              "pull_request_review",
              "pull_request_review_comment",
              "issues",
              "issue_comment",
            ],
            config: {
              url: webhookUrl,
              content_type: "json",
              secret,
              insecure_ssl: "0",
            },
          }),
        },
      );

      if (response.ok) {
        const webhook = await response.json();
        if (webhook.id) {
          await this.set(`webhook_id_${repositoryId}`, String(webhook.id));
        }
      } else {
        console.error(
          "Failed to create GitHub webhook:",
          response.status,
          await response.text(),
        );
      }
    } catch (error) {
      console.error(
        "Failed to set up GitHub webhook - real-time updates will not work:",
        error,
      );
    }
  }

  /**
   * The origin of a Plot webhook URL, used to recognise which of a repo's
   * hooks were registered by Plot. Returns null if the URL can't be parsed.
   */
  private plotWebhookOrigin(webhookUrl: string): string | null {
    try {
      return new URL(webhookUrl).origin;
    } catch {
      return null;
    }
  }

  /**
   * Delete every hook on the repo that points at our webhook host (`origin`)
   * except `keepId`. Identifies Plot hooks by matching both the origin and the
   * `/hook` path prefix that all Plot webhook URLs share, so third-party hooks
   * are never touched. Best-effort: listing or deleting failures are logged
   * and swallowed so they never abort webhook setup.
   */
  private async removeStalePlotWebhooks(
    token: string,
    owner: string,
    repo: string,
    origin: string | null,
    keepId: string | null,
  ): Promise<void> {
    if (!origin) return;
    try {
      const resp = await this.githubFetch(
        token,
        `/repos/${owner}/${repo}/hooks?per_page=100`,
      );
      if (!resp.ok) return;
      const hooks = (await resp.json()) as Array<{
        id?: number | string;
        config?: { url?: string };
      }>;
      if (!Array.isArray(hooks)) return;

      for (const hook of hooks) {
        const id = hook?.id;
        const url = hook?.config?.url;
        if (id == null || typeof url !== "string") continue;
        if (keepId != null && String(id) === keepId) continue;

        let parsed: URL;
        try {
          parsed = new URL(url);
        } catch {
          continue;
        }
        // Only our own webhooks: same API host and the shared `/hook` path.
        if (parsed.origin !== origin || !parsed.pathname.startsWith("/hook")) {
          continue;
        }

        const del = await this.githubFetch(
          token,
          `/repos/${owner}/${repo}/hooks/${id}`,
          { method: "DELETE" },
        );
        if (!del.ok && del.status !== 404) {
          console.warn(
            "Failed to delete stale GitHub webhook:",
            id,
            del.status,
          );
        }
      }
    } catch (error) {
      console.warn("Failed to reconcile GitHub webhooks:", error);
    }
  }

  /**
   * Verify GitHub webhook signature using HMAC-SHA256
   */
  private async verifyWebhookSignature(
    secret: string,
    body: string,
    signature: string,
  ): Promise<boolean> {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );

    const signed = await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(body),
    );

    const expected =
      "sha256=" +
      Array.from(new Uint8Array(signed))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    if (expected.length !== signature.length) return false;
    let result = 0;
    for (let i = 0; i < expected.length; i++) {
      result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    }
    return result === 0;
  }

  /**
   * Handle incoming webhook events from GitHub.
   * Routes to PR or issue handlers based on event type and current options.
   */
  private async onWebhook(
    request: WebhookRequest,
    repositoryId: string,
  ): Promise<void> {
    const secret = await this.get<string>(`webhook_secret_${repositoryId}`);
    if (!secret) {
      console.warn("GitHub webhook secret not found, skipping verification");
      return;
    }

    if (!request.rawBody) {
      console.warn("GitHub webhook missing raw body");
      return;
    }

    const signature = request.headers["x-hub-signature-256"];
    if (!signature) {
      console.warn("GitHub webhook missing signature header");
      return;
    }

    const valid = await this.verifyWebhookSignature(
      secret,
      request.rawBody,
      signature,
    );
    if (!valid) {
      console.warn("GitHub webhook signature verification failed");
      return;
    }

    const event = request.headers["x-github-event"];
    const payload =
      typeof request.body === "string"
        ? JSON.parse(request.body)
        : request.body;

    const options = this.tools.options as {
      syncPullRequests: boolean;
      syncIssues: boolean;
      syncFollowed: boolean;
    };

    if (event === "pull_request") {
      if (options.syncPullRequests) {
        await handlePRWebhook(this, payload, repositoryId);
      }
    } else if (event === "pull_request_review") {
      if (options.syncPullRequests) {
        await handleReviewWebhook(this, payload, repositoryId);
      }
    } else if (event === "issues") {
      if (options.syncIssues) {
        await handleIssueWebhook(this, payload, repositoryId);
      }
    } else if (event === "issue_comment") {
      // issue_comment fires for both issues and PRs
      if (payload.issue?.pull_request) {
        if (options.syncPullRequests) {
          await handlePRCommentWebhook(this, payload, repositoryId);
        }
      } else {
        if (options.syncIssues) {
          await handleIssueCommentWebhook(this, payload, repositoryId);
        }
      }
    } else if (event === "pull_request_review_comment") {
      if (options.syncPullRequests) {
        await handlePRReviewCommentWebhook(this, payload, repositoryId);
      }
    }
  }

  // ---------- Sync management ----------

  /**
   * Stop syncing a repository (cleanup webhooks and state)
   */
  async stopSync(repositoryId: string): Promise<void> {
    const webhookId = await this.get<string>(`webhook_id_${repositoryId}`);
    if (webhookId) {
      try {
        const token = await this.getToken(repositoryId);
        const [owner, repo] = repositoryId.split("/");
        await this.githubFetch(
          token,
          `/repos/${owner}/${repo}/hooks/${webhookId}`,
          { method: "DELETE" },
        );
      } catch (error) {
        console.warn("Failed to delete GitHub webhook:", error);
      }
      await this.clear(`webhook_id_${repositoryId}`);
    }

    await this.clear(`webhook_secret_${repositoryId}`);
    await this.clear(`pr_sync_state_${repositoryId}`);
    await this.clear(`issue_sync_state_${repositoryId}`);
  }
}

export default GitHub;
