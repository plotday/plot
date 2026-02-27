import { Octokit } from "@octokit/rest";

import {
  type Action,
  ActionType,
  type ThreadMeta,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type {
  Project,
  ProjectSyncOptions,
  ProjectSource,
} from "@plotday/twister/common/projects";
import type { NewContact } from "@plotday/twister/plot";
import { Source } from "@plotday/twister/source";
import type { ToolBuilder } from "@plotday/twister/tool";
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
  issuesProcessed: number;
  initialSync: boolean;
  phase: "open" | "closed";
};

type RepoInfo = {
  owner: string;
  repo: string;
  fullName: string;
};

/**
 * GitHub Issues source
 *
 * Implements the ProjectSource interface for syncing GitHub Issues
 * with Plot threads. Explicitly filters out pull requests.
 */
export class GitHubIssues extends Source<GitHubIssues> implements ProjectSource {
  static readonly PROVIDER = AuthProvider.GitHub;
  static readonly SCOPES = ["repo"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: GitHubIssues.PROVIDER,
            scopes: GitHubIssues.SCOPES,
            linkTypes: [
              {
                type: "issue",
                label: "Issue",
                logo: "https://api.iconify.design/logos/github-icon.svg",
                statuses: [
                  { status: "open", label: "Open" },
                  { status: "closed", label: "Closed" },
                ],
              },
              {
                type: "pull_request",
                label: "Pull Request",
                logo: "https://api.iconify.design/logos/github-icon.svg",
                statuses: [
                  { status: "open", label: "Open" },
                  { status: "closed", label: "Closed" },
                  { status: "merged", label: "Merged" },
                ],
              },
            ],
            getChannels: this.getChannels,
            onChannelEnabled: this.onChannelEnabled,
            onChannelDisabled: this.onChannelDisabled,
          },
        ],
      }),
      network: build(Network, { urls: ["https://api.github.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Create GitHub API client using channel-based auth
   */
  private async getClient(channelId: string): Promise<Octokit> {
    const token = await this.tools.integrations.get(
      GitHubIssues.PROVIDER,
      channelId
    );
    if (!token) {
      throw new Error("No GitHub authentication token available");
    }
    return new Octokit({ auth: token.token });
  }

  /**
   * Parse owner and repo from stored repo info
   */
  private async getRepoInfo(repoId: string): Promise<RepoInfo> {
    const info = await this.get<RepoInfo>(`repo_info_${repoId}`);
    if (!info) {
      throw new Error(`Repo info not found for ${repoId}`);
    }
    return info;
  }

  /**
   * Returns available GitHub repos as channel resources.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const octokit = new Octokit({ auth: token.token });
    const repos = await octokit.rest.repos.listForAuthenticatedUser({
      sort: "updated",
      per_page: 100,
    });
    return repos.data.map((repo) => ({
      id: repo.id.toString(),
      title: repo.full_name,
    }));
  }

  /**
   * Called when a channel resource is enabled for syncing.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Store repo info (owner/repo) for API calls
    // channel.title is "owner/repo" (full_name)
    const [owner, repo] = (channel.title ?? "").split("/");
    if (owner && repo) {
      await this.set<RepoInfo>(`repo_info_${channel.id}`, {
        owner,
        repo,
        fullName: channel.title ?? "",
      });
    }

    // Auto-start sync: setup webhook and begin batch sync
    await this.setupGitHubWebhook(channel.id);
    await this.startBatchSync(channel.id);
  }

  /**
   * Called when a channel resource is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`repo_info_${channel.id}`);
  }

  /**
   * Get list of GitHub repos (projects)
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const octokit = await this.getClient(projectId);
    const repos = await octokit.rest.repos.listForAuthenticatedUser({
      sort: "updated",
      per_page: 100,
    });

    return repos.data.map((repo) => ({
      id: repo.id.toString(),
      name: repo.full_name,
      description: repo.description || null,
      key: null,
    }));
  }

  /**
   * Start syncing issues from a GitHub repo
   */
  async startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions
  ): Promise<void> {
    const { projectId } = options;

    // Setup webhook for real-time updates
    await this.setupGitHubWebhook(projectId);

    // Start initial batch sync
    await this.startBatchSync(projectId, options);
  }

  /**
   * Setup GitHub webhook for real-time updates
   */
  private async setupGitHubWebhook(repoId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        repoId
      );

      // Skip webhook setup for localhost (development mode)
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      const octokit = await this.getClient(repoId);
      const { owner, repo } = await this.getRepoInfo(repoId);

      // Generate webhook secret for signature verification
      const webhookSecret = crypto.randomUUID();
      await this.set(`webhook_secret_${repoId}`, webhookSecret);

      const response = await octokit.rest.repos.createWebhook({
        owner,
        repo,
        config: {
          url: webhookUrl,
          content_type: "json",
          secret: webhookSecret,
        },
        events: ["issues", "issue_comment"],
      });

      if (response.data.id) {
        await this.set(`webhook_id_${repoId}`, response.data.id);
      }
    } catch (error) {
      console.error(
        "Failed to set up GitHub webhook - real-time updates will not work:",
        error
      );
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    repoId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    await this.set<SyncState>(`sync_state_${repoId}`, {
      page: 1,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
      phase: "open",
    });

    const batchCallback = await this.callback(
      this.syncBatch,
      repoId,
      options ?? null
    );
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    repoId: string,
    options?: ProjectSyncOptions | null
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${repoId}`);
    if (!state) {
      throw new Error(`Sync state not found for repo ${repoId}`);
    }

    const octokit = await this.getClient(repoId);
    const { owner, repo, fullName } = await this.getRepoInfo(repoId);

    // Build request params based on phase
    const params: Parameters<typeof octokit.rest.issues.listForRepo>[0] = {
      owner,
      repo,
      state: state.phase,
      per_page: 50,
      page: state.page,
      sort: "updated",
      direction: "desc",
    };

    // For closed phase, only fetch recently closed (last 30 days)
    if (state.phase === "closed") {
      const thirtyDaysAgo = new Date();
      thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
      params.since = thirtyDaysAgo.toISOString();
    }

    if (options?.timeMin) {
      params.since = new Date(options.timeMin).toISOString();
    }

    const response = await octokit.rest.issues.listForRepo(params);
    const issues = response.data;

    // Process each issue (filter out PRs)
    let processedInBatch = 0;
    for (const issue of issues) {
      // Skip pull requests (GitHub returns PRs in issues endpoint)
      if (issue.pull_request) continue;

      const link = await this.convertIssueToLink(
        octokit,
        issue,
        repoId,
        fullName,
        state.initialSync
      );

      if (link) {
        link.channelId = repoId;
        link.meta = {
          ...link.meta,
          syncProvider: "github-issues",
          syncableId: repoId,
        };
        await this.tools.integrations.saveLink(link);
        processedInBatch++;
      }
    }

    // Check if there are more pages (GitHub returns less than per_page when done)
    const hasMorePages = issues.length === 50;

    if (hasMorePages) {
      await this.set<SyncState>(`sync_state_${repoId}`, {
        page: state.page + 1,
        batchNumber: state.batchNumber + 1,
        issuesProcessed: state.issuesProcessed + processedInBatch,
        initialSync: state.initialSync,
        phase: state.phase,
      });

      const nextBatch = await this.callback(
        this.syncBatch,
        repoId,
        options ?? null
      );
      await this.tools.tasks.runTask(nextBatch);
    } else if (state.phase === "open") {
      // Move to closed phase
      await this.set<SyncState>(`sync_state_${repoId}`, {
        page: 1,
        batchNumber: state.batchNumber + 1,
        issuesProcessed: state.issuesProcessed + processedInBatch,
        initialSync: state.initialSync,
        phase: "closed",
      });

      const closedBatch = await this.callback(
        this.syncBatch,
        repoId,
        options ?? null
      );
      await this.tools.tasks.runTask(closedBatch);
    } else {
      // Both phases complete
      await this.clear(`sync_state_${repoId}`);
    }
  }

  /**
   * Convert a GitHub issue to a NewLinkWithNotes
   */
  private async convertIssueToLink(
    octokit: Octokit,
    issue: any,
    repoId: string,
    repoFullName: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes | null> {
    // Build author contact (GitHub users may not have email)
    let authorContact: NewContact | undefined;
    if (issue.user) {
      authorContact = {
        email: issue.user.email || `${issue.user.login}@users.noreply.github.com`,
        name: issue.user.login,
        avatar: issue.user.avatar_url ?? undefined,
      };
    }

    // Build assignee contact
    let assigneeContact: NewContact | undefined;
    const assignee = issue.assignees?.[0] || issue.assignee;
    if (assignee) {
      assigneeContact = {
        email: assignee.email || `${assignee.login}@users.noreply.github.com`,
        name: assignee.login,
        avatar: assignee.avatar_url ?? undefined,
      };
    }

    // Prepare description
    const description = issue.body || "";
    const hasDescription = description.trim().length > 0;

    // Build thread-level actions
    const threadActions: Action[] = [];
    if (issue.html_url) {
      threadActions.push({
        type: ActionType.external,
        title: "Open in GitHub",
        url: issue.html_url,
      });
    }

    // Build notes array (inline notes don't require the `thread` field)
    const notes: any[] = [];

    notes.push({
      key: "description",
      content: hasDescription ? description : null,
      created: issue.created_at,
      author: authorContact,
    });

    // Fetch comments
    const [owner, repo] = repoFullName.split("/");
    try {
      let commentPage = 1;
      let hasMoreComments = true;

      while (hasMoreComments) {
        const commentsResponse = await octokit.rest.issues.listComments({
          owner,
          repo,
          issue_number: issue.number,
          per_page: 100,
          page: commentPage,
        });

        for (const comment of commentsResponse.data) {
          let commentAuthor: NewContact | undefined;
          if (comment.user) {
            commentAuthor = {
              email:
                comment.user.email ||
                `${comment.user.login}@users.noreply.github.com`,
              name: comment.user.login,
              avatar: comment.user.avatar_url ?? undefined,
            };
          }

          notes.push({
            key: `comment-${comment.id}`,
            content: comment.body ?? null,
            created: new Date(comment.created_at),
            author: commentAuthor,
          });
        }

        hasMoreComments = commentsResponse.data.length === 100;
        commentPage++;
      }
    } catch (error) {
      console.error(
        "Error fetching comments:",
        error instanceof Error ? error.message : String(error)
      );
    }

    const link: NewLinkWithNotes = {
      source: `github:issue:${repoId}:${issue.number}`,
      type: "issue",
      title: issue.title,
      created: issue.created_at,
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: issue.closed_at ? "closed" : "open",
      meta: {
        githubIssueNumber: issue.number,
        githubRepoId: repoId,
        githubRepoFullName: repoFullName,
        projectId: repoId,
      },
      actions: threadActions.length > 0 ? threadActions : undefined,
      sourceUrl: issue.html_url ?? null,
      notes,
      preview: hasDescription ? description : null,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };

    return link;
  }

  /**
   * Update issue with new values from the app
   */
  async updateIssue(
    link: import("@plotday/twister").Link
  ): Promise<void> {
    const issueNumber = link.meta?.githubIssueNumber as number | undefined;
    if (!issueNumber) {
      throw new Error("GitHub issue number not found in link meta");
    }

    const repoFullName = link.meta?.githubRepoFullName as string | undefined;
    if (!repoFullName) {
      throw new Error("GitHub repo name not found in link meta");
    }

    const projectId = link.meta?.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Project ID not found in link meta");
    }

    const octokit = await this.getClient(projectId);
    const [owner, repo] = repoFullName.split("/");

    const updateFields: {
      state?: "open" | "closed";
      assignees?: string[];
    } = {};

    // Handle open/close status based on link status
    const isDone = link.status === "done" || link.status === "closed" || link.status === "completed";
    updateFields.state = isDone ? "closed" : "open";

    // Handle assignee - use actor name as GitHub login
    if (link.assignee) {
      if (link.assignee.name) {
        updateFields.assignees = [link.assignee.name];
      }
    } else {
      updateFields.assignees = [];
    }

    if (Object.keys(updateFields).length > 0) {
      await octokit.rest.issues.update({
        owner,
        repo,
        issue_number: issueNumber,
        ...updateFields,
      });
    }
  }

  /**
   * Add a comment to a GitHub issue
   */
  async addIssueComment(
    meta: ThreadMeta,
    body: string
  ): Promise<string | void> {
    const issueNumber = meta.githubIssueNumber as number | undefined;
    if (!issueNumber) {
      throw new Error("GitHub issue number not found in thread meta");
    }

    const repoFullName = meta.githubRepoFullName as string | undefined;
    if (!repoFullName) {
      throw new Error("GitHub repo name not found in thread meta");
    }

    const projectId = meta.projectId as string | undefined;
    if (!projectId) {
      throw new Error("Project ID not found in thread meta");
    }

    const octokit = await this.getClient(projectId);
    const [owner, repo] = repoFullName.split("/");

    const response = await octokit.rest.issues.createComment({
      owner,
      repo,
      issue_number: issueNumber,
      body,
    });

    if (response.data.id) {
      return `comment-${response.data.id}`;
    }
  }

  /**
   * Handle incoming webhook events from GitHub
   */
  private async onWebhook(
    request: WebhookRequest,
    repoId: string
  ): Promise<void> {
    // Verify signature
    const secret = await this.get<string>(`webhook_secret_${repoId}`);
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

    // Verify HMAC-SHA256 signature
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const sig = await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(request.rawBody)
    );
    const expectedSignature =
      "sha256=" +
      Array.from(new Uint8Array(sig))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    if (signature !== expectedSignature) {
      console.warn("GitHub webhook signature verification failed");
      return;
    }

    const event = request.headers["x-github-event"];
    const payload = request.body as any;

    if (event === "issues") {
      await this.handleIssueWebhook(payload, repoId);
    } else if (event === "issue_comment") {
      await this.handleCommentWebhook(payload, repoId);
    }
  }

  /**
   * Handle Issue webhook events
   */
  private async handleIssueWebhook(
    payload: any,
    repoId: string
  ): Promise<void> {
    const issue = payload.issue;
    if (!issue) return;

    // Skip pull requests
    if (issue.pull_request) return;

    const repoFullName = payload.repository?.full_name;
    if (!repoFullName) return;

    let authorContact: NewContact | undefined;
    if (issue.user) {
      authorContact = {
        email:
          issue.user.email ||
          `${issue.user.login}@users.noreply.github.com`,
        name: issue.user.login,
        avatar: issue.user.avatar_url ?? undefined,
      };
    }

    let assigneeContact: NewContact | undefined;
    const assignee = issue.assignees?.[0] || issue.assignee;
    if (assignee) {
      assigneeContact = {
        email:
          assignee.email ||
          `${assignee.login}@users.noreply.github.com`,
        name: assignee.login,
        avatar: assignee.avatar_url ?? undefined,
      };
    }

    const link: NewLinkWithNotes = {
      source: `github:issue:${repoId}:${issue.number}`,
      type: "issue",
      title: issue.title,
      created: issue.created_at,
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: issue.closed_at ? "closed" : "open",
      channelId: repoId,
      meta: {
        githubIssueNumber: issue.number,
        githubRepoId: repoId,
        githubRepoFullName: repoFullName,
        projectId: repoId,
        syncProvider: "github-issues",
        syncableId: repoId,
      },
      preview: issue.body || null,
      notes: [],
    };

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Handle Comment webhook events
   */
  private async handleCommentWebhook(
    payload: any,
    repoId: string
  ): Promise<void> {
    const comment = payload.comment;
    const issue = payload.issue;
    if (!comment || !issue) return;

    // Skip comments on pull requests
    if (issue.pull_request) return;

    const repoFullName = payload.repository?.full_name;
    if (!repoFullName) return;

    let commentAuthor: NewContact | undefined;
    if (comment.user) {
      commentAuthor = {
        email:
          comment.user.email ||
          `${comment.user.login}@users.noreply.github.com`,
        name: comment.user.login,
        avatar: comment.user.avatar_url ?? undefined,
      };
    }

    const linkSource = `github:issue:${repoId}:${issue.number}`;

    const link: NewLinkWithNotes = {
      source: linkSource,
      type: "issue",
      title: issue.title || `#${issue.number}`, // Placeholder; upsert by source will preserve existing title
      notes: [
        {
          key: `comment-${comment.id}`,
          content: comment.body ?? null,
          created: comment.created_at,
          author: commentAuthor,
        } as any,
      ],
      channelId: repoId,
      meta: {
        githubIssueNumber: issue.number,
        githubRepoId: repoId,
        githubRepoFullName: repoFullName,
        projectId: repoId,
        syncProvider: "github-issues",
        syncableId: repoId,
      },
    };

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Stop syncing a GitHub repo
   */
  async stopSync(projectId: string): Promise<void> {
    // Remove webhook
    const webhookId = await this.get<number>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const octokit = await this.getClient(projectId);
        const { owner, repo } = await this.getRepoInfo(projectId);
        await octokit.rest.repos.deleteWebhook({
          owner,
          repo,
          hook_id: webhookId,
        });
      } catch (error) {
        console.warn("Failed to delete GitHub webhook:", error);
      }
      await this.clear(`webhook_id_${projectId}`);
    }

    // Cleanup webhook secret
    await this.clear(`webhook_secret_${projectId}`);

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default GitHubIssues;
