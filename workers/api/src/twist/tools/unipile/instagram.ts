import type { InstagramMessaging as IInstagramMessaging } from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";

export function normalizeUsername(input: string): string | null {
  const u = input.trim().replace(/^@/, "").trim();
  return u.length ? u : null;
}

export class InstagramMessaging extends UnipileMessagingTool implements IInstagramMessaging {
  protected readonly provider = "instagram";

  override async resolveRecipient(params: { channelId: string; address: string }): Promise<string | null> {
    await this.assertAccount(params.channelId);
    const username = normalizeUsername(params.address);
    if (!username) return null;
    // LIVE-CONFIRM: exact Users endpoint/param for IG username → provider id.
    try {
      const user = await this.client.getUser({ accountId: params.channelId, identifier: username });
      return user.id ?? null;
    } catch {
      return null;
    }
  }

  async setMessageRequestAccepted(params: { channelId: string; chatId: string; accepted: boolean }): Promise<void> {
    await this.assertAccount(params.channelId);
    // LIVE-CONFIRM: IG accept/ignore message-request action on PATCH chat.
    await this.client.setChatRequestStatus({ accountId: params.channelId, chatId: params.chatId, accepted: params.accepted });
  }
}
