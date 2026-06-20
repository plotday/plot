import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
} from "@plotday/twister";
import type { NewContact } from "@plotday/twister/plot";

/**
 * Batch sync fetch + transform for Linear issues.
 *
 * The previous sync path used the Linear SDK's lazy-loaded relations
 * (`issue.creator`, `issue.assignee`, `issue.state`, `issue.comments()`,
 * `issue.attachments()`, `comment.user`), each of which is a separate
 * GraphQL round-trip. With a batch of 50 issues that is 250+ sequential
 * network calls inside a single `syncBatch` execution. When Linear was
 * degraded the execution stretched for minutes and a Durable Object
 * storage operation exceeded its timeout, resetting the object
 * ("Durable Object storage operation exceeded timeout which caused object
 * to be reset"). Because the pagination cursor only advances at the end of
 * a batch, the queue retried the same batch forever → stuck sync + error
 * spam.
 *
 * This module fetches everything for a page of issues in ONE nested
 * GraphQL query and transforms the plain response into links with a pure,
 * unit-tested function — no per-issue round-trips.
 */

/** Issues fetched per `syncBatch` execution (one GraphQL query). */
export const ISSUES_PER_PAGE = 25;
/** Comments fetched inline per issue (matches the SDK's default page). */
export const COMMENTS_PER_ISSUE = 50;
/** Attachments fetched inline per issue (matches the SDK's default page). */
export const ATTACHMENTS_PER_ISSUE = 50;

/**
 * Single nested query for a page of a team's issues with all the related
 * data the transform needs. Linear caps query complexity at 10,000 points
 * (each scalar 0.1, each object 1, each connection multiplies its children
 * by its `first:` argument). At the page sizes above this query is roughly
 * `25 × (4.5 + 50×1.7 + 50×0.2) ≈ 2,500` points — comfortably under the cap.
 * See https://linear.app/developers/rate-limiting.
 */
export const TEAM_ISSUES_BATCH_QUERY = `
  query PlotTeamIssuesBatch($teamId: String!, $first: Int!, $after: String, $filter: IssueFilter) {
    team(id: $teamId) {
      issues(first: $first, after: $after, filter: $filter) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          title
          description
          url
          createdAt
          creator { id name email avatarUrl }
          assignee { id name email avatarUrl }
          state { id type }
          comments(first: ${COMMENTS_PER_ISSUE}) {
            nodes {
              id
              body
              createdAt
              user { id name email avatarUrl }
            }
          }
          attachments(first: ${ATTACHMENTS_PER_ISSUE}) {
            nodes { id title }
          }
        }
      }
    }
  }
`;

export type LinearUserData = {
  id?: string | null;
  name?: string | null;
  email?: string | null;
  avatarUrl?: string | null;
};

export type LinearCommentData = {
  id: string;
  body: string;
  createdAt: string;
  user: LinearUserData | null;
};

export type LinearAttachmentData = {
  id: string;
  title: string | null;
};

export type LinearIssueData = {
  id: string;
  title: string;
  description: string | null;
  url: string | null;
  createdAt: string;
  creator: LinearUserData | null;
  assignee: LinearUserData | null;
  state: { id: string; type: string } | null;
  comments: { nodes: LinearCommentData[] };
  attachments: { nodes: LinearAttachmentData[] };
};

export type TeamIssuesBatchResponse = {
  team: {
    issues: {
      pageInfo: { hasNextPage: boolean; endCursor: string | null };
      nodes: LinearIssueData[];
    };
  } | null;
};

/**
 * Resolve a contact from a Linear user object. Prefers the stable provider
 * account id (resolves without an email); falls back to email-only.
 */
export function resolveAuthorContact(
  user: LinearUserData | null | undefined
): NewContact | undefined {
  if (!user) return undefined;

  if (user.id) {
    return {
      ...(user.email ? { email: user.email } : {}),
      name: user.name ?? "",
      avatar: user.avatarUrl ?? undefined,
      source: { accountId: user.id },
    };
  }

  if (user.email) {
    return {
      email: user.email,
      name: user.name ?? "",
      avatar: user.avatarUrl ?? undefined,
    };
  }

  return undefined;
}

/**
 * Pure transform: a fully-loaded Linear issue (from the nested batch query)
 * into a `NewLinkWithNotes`. No network access — all related data is already
 * present on `issue`.
 */
export function buildIssueLink(
  issue: LinearIssueData,
  projectId: string,
  initialSync: boolean
): NewLinkWithNotes {
  const authorContact = resolveAuthorContact(issue.creator);

  let assigneeContact: NewContact | undefined;
  if (issue.assignee) {
    assigneeContact = {
      ...(issue.assignee.email ? { email: issue.assignee.email } : {}),
      name: issue.assignee.name ?? "",
      avatar: issue.assignee.avatarUrl ?? undefined,
      ...(issue.assignee.id ? { source: { accountId: issue.assignee.id } } : {}),
    };
  }

  // Use state ID as status — matches the dynamic linkTypes from getChannels().
  // Falls back to the state type category for the static linkTypes fallback.
  const state = issue.state;
  const status =
    state?.id ??
    (state?.type === "triage" ? "backlog" : state?.type ?? "unstarted");

  const description = issue.description || "";
  const hasDescription = description.trim().length > 0;

  // Thread-level actions: external link + inbound attachment fileRefs.
  const threadActions: Action[] = [];
  if (issue.url) {
    threadActions.push({
      type: ActionType.external,
      title: `Open in Linear`,
      url: issue.url,
    });
  }
  for (const att of issue.attachments.nodes) {
    threadActions.push({
      type: ActionType.fileRef,
      ref: att.id,
      fileName: att.title ?? "attachment",
      fileSize: null,
      mimeType: "application/octet-stream",
    } as Action);
  }

  // Description note + one note per comment.
  type IssueNote = NonNullable<NewLinkWithNotes["notes"]>[number];
  const notes: IssueNote[] = [];
  notes.push({
    key: "description",
    content: hasDescription ? description : null,
    created: new Date(issue.createdAt),
    author: authorContact,
  } as IssueNote);

  for (const comment of issue.comments.nodes) {
    notes.push({
      key: `comment-${comment.id}`,
      content: comment.body,
      created: new Date(comment.createdAt),
      author: resolveAuthorContact(comment.user),
    } as IssueNote);
  }

  return {
    source: `linear:issue:${issue.id}`,
    type: "issue",
    title: issue.title,
    created: new Date(issue.createdAt),
    author: authorContact,
    assignee: assigneeContact ?? null,
    status,
    meta: {
      linearId: issue.id,
      projectId,
    },
    actions: threadActions.length > 0 ? threadActions : undefined,
    sourceUrl: issue.url ?? null,
    notes,
    preview: hasDescription ? description : null,
    ...(initialSync ? { unread: false } : {}),
    ...(initialSync ? { archived: false } : {}),
  };
}
