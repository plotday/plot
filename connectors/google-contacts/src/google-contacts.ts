import {
  type NewContact,
  Connector,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

import {
  type ContactSyncState,
  GOOGLE_PEOPLE_SCOPES,
  GoogleApi,
  getGoogleContacts,
} from "./people-api";

export default class GoogleContacts
  extends Connector<GoogleContacts>
{
  static readonly id = "google-contacts";

  static readonly PROVIDER = AuthProvider.Google;

  static readonly SCOPES = GOOGLE_PEOPLE_SCOPES;

  readonly provider = AuthProvider.Google;
  readonly scopes = GoogleContacts.SCOPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://people.googleapis.com/*"],
      }),
    };
  }

  async getChannels(_auth: Authorization, _token: AuthToken): Promise<Channel[]> {
    return [{ id: "contacts", title: "Contacts" }];
  }

  async onChannelEnabled(channel: Channel): Promise<void> {
    const token = await this.tools.integrations.get(channel.id);
    if (!token) {
      throw new Error("No Google authentication token available");
    }

    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${channel.id}`, initialState);

    const syncCallback = await this.callback(this.syncBatch, 1, channel.id);
    await this.runTask(syncCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
  }

  async getContacts(syncableId: string): Promise<NewContact[]> {
    const token = await this.tools.integrations.get(syncableId);
    if (!token) {
      throw new Error(
        "No Google authentication token available for the provided syncableId"
      );
    }

    const api = new GoogleApi(token.token);
    const result = await getGoogleContacts(api, token.scopes, {
      more: false,
    });

    return result.contacts;
  }

  async startSync(syncableId: string): Promise<void> {
    const token = await this.tools.integrations.get(syncableId);
    if (!token) {
      throw new Error(
        "No Google authentication token available for the provided syncableId"
      );
    }

    const initialState: ContactSyncState = {
      more: false,
    };

    await this.set(`sync_state:${syncableId}`, initialState);

    const syncCallback = await this.callback(this.syncBatch, 1, syncableId);
    await this.runTask(syncCallback);
  }

  async stopSync(syncableId: string): Promise<void> {
    await this.clear(`sync_state:${syncableId}`);
  }

  async syncBatch(batchNumber: number, syncableId: string): Promise<void> {
    try {
      const token = await this.tools.integrations.get(syncableId);
      if (!token) {
        throw new Error(
          "No authentication token available for the provided syncableId"
        );
      }

      const state = await this.get<ContactSyncState>(`sync_state:${syncableId}`);
      if (!state) {
        throw new Error("No sync state found");
      }

      const api = new GoogleApi(token.token);
      const result = await getGoogleContacts(
        api,
        token.scopes,
        state
      );

      if (result.contacts.length > 0) {
        await this.processContacts(result.contacts);
      }

      await this.set(`sync_state:${syncableId}`, result.state);

      if (result.state.more) {
        const nextCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          syncableId
        );
        await this.runTask(nextCallback);
      } else {
        await this.clear(`sync_state:${syncableId}`);
      }
    } catch (error) {
      console.error(`Error in sync batch ${batchNumber}:`, error);

      throw error;
    }
  }

  private async processContacts(
    contacts: NewContact[],
  ): Promise<void> {
    await this.tools.integrations.saveContacts(contacts);
  }
}
