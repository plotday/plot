import type { ITool, NewContact } from "@plotday/twister";

export interface GoogleContacts extends ITool {
  getContacts(syncableId: string): Promise<NewContact[]>;

  startSync<TCallback extends (contacts: NewContact[], ...args: any[]) => any>(
    syncableId: string,
    callback: TCallback,
    ...extraArgs: any[]
  ): Promise<void>;

  stopSync(syncableId: string): Promise<void>;
}
