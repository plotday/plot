import type {
  ChatThreadPage,
  LinkedInInvitationPage,
  LinkedInRelationPage,
  LinkedInMessaging as ILinkedInMessaging,
} from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";
import { normalizeChat, normalizeInvitation, normalizeProfile, normalizeRelation } from "./normalize";

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
}

export { normalizeProfile };
