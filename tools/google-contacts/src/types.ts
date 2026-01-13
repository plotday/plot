import type { ActivityLink, ITool, NewContact } from "@plotday/twister";

export type ContactAuth = {
  authToken: string;
};

export interface GoogleContacts extends ITool {
  requestAuth<TCallback extends (auth: ContactAuth, ...args: any[]) => any>(
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<ActivityLink>;

  getContacts(authToken: string): Promise<NewContact[]>;

  startSync<TCallback extends (contacts: NewContact[], ...args: any[]) => any>(
    authToken: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void>;

  stopSync(authToken: string): Promise<void>;
}
