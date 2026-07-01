import { UnipileMessaging, type ChatProfile } from "./messaging";
import type {
  LinkedInComment,
  LinkedInPost,
  LinkedInPostReaction,
  PostAttachment,
} from "./linkedin-posts";

/** LinkedIn connection request (invitation). */
export type LinkedInInvitation = {
  id: string;
  inviter: ChatProfile;
  message: string | null;
  sentAt: Date;
};
export type LinkedInInvitationPage = {
  invitations: LinkedInInvitation[];
  nextCursor: string | null;
};
export type LinkedInRelationPage = {
  relations: ChatProfile[];
  nextCursor: string | null;
};

/**
 * LinkedIn messaging tool: the common surface plus LinkedIn-only
 * invitations and 1st-degree relations. Implementation:
 * `workers/api/src/twist/tools/unipile/linkedin.ts`.
 */
export abstract class LinkedInMessaging extends UnipileMessaging {
  static readonly toolId = "LinkedInMessaging";

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listReceivedInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listRelations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInRelationPage>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract acceptInvitation(params: {
    channelId: string;
    invitationId: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createPost(params: {
    channelId: string;
    text: string;
    attachments?: PostAttachment[];
  }): Promise<{ postId: string }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listOwnPosts(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ posts: LinkedInPost[]; nextCursor: string | null }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract getPost(params: {
    channelId: string;
    postId: string;
  }): Promise<LinkedInPost | null>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listComments(params: {
    channelId: string;
    postId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ comments: LinkedInComment[]; nextCursor: string | null }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createComment(params: {
    channelId: string;
    postId: string;
    text: string;
    parentCommentId?: string | null;
    attachments?: PostAttachment[];
  }): Promise<{ commentId: string }>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract reactToPost(params: {
    channelId: string;
    socialId: string;
    reactionType: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract unreactToPost(params: {
    channelId: string;
    socialId: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract listPostReactions(params: {
    channelId: string;
    socialId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ reactions: LinkedInPostReaction[]; nextCursor: string | null }>;
}
