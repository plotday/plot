import type { NewContact } from "@plotday/twister";

export interface GoogleContacts {
  getContacts(channelId: string): Promise<NewContact[]>;

  startSync(channelId: string): Promise<void>;

  stopSync(channelId: string): Promise<void>;
}
