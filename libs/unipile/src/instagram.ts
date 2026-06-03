import { UnipileMessaging } from "./messaging";

export abstract class InstagramMessaging extends UnipileMessaging {
  static readonly toolId = "InstagramMessaging";

  /** Accept or ignore an Instagram message request (pending DM). */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setMessageRequestAccepted(params: { channelId: string; chatId: string; accepted: boolean }): Promise<void>;
}
