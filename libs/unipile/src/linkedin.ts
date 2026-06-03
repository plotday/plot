import { UnipileMessaging, type ChatProfile } from "./messaging";

/** LinkedIn connection request (invitation). */
export type LinkedInInvitation = {
  id: string;
  sharedSecret: string;
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
    sharedSecret: string;
  }): Promise<void>;

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract ignoreInvitation(params: {
    channelId: string;
    invitationId: string;
    sharedSecret: string;
  }): Promise<void>;
}
