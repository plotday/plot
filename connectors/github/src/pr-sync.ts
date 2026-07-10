import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";
import type {
  GitHub,
  GitHubPullRequest,
  GitHubReview,
  GitHubIssueComment,
  GitHubReviewComment,
} from "./github";

/** Days of recently closed/merged PRs to include in sync */
const RECENT_DAYS = 30;
/** PRs per page for batch sync */
const PAGE_SIZE = 50;

type PRSyncState = {
  page: number;
  batchNumber: number;
  prsProcessed: number;
  initialSync: boolean;
  syncHistoryMin?: string;
};

/**
 * Initialize batch sync process for pull requests
 */
export async function startPRBatchSync(
  source: GitHub,
  repositoryId: string,
  initialSync: boolean,
  syncHistoryMin?: Date,
): Promise<void> {
  await source.set(`pr_sync_state_${repositoryId}`, {
    page: 1,
    batchNumber: 1,
    prsProcessed: 0,
    initialSync,
    ...(syncHistoryMin ? { syncHistoryMin: syncHistoryMin.toISOString() } : {}),
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
    // Channel was disabled (stopSync clears state) or sync already completed
    // (terminal branch clears state) before this queued batch ran. Exit
    // quietly so the runtime acks the message instead of retrying forever.
    return;
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

  // Filter: open PRs + recently closed/merged (within RECENT_DAYS or syncHistoryMin)
  const cutoff = state.syncHistoryMin
    ? new Date(state.syncHistoryMin)
    : new Date(Date.now() - RECENT_DAYS * 24 * 60 * 60 * 1000);

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
    if (state.initialSync) {
      await source.markInitialSyncTypeDone(repositoryId);
    }
  }
}

/**
 * Fields common to a PR thread's "identity" — the source URL, the "Open in
 * GitHub" action, and the description note — shared by both the batch-sync
 * path (`convertPRToThread`) and the incremental webhook handlers so a PR
 * whose first sync happens via webhook gets full parity immediately instead
 * of waiting on a later batch resync to backfill it.
 */
export function buildPRThreadFields(
  source: GitHub,
  pr: GitHubPullRequest,
): {
  actions: Action[];
  sourceUrl: string;
  descriptionNote: { key: string; content: string | null; created: Date; author: NewContact };
} {
  const hasDescription = Boolean(pr.body && pr.body.trim().length > 0);
  return {
    actions: [
      {
        type: ActionType.external,
        title: `Open in GitHub`,
        url: pr.html_url,
      },
    ],
    sourceUrl: pr.html_url,
    descriptionNote: {
      key: "description",
      content: hasDescription ? pr.body : null,
      created: new Date(pr.created_at),
      author: source.userToContact(pr.user),
    },
  };
}

/**
 * Build a Plot note for an inline (code-line) PR review comment. File/line
 * context renders as a short header — not the full diff hunk, to avoid
 * clutter — followed by the comment body. Replies (GitHub's
 * `in_reply_to_id`) map to Plot's native `reNote` threading so they nest
 * under their parent instead of appearing as flat siblings.
 */
export function buildReviewCommentNote(
  source: GitHub,
  comment: GitHubReviewComment
): {
  key: string;
  content: string;
  created: Date;
  author: NewContact;
  reNote?: { key: string };
} {
  const location = comment.line ? `${comment.path}:${comment.line}` : comment.path;
  const note: {
    key: string;
    content: string;
    created: Date;
    author: NewContact;
    reNote?: { key: string };
  } = {
    key: `review-comment-${comment.id}`,
    content: `📄 ${location}\n\n${comment.body}`,
    created: new Date(comment.created_at),
    author: source.userToContact(comment.user),
  };
  if (comment.in_reply_to_id) {
    note.reNote = { key: `review-comment-${comment.in_reply_to_id}` };
  }
  return note;
}

/**
 * Fetch every inline review comment on a PR (paginated).
 */
export async function fetchReviewComments(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  prNumber: number
): Promise<GitHubReviewComment[]> {
  const response = await source.githubFetch(
    token,
    `/repos/${owner}/${repo}/pulls/${prNumber}/comments?per_page=100`
  );
  if (!response.ok) return [];
  return response.json();
}

function openPRCommentKeysStorageKey(repositoryId: string, prNumber: number): string {
  return `open_pr_comment_keys_${repositoryId}_${prNumber}`;
}

/**
 * Overwrite the full set of comment/review-comment note keys tracked for an
 * open PR. Called by batch sync (converges on every resync) and by the
 * `opened`/`reopened` webhook actions (full re-fetch, since a reopened PR's
 * prior key list was cleared on close).
 */
export async function recordOpenPRCommentKeys(
  source: GitHub,
  repositoryId: string,
  prNumber: number,
  keys: string[]
): Promise<void> {
  await source.set(openPRCommentKeysStorageKey(repositoryId, prNumber), keys);
}

/**
 * Append a single new comment/review-comment key to an open PR's tracked
 * set. Called by the incremental comment-created webhook handlers, which
 * know about exactly one new comment and shouldn't pay for a full re-fetch.
 * No-ops if the PR isn't currently tracked as open (e.g. a comment webhook
 * arriving for a PR this instance hasn't batch-synced yet — the next batch
 * pass or an `opened` webhook will pick it up via `recordOpenPRCommentKeys`).
 */
export async function appendOpenPRCommentKey(
  source: GitHub,
  repositoryId: string,
  prNumber: number,
  key: string
): Promise<void> {
  const storageKey = openPRCommentKeysStorageKey(repositoryId, prNumber);
  const existing = await source.get<string[]>(storageKey);
  if (!existing) return;
  if (existing.includes(key)) return;
  await source.set(storageKey, [...existing, key]);
}

/**
 * Stop tracking a PR's comment keys — called when a PR closes/merges, so
 * the reaction poller (Task 9) naturally excludes it on its next pass.
 */
export async function clearOpenPRCommentKeys(
  source: GitHub,
  repositoryId: string,
  prNumber: number
): Promise<void> {
  await source.clear(openPRCommentKeysStorageKey(repositoryId, prNumber));
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

  const { actions: threadActions, sourceUrl, descriptionNote } = buildPRThreadFields(source, pr);
  const notes: any[] = [descriptionNote];

  const hasDescription = Boolean(pr.body && pr.body.trim().length > 0);

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

  // Fetch inline (code-line) review comments
  try {
    const reviewComments = await fetchReviewComments(source, token, owner, repo, pr.number);
    for (const comment of reviewComments) {
      notes.push(buildReviewCommentNote(source, comment));
    }
  } catch (error) {
    console.error("Error fetching PR review comments:", error);
  }

  const commentKeys = notes
    .map((n) => n.key as string)
    .filter((k) => k.startsWith("comment-") || k.startsWith("review-comment-"));
  if (pr.state === "open") {
    await recordOpenPRCommentKeys(source, repositoryId, pr.number, commentKeys);
  } else {
    await clearOpenPRCommentKeys(source, repositoryId, pr.number);
  }

  const thread: NewLinkWithNotes = {
    channelId: repositoryId,
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
    sourceUrl,
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

  const { actions, sourceUrl, descriptionNote } = buildPRThreadFields(source, pr);
  const action = payload.action as string | undefined;
  const notes = action === "opened" || action === "edited" ? [descriptionNote] : [];

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
    actions,
    sourceUrl,
    preview: pr.body || null,
    notes,
  };

  await source.saveLink(thread);

  if (action === "opened" || action === "reopened") {
    const token = await source.getToken(repositoryId);
    const [issueComments, reviewComments] = await Promise.all([
      source
        .githubFetch(token, `/repos/${owner}/${repo}/issues/${pr.number}/comments?per_page=100`)
        .then((r) => (r.ok ? r.json() : [])),
      fetchReviewComments(source, token, owner, repo, pr.number),
    ]);
    const keys = [
      ...issueComments.map((c: { id: number }) => `comment-${c.id}`),
      ...reviewComments.map((c: GitHubReviewComment) => `review-comment-${c.id}`),
    ];
    await recordOpenPRCommentKeys(source, repositoryId, pr.number, keys);
  } else if (pr.state === "closed") {
    await clearOpenPRCommentKeys(source, repositoryId, pr.number);
  }
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

  const { actions, sourceUrl } = buildPRThreadFields(source, pr);

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
    actions,
    sourceUrl,
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
    sourceUrl: issue.html_url,
  };

  await source.saveLink(thread);

  if (payload.action === "created") {
    await appendOpenPRCommentKey(source, repositoryId, prNumber, `comment-${comment.id}`);
  }
}

/**
 * Handle pull_request_review_comment webhook event (inline code-line
 * comments — created/edited/deleted).
 */
export async function handlePRReviewCommentWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string,
): Promise<void> {
  const comment: GitHubReviewComment = payload.comment;
  const pr: GitHubPullRequest = payload.pull_request;
  const action: string = payload.action;
  if (!comment || !pr) return;

  const [owner, repo] = repositoryId.split("/");

  if (action === "deleted") {
    // No archive-note API on this connector today for any comment type
    // (top-level comments have the same gap) — out of scope here; the
    // note stays in Plot as historical record, matching existing behavior
    // for deleted top-level PR comments.
    return;
  }

  const note = buildReviewCommentNote(source, comment);

  const thread: NewLinkWithNotes = {
    source: `github:pr:${owner}/${repo}/${pr.number}`,
    type: "pull_request",
    title: pr.title,
    notes: [note as any],
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

  if (action === "created") {
    await appendOpenPRCommentKey(source, repositoryId, pr.number, note.key);
  }
}

/**
 * Add a general (conversation-level) comment to a pull request.
 *
 * Conversation comments on a PR are stored as issue comments on GitHub —
 * same endpoint, same body shape. Returns the created comment's id and
 * body so callers can record the external sync baseline.
 */
export async function addPRComment(
  source: GitHub,
  meta: import("@plotday/twister").ThreadMeta,
  body: string,
  _noteId?: string,
): Promise<{ id: number; body: string } | void> {
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
    return { id: comment.id, body: comment.body ?? body };
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
