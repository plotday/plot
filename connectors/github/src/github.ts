import {
  type Link,
  type NewLinkWithNotes,
  type Note,
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
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Plot } from "@plotday/twister/tools/plot";
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
        { status: "open", label: "Open" },
        { status: "closed", label: "Closed", tag: Tag.Done },
        { status: "merged", label: "Merged", tag: Tag.Done },
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
        { status: "open", label: "Open" },
        { status: "closed", label: "Closed", tag: Tag.Done },
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
      plot: build(Plot, {
        thread: { defaultMention: true },
        note: { defaultMention: true },
      }),
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
        ...options?.headers,
      },
    });
  }

  /**
   * Get an authenticated token for a channel repository
   */
  async getToken(channelId: string): Promise<string> {
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
   * Returns available GitHub repositories as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken,
  ): Promise<Channel[]> {
    const repos: GitHubRepo[] = [];
    let page = 1;

    while (true) {
      const response = await fetch(
        `https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=${page}`,
        {
          headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${token.token}`,
            "X-GitHub-Api-Version": "2022-11-28",
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

    return repos.map((repo) => ({
      id: repo.full_name,
      title: repo.full_name,
    }));
  }

  /**
   * Called when a channel repository is enabled for syncing.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Setup webhook subscribing to all event types
    await this.setupWebhook(channel.id);

    // Start initial sync for enabled types
    const options = this.tools.options as { syncPullRequests: boolean; syncIssues: boolean };
    if (options.syncPullRequests) {
      await startPRBatchSync(this, channel.id, true);
    }
    if (options.syncIssues) {
      await startIssueBatchSync(this, channel.id, true);
    }
  }

  /**
   * Called when a channel repository is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
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
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<void> {
    const meta = thread.meta ?? {};
    if (meta.prNumber) {
      await addPRComment(this, meta, note.content ?? "");
    } else if (meta.issueNumber) {
      await addIssueComment(this, meta, note.content ?? "");
    }
  }

  // ---------- Webhook ----------

  /**
   * Setup GitHub webhook for real-time updates.
   * Subscribes to all event types regardless of options,
   * so toggling on later works without re-creating the webhook.
   */
  private async setupWebhook(repositoryId: string): Promise<void> {
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
