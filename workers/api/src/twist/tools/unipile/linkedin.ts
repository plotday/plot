import type {
  ChatThreadPage,
  LinkedInInvitationPage,
  LinkedInRelationPage,
  LinkedInMessaging as ILinkedInMessaging,
  LinkedInComment,
  LinkedInPost,
  LinkedInPostReaction,
  PostAttachment,
} from "@plotday/unipile";
import { accountIdFromChannel } from "@plotday/unipile";
import { UnipileApiError } from "./client";
import { UnipileMessagingTool } from "./messaging";
import {
  normalizeChat,
  normalizeComment,
  normalizeInvitation,
  normalizePost,
  normalizePostReaction,
  normalizeProfile,
  normalizeRelation,
} from "./normalize";

export class LinkedInMessaging extends UnipileMessagingTool implements ILinkedInMessaging {
  protected readonly provider = "linkedin";

  // LinkedIn 501s on the generic GET /v2/:acc/chats ("Use List inbox Chats
  // endpoint for this provider"); chats are inbox-scoped. We backfill the
  // conversation inboxes (primary DMs + InMail) and skip archived/spam/jobs.
  private static readonly CHAT_INBOXES = ["CLASSIC_PRIMARY", "CLASSIC_INMAIL"];

  // Walk the conversation inboxes in order, one page at a time. The wrapper's
  // string cursor encodes "<inboxIndex>|<innerCursor>" so the connector's
  // existing single-cursor pagination keeps working across inboxes.
  override async listChats(params: { channelId: string; cursor?: string | null; limit?: number; since?: Date }): Promise<ChatThreadPage> {
    return this.withAccount(params.channelId, async () => {
      const inboxes = LinkedInMessaging.CHAT_INBOXES;
      let idx = 0;
      let inner: string | null = null;
      if (params.cursor) {
        const sep = params.cursor.indexOf("|");
        if (sep >= 0) {
          idx = Number(params.cursor.slice(0, sep)) || 0;
          inner = params.cursor.slice(sep + 1) || null;
        }
      }
      if (idx >= inboxes.length) return { chats: [], nextCursor: null };

      const result = await this.client.listInboxChats({
        accountId: params.channelId,
        inboxId: inboxes[idx]!,
        cursor: inner,
        limit: params.limit,
      });
      const chats = (result.data ?? [])
        .map((raw) => normalizeChat(raw, this.provider))
        .filter((c) => !params.since || c.lastActivityAt >= params.since);

      let nextCursor: string | null = null;
      if (result.next_cursor) nextCursor = `${idx}|${result.next_cursor}`;
      else if (idx + 1 < inboxes.length) nextCursor = `${idx + 1}|`;
      return { chats, nextCursor };
    });
  }

  async listReceivedInvitations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInInvitationPage> {
    return this.withAccount(params.channelId, async () => {
      // v2 relations/invitations are cursor-paginated (next_cursor), not offset.
      const result = await this.client.listReceivedInvitations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
      return { invitations: (result.data ?? []).map(normalizeInvitation), nextCursor: result.next_cursor ?? null };
    });
  }

  async listRelations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInRelationPage> {
    return this.withAccount(params.channelId, async () => {
      const result = await this.client.listRelations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
      return { relations: (result.data ?? []).map(normalizeRelation), nextCursor: result.next_cursor ?? null };
    });
  }

  // v2 accept/ignore is keyed on the relation-request id alone (no shared_secret).
  async acceptInvitation(params: { channelId: string; invitationId: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.acceptInvitation({ accountId: params.channelId, invitationId: params.invitationId })
    );
  }

  async ignoreInvitation(params: { channelId: string; invitationId: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.ignoreInvitation({ accountId: params.channelId, invitationId: params.invitationId })
    );
  }

  async createPost(params: { channelId: string; text: string; attachments?: PostAttachment[] }): Promise<{ postId: string }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.createPost({ accountId: acc, text: params.text, visibility: "public", attachments: params.attachments });
      const postId = res.social_id ?? res.post_id ?? res.id ?? "";
      return { postId };
    });
  }

  async listOwnPosts(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<{ posts: LinkedInPost[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listOwnPosts({ accountId: acc, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { posts: rows.map((p) => normalizePost(p, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }

  async getPost(params: { channelId: string; postId: string }): Promise<LinkedInPost | null> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      try {
        const raw = await this.client.getPost({ accountId: acc, postId: params.postId });
        return normalizePost(raw, this.provider);
      } catch (e) {
        if (e instanceof UnipileApiError && e.status === 404) return null;
        throw e;
      }
    });
  }

  async listComments(params: { channelId: string; postId: string; cursor?: string | null; limit?: number }): Promise<{ comments: LinkedInComment[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listComments({ accountId: acc, postId: params.postId, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { comments: rows.map((c) => normalizeComment(c, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }

  async createComment(params: { channelId: string; postId: string; text: string; parentCommentId?: string | null; attachments?: PostAttachment[] }): Promise<{ commentId: string }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.createComment({ accountId: acc, postId: params.postId, text: params.text, commentId: params.parentCommentId ?? null, attachments: params.attachments });
      return { commentId: res.comment_id ?? res.id ?? "" };
    });
  }

  async reactToPost(params: { channelId: string; socialId: string; reactionType: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.addPostReaction({ accountId: accountIdFromChannel(params.channelId), socialId: params.socialId, reactionType: params.reactionType })
    );
  }

  async unreactToPost(params: { channelId: string; socialId: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.removePostReaction({ accountId: accountIdFromChannel(params.channelId), socialId: params.socialId })
    );
  }

  async listPostReactions(params: { channelId: string; socialId: string; cursor?: string | null; limit?: number }): Promise<{ reactions: LinkedInPostReaction[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listPostReactions({ accountId: acc, socialId: params.socialId, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { reactions: rows.map((r) => normalizePostReaction(r, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }
}

export { normalizeProfile };
