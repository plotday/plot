import type { GitHub } from "./github";
import { EMOJI_TO_GITHUB_REACTION, GITHUB_REACTION_TO_EMOJI } from "./github-emoji";

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

type GitHubReactionEntry = { id: number; content: string; user: { id: number; login: string } };

/**
 * Fetch a comment's current reactions from GitHub and reconcile them into
 * Plot via `setNoteReactions` (clear-and-replace — this IS the note's full
 * reaction state, including removals since the last poll).
 */
export async function reconcileCommentReactions(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  prNumber: number,
  key: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  if (!endpoint) return;

  let entries: GitHubReactionEntry[];
  try {
    const response = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind)
    );
    if (!response.ok) return;
    entries = await response.json();
  } catch (error) {
    console.warn(`[github] Failed to fetch reactions for ${key}:`, error);
    return;
  }

  const reactions: Record<string, ReturnType<GitHub["userToContact"]>[]> = {};
  for (const entry of entries) {
    const emoji = GITHUB_REACTION_TO_EMOJI[entry.content];
    if (!emoji) continue; // GitHub reaction type we don't map (shouldn't happen — fixed set)
    reactions[emoji] = reactions[emoji] ?? [];
    reactions[emoji].push(source.userToContact(entry.user));
  }

  try {
    await source.setNoteReactions(
      { source: `github:pr:${owner}/${repo}/${prNumber}` },
      key,
      reactions as any
    );
  } catch (error) {
    console.warn(`[github] Failed to reconcile reactions for ${key}:`, error);
  }
}

/**
 * Recurring poll entry point (scheduleRecurring callback). Enumerates every
 * repo this connector instance is syncing, then every PR this connector has
 * tracked as open (Task 7's `open_pr_comment_keys_*` state — there is no
 * platform read-back for a connector's own synced links/notes, so this
 * state is the only source of truth for "which PRs are currently open").
 * For each tracked comment key, reconciles its reactions.
 */
export async function pollOpenPRReactions(source: GitHub): Promise<void> {
  const stateKeys = await source.listStoreKeys("open_pr_comment_keys_");
  for (const stateKey of stateKeys) {
    // Format: open_pr_comment_keys_<owner>/<repo>_<prNumber>
    const match = stateKey.match(/^open_pr_comment_keys_(.+)_(\d+)$/);
    if (!match) continue;
    const repositoryId = match[1];
    const prNumber = Number(match[2]);
    const [owner, repo] = repositoryId.split("/");
    if (!owner || !repo) continue;

    const keys = (await source.get<string[]>(stateKey)) ?? [];
    if (keys.length === 0) continue;

    let token: string;
    try {
      token = await source.getToken(repositoryId);
    } catch {
      continue; // token unavailable (needs reauth) — skip this repo this pass
    }

    for (const key of keys) {
      await reconcileCommentReactions(source, token, owner, repo, prNumber, key);
    }
  }
}
