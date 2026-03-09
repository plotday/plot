import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { GitHub, GitHubIssueComment } from "./github";

/** Issues per page for batch sync */
const PAGE_SIZE = 50;

type IssueSyncState = {
  page: number;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
  phase: "open" | "closed";
};

/**
 * Initialize batch sync process for issues
 */
export async function startIssueBatchSync(
  source: GitHub,
  repositoryId: string,
  initialSync: boolean,
): Promise<void> {
  await source.set(`issue_sync_state_${repositoryId}`, {
    page: 1,
    batchNumber: 1,
    issuesProcessed: 0,
    initialSync,
    phase: "open",
  } satisfies IssueSyncState);

  const batchCallback = await source.createCallback(source.syncIssueBatch, repositoryId);
  await source.runTask(batchCallback);
}

/**
 * Process a batch of issues
 */
export async function syncIssueBatch(
  source: GitHub,
  repositoryId: string,
): Promise<void> {
  const state = await source.get<IssueSyncState>(`issue_sync_state_${repositoryId}`);
  if (!state) {
    throw new Error(`Issue sync state not found for repository ${repositoryId}`);
  }

  const token = await source.getToken(repositoryId);
  const [owner, repo] = repositoryId.split("/");

  // Build request URL based on phase
  let url = `/repos/${owner}/${repo}/issues?state=${state.phase}&per_page=${PAGE_SIZE}&page=${state.page}&sort=updated&direction=desc`;

  // For closed phase, only fetch recently closed (last 30 days)
  if (state.phase === "closed") {
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    url += `&since=${thirtyDaysAgo.toISOString()}`;
  }

  const response = await source.githubFetch(token, url);

  if (!response.ok) {
    throw new Error(
      `Failed to fetch issues: ${response.status} ${await response.text()}`,
    );
  }

  const issues: any[] = await response.json();

  // Process each issue (filter out PRs — GitHub returns PRs in issues endpoint)
  let processedInBatch = 0;
  for (const issue of issues) {
    if (issue.pull_request) continue;

    const link = await convertIssueToLink(
      source,
      token,
      owner,
      repo,
      issue,
      repositoryId,
      state.initialSync,
    );

    if (link) {
      link.channelId = repositoryId;
      link.meta = {
        ...link.meta,
        syncProvider: "github",
        syncableId: repositoryId,
      };
      await source.saveLink(link);
      processedInBatch++;
    }
  }

  const hasMorePages = issues.length === PAGE_SIZE;

  if (hasMorePages) {
    await source.set(`issue_sync_state_${repositoryId}`, {
      page: state.page + 1,
      batchNumber: state.batchNumber + 1,
      issuesProcessed: state.issuesProcessed + processedInBatch,
      initialSync: state.initialSync,
      phase: state.phase,
    } satisfies IssueSyncState);

    const nextBatch = await source.createCallback(source.syncIssueBatch, repositoryId);
    await source.runTask(nextBatch);
  } else if (state.phase === "open") {
    // Move to closed phase
    await source.set(`issue_sync_state_${repositoryId}`, {
      page: 1,
      batchNumber: state.batchNumber + 1,
      issuesProcessed: state.issuesProcessed + processedInBatch,
      initialSync: state.initialSync,
      phase: "closed",
    } satisfies IssueSyncState);

    const closedBatch = await source.createCallback(source.syncIssueBatch, repositoryId);
    await source.runTask(closedBatch);
  } else {
    // Both phases complete
    await source.clear(`issue_sync_state_${repositoryId}`);
  }
}

/**
 * Convert a GitHub issue to a NewLinkWithNotes
 */
async function convertIssueToLink(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  issue: any,
  repositoryId: string,
  initialSync: boolean,
): Promise<NewLinkWithNotes | null> {
  const authorContact = issue.user ? source.userToContact(issue.user) : undefined;

  const assignee = issue.assignees?.[0] || issue.assignee;
  const assigneeContact = assignee ? source.userToContact(assignee) : undefined;

  const description = issue.body || "";
  const hasDescription = description.trim().length > 0;

  const threadActions: Action[] = [];
  if (issue.html_url) {
    threadActions.push({
      type: ActionType.external,
      title: "Open in GitHub",
      url: issue.html_url,
    });
  }

  const notes: any[] = [];

  notes.push({
    key: "description",
    content: hasDescription ? description : null,
    created: issue.created_at,
    author: authorContact,
  });

  // Fetch comments
  try {
    let commentPage = 1;
    let hasMoreComments = true;

    while (hasMoreComments) {
      const commentsResponse = await source.githubFetch(
        token,
        `/repos/${owner}/${repo}/issues/${issue.number}/comments?per_page=100&page=${commentPage}`,
      );

      if (!commentsResponse.ok) break;

      const comments: GitHubIssueComment[] = await commentsResponse.json();
      for (const comment of comments) {
        const commentAuthor = source.userToContact(comment.user);
        notes.push({
          key: `comment-${comment.id}`,
          content: comment.body ?? null,
          created: new Date(comment.created_at),
          author: commentAuthor,
        });
      }

      hasMoreComments = comments.length === 100;
      commentPage++;
    }
  } catch (error) {
    console.error("Error fetching issue comments:", error);
  }

  const link: NewLinkWithNotes = {
    source: `github:issue:${owner}/${repo}/${issue.number}`,
    type: "issue",
    title: issue.title,
    created: issue.created_at,
    author: authorContact,
    assignee: assigneeContact ?? null,
    status: issue.closed_at ? "closed" : "open",
    meta: {
      provider: "github",
      owner,
      repo,
      issueNumber: issue.number,
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
 * Handle issues webhook event
 */
export async function handleIssueWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const issue = payload.issue;
  if (!issue) return;

  // Skip pull requests
  if (issue.pull_request) return;

  const [owner, repo] = repositoryId.split("/");

  const authorContact = issue.user ? source.userToContact(issue.user) : undefined;
  const assignee = issue.assignees?.[0] || issue.assignee;
  const assigneeContact = assignee ? source.userToContact(assignee) : undefined;

  const link: NewLinkWithNotes = {
    source: `github:issue:${owner}/${repo}/${issue.number}`,
    type: "issue",
    title: issue.title,
    created: issue.created_at,
    author: authorContact,
    assignee: assigneeContact ?? null,
    status: issue.closed_at ? "closed" : "open",
    channelId: repositoryId,
    meta: {
      provider: "github",
      owner,
      repo,
      issueNumber: issue.number,
      syncProvider: "github",
      syncableId: repositoryId,
    },
    preview: issue.body || null,
    notes: [],
  };

  await source.saveLink(link);
}

/**
 * Handle issue_comment webhook event (for issue comments, not PR comments)
 */
export async function handleIssueCommentWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const comment: GitHubIssueComment = payload.comment;
  const issue = payload.issue;
  if (!comment || !issue) return;

  // Skip comments on pull requests
  if (issue.pull_request) return;

  const [owner, repo] = repositoryId.split("/");
  const commentAuthor = source.userToContact(comment.user);

  const link: NewLinkWithNotes = {
    source: `github:issue:${owner}/${repo}/${issue.number}`,
    type: "issue",
    title: issue.title,
    notes: [
      {
        key: `comment-${comment.id}`,
        content: comment.body ?? null,
        created: comment.created_at,
        author: commentAuthor,
      } as any,
    ],
    channelId: repositoryId,
    meta: {
      provider: "github",
      owner,
      repo,
      issueNumber: issue.number,
      syncProvider: "github",
      syncableId: repositoryId,
    },
  };

  await source.saveLink(link);
}

/**
 * Update an issue's status and assignee
 */
export async function updateIssue(
  source: GitHub,
  link: import("@plotday/twister").Link,
): Promise<void> {
  if (!link.meta) return;

  const owner = link.meta.owner as string;
  const repo = link.meta.repo as string;
  const issueNumber = link.meta.issueNumber as number;
  const syncableId = `${owner}/${repo}`;

  if (!owner || !repo || !issueNumber) {
    throw new Error("Owner, repo, and issueNumber required in link meta");
  }

  const token = await source.getToken(syncableId);

  const updateFields: Record<string, any> = {};

  const isDone = link.status === "done" || link.status === "closed" || link.status === "completed";
  updateFields.state = isDone ? "closed" : "open";

  if (link.assignee) {
    if (link.assignee.name) {
      updateFields.assignees = [link.assignee.name];
    }
  } else {
    updateFields.assignees = [];
  }

  if (Object.keys(updateFields).length > 0) {
    const response = await source.githubFetch(
      token,
      `/repos/${owner}/${repo}/issues/${issueNumber}`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(updateFields),
      },
    );

    if (!response.ok) {
      throw new Error(
        `Failed to update issue: ${response.status} ${await response.text()}`,
      );
    }
  }
}

/**
 * Add a comment to a GitHub issue
 */
export async function addIssueComment(
  source: GitHub,
  meta: import("@plotday/twister").ThreadMeta,
  body: string,
): Promise<string | void> {
  const owner = meta.owner as string;
  const repo = meta.repo as string;
  const issueNumber = meta.issueNumber as number;
  const syncableId = `${owner}/${repo}`;

  if (!owner || !repo || !issueNumber) {
    throw new Error("Owner, repo, and issueNumber required in thread meta");
  }

  const token = await source.getToken(syncableId);

  const response = await source.githubFetch(
    token,
    `/repos/${owner}/${repo}/issues/${issueNumber}/comments`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body }),
    },
  );

  if (!response.ok) {
    throw new Error(
      `Failed to add issue comment: ${response.status} ${await response.text()}`,
    );
  }

  const comment = await response.json();
  if (comment?.id) {
    return `comment-${comment.id}`;
  }
}
