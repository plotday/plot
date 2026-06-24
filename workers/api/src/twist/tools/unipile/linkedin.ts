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
    const offset = params.cursor ? Number(params.cursor) : 0;
    const result = await this.client.listReceivedInvitations({ accountId: params.channelId, offset, limit: params.limit });
    const nextCursor = result.has_more ? String(offset + result.data.length) : null;
    return { invitations: result.data.map(normalizeInvitation), nextCursor };
  }

  async listRelations(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<LinkedInRelationPage> {
    await this.assertAccount(params.channelId);
    const offset = params.cursor ? Number(params.cursor) : 0;
    const result = await this.client.listRelations({ accountId: params.channelId, offset, limit: params.limit });
    const nextCursor = result.has_more ? String(offset + result.data.length) : null;
    return { relations: result.data.map(normalizeRelation), nextCursor };
  }

  async acceptInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.acceptInvitation({ accountId: params.channelId, invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }

  async ignoreInvitation(params: { channelId: string; invitationId: string; sharedSecret: string }): Promise<void> {
    await this.assertAccount(params.channelId);
    await this.client.ignoreInvitation({ accountId: params.channelId, invitationId: params.invitationId, sharedSecret: params.sharedSecret });
  }
}

export { normalizeProfile };
