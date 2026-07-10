import type { GitHub } from "./github";
import { EMOJI_TO_GITHUB_REACTION } from "./github-emoji";

/**
 * Routes a note `key` to the GitHub API namespace it belongs to.
 * `review-comment-` and `comment-` are disjoint prefixes (neither is a
 * prefix of the other), so check order doesn't matter — `review-comment-`
 * is checked first purely for readability, since it's the more specific
 * case conceptually.
 */
export function commentEndpointForKey(
  key: string | null
): { commentId: string; kind: "issue" | "review" } | null {
  if (!key) return null;
  const reviewMatch = key.match(/^review-comment-(\d+)$/);
  if (reviewMatch) return { commentId: reviewMatch[1], kind: "review" };
  const issueMatch = key.match(/^comment-(\d+)$/);
  if (issueMatch) return { commentId: issueMatch[1], kind: "issue" };
  return null;
}

function reactionsPath(
  owner: string,
  repo: string,
  commentId: string,
  kind: "issue" | "review"
): string {
  const namespace = kind === "issue" ? "issues" : "pulls";
  return `/repos/${owner}/${repo}/${namespace}/comments/${commentId}/reactions`;
}

/**
 * Add a reaction to a comment. Best-effort: swallows failures (rate limit,
 * comment deleted since) rather than throwing, since this is dispatched
 * from a user's own reaction toggle in Plot — surfacing a hard failure
 * back to the user for a GitHub-side hiccup would be poor UX for a
 * secondary action like a reaction.
 */
export async function reactToComment(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  key: string,
  emoji: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  const githubReaction = EMOJI_TO_GITHUB_REACTION[emoji];
  if (!endpoint || !githubReaction) return;

  try {
    const response = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: githubReaction }),
      }
    );
    if (!response.ok) {
      console.warn(
        `[github] Failed to add reaction ${githubReaction} to ${key}: ${response.status}`
      );
    }
  } catch (error) {
    console.warn(`[github] Error adding reaction ${githubReaction} to ${key}:`, error);
  }
}

/**
 * Remove a reaction from a comment. GitHub's DELETE endpoint is keyed on
 * the reaction's OWN id (not the comment id + content), so this must first
 * list the comment's reactions to find which one to delete — the reaction
 * poll (Task 9) already does this same list call, but outbound removal is
 * a separate, immediate user action and can't wait for the next poll.
 */
export async function unreactToComment(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  key: string,
  emoji: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  const githubReaction = EMOJI_TO_GITHUB_REACTION[emoji];
  if (!endpoint || !githubReaction) return;

  try {
    const listResponse = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind) +
        `?content=${encodeURIComponent(githubReaction)}`
    );
    if (!listResponse.ok) return;
    const reactions: Array<{ id: number; user: { login: string } }> =
      await listResponse.json();
    // Best-effort: GitHub's API has no per-user identity we can correlate
    // to "the Plot actor who unreacted" without a second lookup, so this
    // removes the FIRST matching reaction of this content type. In
    // practice each Plot actor maps to exactly one GitHub account, and
    // GitHub only allows one reaction per (user, content) per comment, so
    // this is precise for the common case of that account's own reaction.
    const target = reactions[0];
    if (!target) return;

    const deleteResponse = await source.githubFetch(
      token,
      `${reactionsPath(owner, repo, endpoint.commentId, endpoint.kind)}/${target.id}`,
      { method: "DELETE" }
    );
    if (!deleteResponse.ok) {
      console.warn(
        `[github] Failed to remove reaction ${githubReaction} from ${key}: ${deleteResponse.status}`
      );
    }
  } catch (error) {
    console.warn(`[github] Error removing reaction ${githubReaction} from ${key}:`, error);
  }
}
