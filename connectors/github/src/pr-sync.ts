import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { GitHub, GitHubPullRequest, GitHubReview, GitHubIssueComment } from "./github";

/** Days of recently closed/merged PRs to include in sync */
const RECENT_DAYS = 30;
/** PRs per page for batch sync */
const PAGE_SIZE = 50;

type PRSyncState = {
  page: number;
  batchNumber: number;
  prsProcessed: number;
  initialSync: boolean;
};

/**
 * Initialize batch sync process for pull requests
 */
export async function startPRBatchSync(
  source: GitHub,
  repositoryId: string,
  initialSync: boolean,
): Promise<void> {
  await source.set(`pr_sync_state_${repositoryId}`, {
    page: 1,
    batchNumber: 1,
    prsProcessed: 0,
    initialSync,
  } satisfies PRSyncState);

  const batchCallback = await source.createCallback(source.syncPRBatch, repositoryId);
  await source.runTask(batchCallback);
}

/**
 * Process a batch of pull requests
 */
export async function syncPRBatch(
  source: GitHub,
  repositoryId: string,
): Promise<void> {
  const state = await source.get<PRSyncState>(`pr_sync_state_${repositoryId}`);
  if (!state) {
    throw new Error(`PR sync state not found for repository ${repositoryId}`);
  }

  const token = await source.getToken(repositoryId);
  const [owner, repo] = repositoryId.split("/");

  const response = await source.githubFetch(
    token,
    `/repos/${owner}/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=${PAGE_SIZE}&page=${state.page}`,
  );

  if (!response.ok) {
    throw new Error(
      `Failed to fetch PRs: ${response.status} ${await response.text()}`,
    );
  }

  const prs: GitHubPullRequest[] = await response.json();

  // Filter: open PRs + recently closed/merged (within RECENT_DAYS)
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - RECENT_DAYS);

  const relevantPRs = prs.filter((pr) => {
    if (pr.state === "open") return true;
    const closedDate = pr.merged_at || pr.closed_at;
    if (closedDate && new Date(closedDate) >= cutoff) return true;
    return false;
  });

  const allBeyondCutoff =
    prs.length > 0 &&
    prs.every((pr) => {
      if (pr.state === "open") return false;
      const closedDate = pr.merged_at || pr.closed_at;
      return closedDate && new Date(closedDate) < cutoff;
    });

  for (const pr of relevantPRs) {
    const thread = await convertPRToThread(
      source,
      token,
      owner,
      repo,
      pr,
      repositoryId,
      state.initialSync,
    );

    if (thread) {
      thread.channelId = repositoryId;
      thread.meta = {
        ...thread.meta,
        syncProvider: "github",
        syncableId: repositoryId,
      };
      await source.saveLink(thread);
    }
  }

  if (prs.length === PAGE_SIZE && !allBeyondCutoff) {
    await source.set(`pr_sync_state_${repositoryId}`, {
      page: state.page + 1,
      batchNumber: state.batchNumber + 1,
      prsProcessed: state.prsProcessed + relevantPRs.length,
      initialSync: state.initialSync,
    } satisfies PRSyncState);

    const nextBatch = await source.createCallback(source.syncPRBatch, repositoryId);
    await source.runTask(nextBatch);
  } else {
    await source.clear(`pr_sync_state_${repositoryId}`);
  }
}

/**
 * Convert a GitHub PR to a NewLinkWithNotes
 */
async function convertPRToThread(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  pr: GitHubPullRequest,
  repositoryId: string,
  initialSync: boolean,
): Promise<NewLinkWithNotes | null> {
  const authorContact = source.userToContact(pr.user);
  const assigneeContact = pr.assignee
    ? source.userToContact(pr.assignee)
    : null;

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

  // Fetch general comments
  try {
    const commentsResponse = await source.githubFetch(
      token,
      `/repos/${owner}/${repo}/issues/${pr.number}/comments?per_page=100`,
    );
    if (commentsResponse.ok) {
      const comments: GitHubIssueComment[] = await commentsResponse.json();
      for (const comment of comments) {
        const commentAuthor = source.userToContact(comment.user);
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
    const reviewsResponse = await source.githubFetch(
      token,
      `/repos/${owner}/${repo}/pulls/${pr.number}/reviews?per_page=100`,
    );
    if (reviewsResponse.ok) {
      const reviews: GitHubReview[] = await reviewsResponse.json();
      for (const review of reviews) {
        if (review.state === "COMMENTED" && !review.body) continue;

        const reviewAuthor = source.userToContact(review.user);
        const prefix = reviewStatePrefix(review.state);
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
    status: pr.merged_at
      ? "merged"
      : pr.state === "closed"
        ? "closed"
        : "open",
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
    ...(!initialSync && pr.state === "closed" && !pr.merged_at
      ? { archived: true }
      : {}),
  };

  return thread;
}

/**
 * Handle pull_request webhook event
 */
export async function handlePRWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const pr: GitHubPullRequest = payload.pull_request;
  if (!pr) return;

  const [owner, repo] = repositoryId.split("/");

  const authorContact = source.userToContact(pr.user);
  const assigneeContact = pr.assignee
    ? source.userToContact(pr.assignee)
    : null;

  const thread: NewLinkWithNotes = {
    source: `github:pr:${owner}/${repo}/${pr.number}`,
    type: "pull_request",
    title: pr.title,
    created: new Date(pr.created_at),
    author: authorContact,
    assignee: assigneeContact,
    status: pr.merged_at
      ? "merged"
      : pr.state === "closed"
        ? "closed"
        : "open",
    ...(pr.state === "closed" && !pr.merged_at ? { archived: true } : {}),
    channelId: repositoryId,
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

  await source.saveLink(thread);
}

/**
 * Handle pull_request_review webhook event
 */
export async function handleReviewWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const review: GitHubReview = payload.review;
  const pr: GitHubPullRequest = payload.pull_request;
  if (!review || !pr) return;

  if (review.state === "COMMENTED" && !review.body) return;

  const [owner, repo] = repositoryId.split("/");
  const reviewAuthor = source.userToContact(review.user);

  const prefix = reviewStatePrefix(review.state);
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
    channelId: repositoryId,
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

  await source.saveLink(thread);
}

/**
 * Handle issue_comment webhook event (for PR comments)
 */
export async function handlePRCommentWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const comment: GitHubIssueComment = payload.comment;
  const issue = payload.issue;
  if (!comment || !issue) return;

  const [owner, repo] = repositoryId.split("/");
  const prNumber = issue.number;
  const commentAuthor = source.userToContact(comment.user);

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
    channelId: repositoryId,
    meta: {
      provider: "github",
      owner,
      repo,
      prNumber,
      syncProvider: "github",
      syncableId: repositoryId,
    },
  };

  await source.saveLink(thread);
}

/**
 * Add a general comment to a pull request
 */
export async function addPRComment(
  source: GitHub,
  meta: import("@plotday/twister").ThreadMeta,
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

  const token = await source.getToken(syncableId);

  const response = await source.githubFetch(
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
export async function updatePRStatus(
  source: GitHub,
  link: import("@plotday/twister").Link,
): Promise<void> {
  if (!link.meta) return;

  const owner = link.meta.owner as string;
  const repo = link.meta.repo as string;
  const prNumber = link.meta.prNumber as number;
  const syncableId = `${owner}/${repo}`;

  if (!owner || !repo || !prNumber) {
    throw new Error("Owner, repo, and prNumber required in link meta");
  }

  const token = await source.getToken(syncableId);

  const isDone = link.status === "done" || link.status === "closed" || link.status === "approved";
  if (isDone) {
    const response = await source.githubFetch(
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
        `Failed to update PR status: ${response.status}`,
      );
    }
  }
}

/**
 * Close a pull request without merging
 */
export async function closePR(
  source: GitHub,
  meta: import("@plotday/twister").ThreadMeta,
): Promise<void> {
  const owner = meta.owner as string;
  const repo = meta.repo as string;
  const prNumber = meta.prNumber as number;
  const syncableId = `${owner}/${repo}`;

  if (!owner || !repo || !prNumber) {
    throw new Error("Owner, repo, and prNumber required in thread meta");
  }

  const token = await source.getToken(syncableId);

  const response = await source.githubFetch(
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

function reviewStatePrefix(
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
