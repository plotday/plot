import type {
  LinkedInInvitationPage,
  LinkedInRelationPage,
  LinkedInMessaging as ILinkedInMessaging,
} from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";
import { normalizeInvitation, normalizeProfile, normalizeRelation } from "./normalize";

export class LinkedInMessaging extends UnipileMessagingTool implements ILinkedInMessaging {
  protected readonly provider = "linkedin";

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

  // `sharedSecret` is retained in the signature for interface compatibility but
  // is unused — v2 accept/ignore is keyed on the relation-request id alone.
  async acceptInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.acceptInvitation({ accountId: params.channelId, invitationId: params.invitationId })
    );
  }

  async ignoreInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.ignoreInvitation({ accountId: params.channelId, invitationId: params.invitationId })
    );
  }
}

export { normalizeProfile };
