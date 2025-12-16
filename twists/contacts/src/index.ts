import GoogleContactsTool from "@plotday/tool-google-contacts";
import type {
  Contact,
  ContactAuth,
  GoogleContacts,
} from "@plotday/tool-google-contacts";
import {
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

type ContactProvider = "google";

type StoredContactAuth = {
  provider: ContactProvider;
  authToken: string;
};

export default class ContactsTwist extends Twist<ContactsTwist> {
  build(build: ToolBuilder) {
    return {
      googleContacts: build(GoogleContactsTool),
      plot: build(Plot),
    };
  }

  private getProviderTool(provider: ContactProvider): GoogleContacts {
    switch (provider) {
      case "google":
        return this.tools.googleContacts;
      default:
        throw new Error(`Unknown contact provider: ${provider}`);
    }
  }

  private async getStoredAuths(): Promise<StoredContactAuth[]> {
    const stored = await this.tools.store.get<StoredContactAuth[]>(
      "contact_auths"
    );
    return stored || [];
  }

  private async addStoredAuth(
    provider: ContactProvider,
    authToken: string
  ): Promise<void> {
    const auths = await this.getStoredAuths();
    const existingIndex = auths.findIndex((auth) => auth.provider === provider);

    if (existingIndex >= 0) {
      auths[existingIndex].authToken = authToken;
    } else {
      auths.push({ provider, authToken });
    }

    await this.tools.store.set("contact_auths", auths);
  }

  private async getAuthToken(
    provider: ContactProvider
  ): Promise<string | null> {
    const auths = await this.getStoredAuths();
    const auth = auths.find((auth) => auth.provider === provider);
    return auth?.authToken || null;
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Get auth links from contacts tools
    const googleAuthLink = await this.tools.googleContacts.requestAuth(
      this.onAuthComplete,
      "google"
    );

    // Create activity with auth link
    await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect your contacts",
      start: new Date(),
      end: null,
      notes: [
        {
          links: [googleAuthLink],
        },
      ],
    });
  }

  async getContacts(provider: ContactProvider): Promise<Contact[]> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Contacts not authenticated`);
    }

    const tool = this.getProviderTool(provider);
    return await tool.getContacts(authToken);
  }

  async startSync(provider: ContactProvider): Promise<void> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Contacts not authenticated`);
    }

    const tool = this.getProviderTool(provider);
    await tool.startSync(authToken, this.handleContacts, provider);
  }

  async stopSync(provider: ContactProvider): Promise<void> {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`${provider} Contacts not authenticated`);
    }

    const tool = this.getProviderTool(provider);
    await tool.stopSync(authToken);
  }

  async getAllContacts(): Promise<
    { provider: ContactProvider; contacts: Contact[] }[]
  > {
    const results = [];
    const auths = await this.getStoredAuths();

    for (const auth of auths) {
      try {
        const contacts = await this.getContacts(auth.provider);
        results.push({ provider: auth.provider, contacts });
      } catch (error) {
        console.warn(`Failed to get ${auth.provider} contacts:`, error);
      }
    }

    return results;
  }

  async handleContacts(contacts: Contact[], context?: any): Promise<void> {
    console.log("Received contacts:", {
      count: contacts.length,
      provider: context?.provider,
    });

    // Process the contacts through the plot tool
    await this.tools.plot.addContacts(contacts);
  }

  async onAuthComplete(
    authResult: ContactAuth,
    provider: ContactProvider
  ): Promise<void> {
    if (!provider) {
      console.error("No provider specified in auth context");
      return;
    }

    // Store the auth token for later use
    await this.addStoredAuth(provider, authResult.authToken);
    console.log(`${provider} Contacts authentication completed`);

    try {
      // Create sync confirmation activity
      await this.createSyncConfirmationActivity(provider, authResult.authToken);
    } catch (error) {
      console.error(
        `Failed to create sync confirmation for ${provider}:`,
        error
      );
    }
  }

  private async createSyncConfirmationActivity(
    provider: ContactProvider,
    authToken: string
  ): Promise<void> {
    // Create callback link for sync using the cleaner API
    const token = await this.callback(this.onSyncSelected, provider, authToken);

    const link: ActivityLink = {
      title: `🔄 Start syncing ${provider} contacts`,
      type: ActivityLinkType.callback,
      callback: token,
    };

    // Create the sync confirmation activity
    await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: `Would you like to sync your ${provider} contacts?`,
      start: new Date(),
      end: null,
      notes: [
        {
          links: [link],
        },
      ],
    });
  }

  async onSyncSelected(
    link: ActivityLink,
    provider: ContactProvider,
    authToken: string
  ): Promise<void> {
    console.log("Sync selected:", "title" in link ? link.title : link.type);

    try {
      // Start sync for the contacts
      const tool = this.getProviderTool(provider);
      await tool.startSync(authToken, this.handleContacts, provider);

      console.log(`Started syncing ${provider} contacts`);

      // Optionally create a confirmation activity
      await this.tools.plot.createActivity({
        type: ActivityType.Action,
        title: `✅ Started syncing ${provider} contacts`,
        notes: [
          {
            content: `Contact sync has been started for your ${provider} contacts.`,
          },
        ],
        start: new Date(),
        end: null,
      });
    } catch (error) {
      console.error(`Failed to start sync for ${provider} contacts:`, error);
    }
  }
}
