import type { WhatsAppMessaging as IWhatsAppMessaging } from "@plotday/unipile";
import { UnipileMessagingTool } from "./messaging";

/** Convert a phone number to a WhatsApp JID. Returns null when no digits.
 * LIVE-CONFIRM (§13): whether Unipile accepts the JID directly in attendees_ids. */
export function phoneToJid(input: string): string | null {
  if (/@s\.whatsapp\.net$/.test(input.trim())) return input.trim();
  const digits = input.replace(/\D/g, "");
  if (digits.length < 5) return null;
  return `${digits}@s.whatsapp.net`;
}

export class WhatsAppMessaging extends UnipileMessagingTool implements IWhatsAppMessaging {
  protected readonly provider = "whatsapp";

  override async resolveRecipient(params: { channelId: string; address: string }): Promise<string | null> {
    await this.assertAccount(params.channelId);
    return phoneToJid(params.address);
  }
}
