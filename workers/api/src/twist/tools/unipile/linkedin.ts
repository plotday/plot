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
    await this.assertAccount(params.channelId);
    const result = await this.client.listReceivedInvitations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    return { invitations: result.items.map(normalizeInvitation), nextCursor: result.cursor };
  }

  async listRelations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInRelationPage> {
    await this.assertAccount(params.channelId);
    const result = await this.client.listRelations({ accountId: params.channelId, cursor: params.cursor ?? null, limit: params.limit });
    return { relations: result.items.map(normalizeRelation), nextCursor: result.cursor };
  }

  async acceptInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.acceptInvitation({ invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }

  async ignoreInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.ignoreInvitation({ invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }
}

export { normalizeProfile };
