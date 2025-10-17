import type { ActivityLink, Tool } from "@plotday/sdk";

export type Contact = {
  email: string;
  name?: string;
  avatar?: string;
};

export type ContactAuth = {
  authToken: string;
};

export interface GoogleContacts extends Tool {
  requestAuth(
    callbackFunctionName: string,
    callbackContext?: any
  ): Promise<ActivityLink>;

  getContacts(authToken: string): Promise<Contact[]>;

  startSync(
    authToken: string,
    callbackFunctionName: string,
    options?: {
      context?: any;
    }
  ): Promise<void>;

  stopSync(authToken: string): Promise<void>;
}

