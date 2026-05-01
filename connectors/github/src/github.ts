import {
  type Link,
  type NewLinkWithNotes,
  type Note,
  type NoteWriteBackResult,
  Connector,
  type Thread,
  type ToolBuilder,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { Options } from "@plotday/twister/options";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
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
  addPRComment,
  updatePRStatus,
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

export type GitHubReview = {
  id: number;
  body: string;
  state: "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "DISMISSED" | "PENDING";
  submitted_at: string;
  user: GitHubUser;
  html_url: string;
};

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
};

/**
 * GitHub source — syncs pull requests and issues from GitHub repositories.
 *
 * Options:
 * - syncPullRequests: boolean (default: true) — sync PRs, reviews, and PR comments
 * - syncIssues: boolean (default: true) — sync issues and issue comments
 */
export class GitHub extends Connector<GitHub> {
  static readonly PROVIDER = AuthProvider.GitHub;
  static readonly SCOPES = ["repo"];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.GitHub;
  readonly scopes = GitHub.SCOPES;
  readonly linkTypes = [
    {
      type: "pull_request",
      label: "Pull Request",
      logo: "https://api.iconify.design/logos/github-icon.svg",
      logoDark: "https://api.iconify.design/simple-icons/github.svg?color=%23ffffff",
      logoMono: "https://api.iconify.design/simple-icons/github.svg",
      statuses: [
        { status: "open", label: "Open", todo: true },
        { status: "closed", label: "Closed", tag: Tag.Done, done: true },
        { status: "merged", label: "Merged", tag: Tag.Done, done: true },
      ],
      supportsAssignee: true,
    },
    {
      type: "issue",
      label: "Issue",
      logo: "https://api.iconify.design/logos/github-icon.svg",
      logoDark: "https://api.iconify.design/simple-icons/github.svg?color=%23ffffff",
      logoMono: "https://api.iconify.design/simple-icons/github.svg",
      statuses: [
        { status: "open", label: "Open", todo: true },
        { status: "closed", label: "Closed", tag: Tag.Done, done: true },
      ],
      supportsAssignee: true,
    },
  ];

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
  async getToken(channelId: string): Promise<string> {
    if (isRepoChannelId(channelId)) {
      const orgId = await this.get<string>(`org_for_repo_${channelId}`);
      if (orgId) {
        const orgToken = await this.tools.integrations.get(orgId);
        if (orgToken) return orgToken.token;
      }
    }
    const authToken = await this.tools.integrations.get(channelId);
    if (!authToken) {
      throw new Error("No GitHub authentication token available");
    }
    return authToken.token;
  }

  /**
   * Convert a GitHub user to a NewContact using noreply email
   */
  userToContact(user: GitHubUser): NewContact {
    return {
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      avatar: user.avatar_url ?? undefined,
      source: { provider: AuthProvider.GitHub, accountId: String(user.id) },
    };
  }

  /**
   * Save a link via integrations
   */
  async saveLink(link: NewLinkWithNotes): Promise<void> {
    await this.tools.integrations.saveLink(link);
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

  // ---------- Channel lifecycle ----------

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

    const options = this.tools.options as { syncPullRequests: boolean; syncIssues: boolean };
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
    await this.clear(`sync_enabled_${repositoryId}`);
    await this.clear(`org_for_repo_${repositoryId}`);
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
   * Returns a {@link NoteWriteBackResult} so the runtime sets the note's
   * key to `comment-<githubCommentId>` (matching what sync-in uses) and
   * records the external sync baseline. GitHub stores comment bodies as
   * markdown and returns the stored body verbatim, so the hashed baseline
   * matches what the next incremental sync will surface.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const body = note.content ?? "";
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
   * Pushes the new content to the corresponding GitHub comment (PR and
   * issue conversation comments live under the same endpoint) and refreshes
   * the sync baseline from GitHub's stored markdown body.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    if (!note.key) return;
    if (!meta.prNumber && !meta.issueNumber) return;

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

  // ---------- Webhook ----------

  /**
   * Setup GitHub webhook for real-time updates.
   * Subscribes to all event types regardless of options,
   * so toggling on later works without re-creating the webhook.
   */
  async setupWebhook(repositoryId: string): Promise<void> {
    try {
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

      await this.set(`webhook_secret_${repositoryId}`, secret);

      const token = await this.getToken(repositoryId);
      const [owner, repo] = repositoryId.split("/");

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

    const options = this.tools.options as { syncPullRequests: boolean; syncIssues: boolean };

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
