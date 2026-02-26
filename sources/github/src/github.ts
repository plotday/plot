import {
  type Thread,
  type Action,
  ActionType,
  type ThreadMeta,
  ThreadType,
  type NewLinkWithNotes,
  Source,
  type ToolBuilder,
} from "@plotday/twister";
import type {
  Repository,
  SourceControlSyncOptions,
  SourceControlSource,
} from "@plotday/twister/common/source-control";
import type { NewContact } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

type SyncState = {
  page: number;
  batchNumber: number;
  prsProcessed: number;
  initialSync: boolean;
};

type GitHubUser = {
  id: number;
  login: string;
  avatar_url?: string;
  name?: string;
  email?: string;
};

type GitHubPullRequest = {
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

type GitHubIssueComment = {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
  user: GitHubUser;
  html_url: string;
};

type GitHubReview = {
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
 * GitHub source control source
 *
 * Implements the SourceControlSource interface for syncing GitHub repositories
 * and pull requests with Plot threads.
 */
export class GitHub extends Source<GitHub> implements SourceControlSource {
  static readonly PROVIDER = AuthProvider.GitHub;
  static readonly SCOPES = ["repo"];

  /** Days of recently closed/merged PRs to include in sync */
  private static readonly RECENT_DAYS = 30;
  /** PRs per page for batch sync */
  private static readonly PAGE_SIZE = 50;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: GitHub.PROVIDER,
            scopes: GitHub.SCOPES,
            getChannels: this.getChannels,
            onChannelEnabled: this.onChannelEnabled,
            onChannelDisabled: this.onChannelDisabled,
            linkTypes: [
              { type: "pull_request", label: "Pull Request" },
              { type: "review", label: "Review" },
            ],
          },
        ],
      }),
      network: build(Network, { urls: ["https://api.github.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Make an authenticated GitHub API request
   */
  private async githubFetch(
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
  private async getToken(channelId: string): Promise<string> {
    const authToken = await this.tools.integrations.get(
      GitHub.PROVIDER,
      channelId,
    );
    if (!authToken) {
      throw new Error("No GitHub authentication token available");
    }
    return authToken.token;
  }

  /**
   * Returns available GitHub repositories as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken,
  ): Promise<Channel[]> {
    const repos: GitHubRepo[] = [];
    let page = 1;

    // Paginate through all repos
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

    // Setup webhook and start initial sync
    await this.setupWebhook(channel.id);
    await this.startBatchSync(channel.id);
  }

  /**
   * Called when a channel repository is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  /**
   * Get list of repositories
   */
  async getRepositories(repositoryId: string): Promise<Repository[]> {
    const token = await this.getToken(repositoryId);

    const repos: GitHubRepo[] = [];
    let page = 1;

    while (true) {
      const response = await this.githubFetch(
        token,
        `/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=${page}`,
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
      name: repo.name,
      description: repo.description,
      url: repo.html_url,
      owner: repo.owner.login,
      defaultBranch: repo.default_branch,
      private: repo.private,
    }));
  }

  /**
   * Start syncing pull requests from a repository
   */
  async startSync(
    options: {
      repositoryId: string;
    } & SourceControlSyncOptions,
  ): Promise<void> {
    const { repositoryId } = options;

    // Setup webhook for real-time updates
    await this.setupWebhook(repositoryId);

    // Start initial batch sync
    await this.startBatchSync(repositoryId);
  }

  /**
   * Stop syncing a repository
   */
  async stopSync(repositoryId: string): Promise<void> {
    // Remove webhook
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

    // Cleanup webhook secret
    await this.clear(`webhook_secret_${repositoryId}`);

    // Cleanup sync state
    await this.clear(`sync_state_${repositoryId}`);
  }

  // ---------- Webhook setup ----------

  /**
   * Setup GitHub webhook for real-time PR updates
   */
  private async setupWebhook(repositoryId: string): Promise<void> {
    try {
      // Generate a webhook secret for signature verification
      const secret = crypto.randomUUID();

      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        repositoryId,
      );

      // Skip webhook setup for localhost (development mode)
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

    // Constant-time comparison
    if (expected.length !== signature.length) return false;
    let result = 0;
    for (let i = 0; i < expected.length; i++) {
      result |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    }
    return result === 0;
  }

  /**
   * Handle incoming webhook events from GitHub
   */
  private async onWebhook(
    request: WebhookRequest,
    repositoryId: string,
  ): Promise<void> {
    // Verify webhook signature
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

    if (event === "pull_request") {
      await this.handlePRWebhook(payload, repositoryId);
    } else if (event === "pull_request_review") {
      await this.handleReviewWebhook(payload, repositoryId);
    } else if (event === "issue_comment") {
      // Only handle comments on PRs (issue_comment fires for both issues and PRs)
      if (payload.issue?.pull_request) {
        await this.handleCommentWebhook(payload, repositoryId);
      }
    }
  }

  /**
   * Handle pull_request webhook event
   */
  private async handlePRWebhook(
    payload: any,
    repositoryId: string,
  ): Promise<void> {
    const pr: GitHubPullRequest = payload.pull_request;
    if (!pr) return;

    const [owner, repo] = repositoryId.split("/");

    const authorContact = this.userToContact(pr.user);
    const assigneeContact = pr.assignee
      ? this.userToContact(pr.assignee)
      : null;

    const thread: NewLinkWithNotes = {
      source: `github:pr:${owner}/${repo}/${pr.number}`,
      type: "pull_request",
      title: pr.title,
      created: new Date(pr.created_at),
      author: authorContact,
      assignee: assigneeContact,
      status: pr.merged_at ? "done" : null,
      ...(pr.state === "closed" && !pr.merged_at ? { archived: true } : {}),
      meta: {
        provider: "github",
        owner,
        repo,
        prNumber: pr.number,
        prNodeId: pr.id,
        syncProvider: "github",
        syncableId: repositoryId,
      },
      preview: pr.body || null,
      notes: [],
    };

    await this.tools.integrations.saveLink(thread);
  }

  /**
   * Handle pull_request_review webhook event
   */
  private async handleReviewWebhook(
    payload: any,
    repositoryId: string,
  ): Promise<void> {
    const review: GitHubReview = payload.review;
    const pr: GitHubPullRequest = payload.pull_request;
    if (!review || !pr) return;

    // Skip empty COMMENTED reviews (just inline comments with no summary)
    if (review.state === "COMMENTED" && !review.body) return;

    const [owner, repo] = repositoryId.split("/");
    const reviewAuthor = this.userToContact(review.user);

    const prefix = this.reviewStatePrefix(review.state);
    const content = prefix
      ? `${prefix}${review.body ? `\n\n${review.body}` : ""}`
      : review.body || null;

    const thread: NewLinkWithNotes = {
      source: `github:pr:${owner}/${repo}/${pr.number}`,
      type: "pull_request",
      title: pr.title,
      notes: [
        {
          key: `review-${review.id}`,
          content,
          created: new Date(review.submitted_at),
          author: reviewAuthor,
        } as any,
      ],
      meta: {
        provider: "github",
        owner,
        repo,
        prNumber: pr.number,
        prNodeId: pr.id,
        syncProvider: "github",
        syncableId: repositoryId,
      },
    };

    await this.tools.integrations.saveLink(thread);
  }

  /**
   * Handle issue_comment webhook event (for PR comments)
   */
  private async handleCommentWebhook(
    payload: any,
    repositoryId: string,
  ): Promise<void> {
    const comment: GitHubIssueComment = payload.comment;
    const issue = payload.issue;
    if (!comment || !issue) return;

    const [owner, repo] = repositoryId.split("/");
    const prNumber = issue.number;
    const commentAuthor = this.userToContact(comment.user);

    const thread: NewLinkWithNotes = {
      source: `github:pr:${owner}/${repo}/${prNumber}`,
      type: "pull_request",
      title: issue.title,
      notes: [
        {
          key: `comment-${comment.id}`,
          content: comment.body,
          created: new Date(comment.created_at),
          author: commentAuthor,
        } as any,
      ],
      meta: {
        provider: "github",
        owner,
        repo,
        prNumber,
        syncProvider: "github",
        syncableId: repositoryId,
      },
    };

    await this.tools.integrations.saveLink(thread);
  }

  // ---------- Batch sync ----------

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(repositoryId: string): Promise<void> {
    await this.set(`sync_state_${repositoryId}`, {
      page: 1,
      batchNumber: 1,
      prsProcessed: 0,
      initialSync: true,
    });

    const batchCallback = await this.callback(this.syncBatch, repositoryId);
    await this.runTask(batchCallback);
  }

  /**
   * Process a batch of pull requests
   */
  private async syncBatch(repositoryId: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${repositoryId}`);
    if (!state) {
      throw new Error(`Sync state not found for repository ${repositoryId}`);
    }

    const token = await this.getToken(repositoryId);
    const [owner, repo] = repositoryId.split("/");

    // Fetch batch of PRs (all states, sorted by updated)
    const response = await this.githubFetch(
      token,
      `/repos/${owner}/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=${GitHub.PAGE_SIZE}&page=${state.page}`,
    );

    if (!response.ok) {
      throw new Error(
        `Failed to fetch PRs: ${response.status} ${await response.text()}`,
      );
    }

    const prs: GitHubPullRequest[] = await response.json();

    // Filter: open PRs + recently closed/merged (within RECENT_DAYS)
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - GitHub.RECENT_DAYS);

    const relevantPRs = prs.filter((pr) => {
      if (pr.state === "open") return true;
      // Closed/merged: include if recently updated
      const closedDate = pr.merged_at || pr.closed_at;
      if (closedDate && new Date(closedDate) >= cutoff) return true;
      return false;
    });

    // If all PRs in this page are beyond the cutoff, stop syncing
    const allBeyondCutoff =
      prs.length > 0 &&
      prs.every((pr) => {
        if (pr.state === "open") return false;
        const closedDate = pr.merged_at || pr.closed_at;
        return closedDate && new Date(closedDate) < cutoff;
      });

    // Process each relevant PR
    for (const pr of relevantPRs) {
      const thread = await this.convertPRToThread(
        token,
        owner,
        repo,
        pr,
        repositoryId,
        state.initialSync,
      );

      if (thread) {
        thread.meta = {
          ...thread.meta,
          syncProvider: "github",
          syncableId: repositoryId,
        };
        await this.tools.integrations.saveLink(thread);
      }
    }

    // Continue to next page if there are more PRs and not all beyond cutoff
    if (prs.length === GitHub.PAGE_SIZE && !allBeyondCutoff) {
      await this.set(`sync_state_${repositoryId}`, {
        page: state.page + 1,
        batchNumber: state.batchNumber + 1,
        prsProcessed: state.prsProcessed + relevantPRs.length,
        initialSync: state.initialSync,
      });

      const nextBatch = await this.callback(this.syncBatch, repositoryId);
      await this.runTask(nextBatch);
    } else {
      // Sync complete
      await this.clear(`sync_state_${repositoryId}`);
    }
  }

  /**
   * Convert a GitHub PR to a NewLinkWithNotes
   */
  private async convertPRToThread(
    token: string,
    owner: string,
    repo: string,
    pr: GitHubPullRequest,
    repositoryId: string,
    initialSync: boolean,
  ): Promise<NewLinkWithNotes | null> {
    const authorContact = this.userToContact(pr.user);
    const assigneeContact = pr.assignee
      ? this.userToContact(pr.assignee)
      : null;

    // Build thread-level actions
    const threadActions: Action[] = [
      {
        type: ActionType.external,
        title: `Open in GitHub`,
        url: pr.html_url,
      },
    ];

    const notes: any[] = [];

    const hasDescription = pr.body && pr.body.trim().length > 0;
    notes.push({
      key: "description",
      content: hasDescription ? pr.body : null,
      created: new Date(pr.created_at),
      author: authorContact,
    });

    // Fetch general comments (issue comments API)
    try {
      const commentsResponse = await this.githubFetch(
        token,
        `/repos/${owner}/${repo}/issues/${pr.number}/comments?per_page=100`,
      );
      if (commentsResponse.ok) {
        const comments: GitHubIssueComment[] = await commentsResponse.json();
        for (const comment of comments) {
          const commentAuthor = this.userToContact(comment.user);
          notes.push({
            key: `comment-${comment.id}`,
            content: comment.body,
            created: new Date(comment.created_at),
            author: commentAuthor,
          });
        }
      }
    } catch (error) {
      console.error("Error fetching PR comments:", error);
    }

    // Fetch review summaries
    try {
      const reviewsResponse = await this.githubFetch(
        token,
        `/repos/${owner}/${repo}/pulls/${pr.number}/reviews?per_page=100`,
      );
      if (reviewsResponse.ok) {
        const reviews: GitHubReview[] = await reviewsResponse.json();
        for (const review of reviews) {
          // Skip empty COMMENTED reviews (just inline comments with no summary)
          if (review.state === "COMMENTED" && !review.body) continue;

          const reviewAuthor = this.userToContact(review.user);
          const prefix = this.reviewStatePrefix(review.state);
          const content = prefix
            ? `${prefix}${review.body ? `\n\n${review.body}` : ""}`
            : review.body || null;

          if (content) {
            notes.push({
              key: `review-${review.id}`,
              content,
              created: new Date(review.submitted_at),
              author: reviewAuthor,
            });
          }
        }
      }
    } catch (error) {
      console.error("Error fetching PR reviews:", error);
    }

    const thread: NewLinkWithNotes = {
      source: `github:pr:${owner}/${repo}/${pr.number}`,
      type: "pull_request",
      title: pr.title,
      created: new Date(pr.created_at),
      author: authorContact,
      assignee: assigneeContact,
      status: pr.merged_at ? "done" : null,
      meta: {
        provider: "github",
        owner,
        repo,
        prNumber: pr.number,
        prNodeId: pr.id,
      },
      actions: threadActions,
      sourceUrl: pr.html_url,
      notes,
      preview: hasDescription ? pr.body : null,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
      // Archive closed-without-merge PRs on incremental sync only
      ...(!initialSync && pr.state === "closed" && !pr.merged_at
        ? { archived: true }
        : {}),
    };

    return thread;
  }

  // ---------- Bidirectional methods ----------

  /**
   * Add a general comment to a pull request
   */
  async addPRComment(
    meta: ThreadMeta,
    body: string,
    noteId?: string,
  ): Promise<string | void> {
    const owner = meta.owner as string;
    const repo = meta.repo as string;
    const prNumber = meta.prNumber as number;
    const syncableId = `${owner}/${repo}`;

    if (!owner || !repo || !prNumber) {
      throw new Error("Owner, repo, and prNumber required in thread meta");
    }

    const token = await this.getToken(syncableId);

    const response = await this.githubFetch(
      token,
      `/repos/${owner}/${repo}/issues/${prNumber}/comments`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body }),
      },
    );

    if (!response.ok) {
      throw new Error(
        `Failed to add PR comment: ${response.status} ${await response.text()}`,
      );
    }

    const comment = await response.json();
    if (comment?.id) {
      return `comment-${comment.id}`;
    }
  }

  /**
   * Update a PR's review status (approve or request changes)
   */
  async updatePRStatus(thread: Thread): Promise<void> {
    const meta = thread.meta;
    if (!meta) return;

    const owner = meta.owner as string;
    const repo = meta.repo as string;
    const prNumber = meta.prNumber as number;
    const syncableId = `${owner}/${repo}`;

    if (!owner || !repo || !prNumber) {
      throw new Error("Owner, repo, and prNumber required in thread meta");
    }

    const token = await this.getToken(syncableId);

    // Map thread done state to review event
    // done = approved, not done = no action (can't undo approval via API easily)
    if (thread.type === ThreadType.Action && thread.done !== null) {
      const response = await this.githubFetch(
        token,
        `/repos/${owner}/${repo}/pulls/${prNumber}/reviews`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            event: "APPROVE",
          }),
        },
      );

      if (!response.ok) {
        throw new Error(
          `Failed to update PR status: ${response.status} ${await response.text()}`,
        );
      }
    }
  }

  /**
   * Close a pull request without merging
   */
  async closePR(meta: ThreadMeta): Promise<void> {
    const owner = meta.owner as string;
    const repo = meta.repo as string;
    const prNumber = meta.prNumber as number;
    const syncableId = `${owner}/${repo}`;

    if (!owner || !repo || !prNumber) {
      throw new Error("Owner, repo, and prNumber required in thread meta");
    }

    const token = await this.getToken(syncableId);

    const response = await this.githubFetch(
      token,
      `/repos/${owner}/${repo}/pulls/${prNumber}`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state: "closed" }),
      },
    );

    if (!response.ok) {
      throw new Error(
        `Failed to close PR: ${response.status} ${await response.text()}`,
      );
    }
  }

  // ---------- Helpers ----------

  /**
   * Convert a GitHub user to a NewContact using noreply email
   */
  private userToContact(user: GitHubUser): NewContact {
    return {
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      avatar: user.avatar_url ?? undefined,
    };
  }

  /**
   * Get a prefix for review state
   */
  private reviewStatePrefix(
    state: GitHubReview["state"],
  ): string | null {
    switch (state) {
      case "APPROVED":
        return "**Approved**";
      case "CHANGES_REQUESTED":
        return "**Changes Requested**";
      case "DISMISSED":
        return "**Dismissed**";
      default:
        return null;
    }
  }
}

export default GitHub;
