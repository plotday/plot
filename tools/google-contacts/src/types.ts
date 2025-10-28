import type { ActivityLink, ITool } from "@plotday/agent";

export type Contact = {
  email: string;
  name?: string;
  avatar?: string;
};

export type ContactAuth = {
  authToken: string;
};

export interface GoogleContacts extends ITool {
  requestAuth<TCallback extends (auth: ContactAuth, ...args: any[]) => any>(
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<ActivityLink>;

  getContacts(authToken: string): Promise<Contact[]>;

  startSync<TCallback extends (contacts: Contact[], ...args: any[]) => any>(
    authToken: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void>;

  stopSync(authToken: string): Promise<void>;
}
