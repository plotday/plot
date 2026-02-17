import type { ITool, NewContact } from "@plotday/twister";

export type GoogleContactsOptions = {
  /** Callback invoked for each batch of synced contacts. */
  onItem: (contacts: NewContact[]) => Promise<void>;
};

export interface GoogleContacts extends ITool {
  getContacts(syncableId: string): Promise<NewContact[]>;

  startSync<TCallback extends (contacts: NewContact[], ...args: any[]) => any>(
    syncableId: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void>;

  stopSync(syncableId: string): Promise<void>;
}
