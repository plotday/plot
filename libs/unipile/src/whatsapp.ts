import { UnipileMessaging } from "./messaging";

/** WhatsApp messaging tool. Common surface only; resolveRecipient maps a phone
 * number to a WhatsApp JID. Impl: workers/api/.../unipile/whatsapp.ts. */
export abstract class WhatsAppMessaging extends UnipileMessaging {
  static readonly toolId = "WhatsAppMessaging";
}
