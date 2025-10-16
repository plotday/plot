import {
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  Agent,
  type Priority,
  type Tools,
} from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";
import { Store } from "@plotday/sdk/tools/store";
import GoogleContactsTool from "@plotday/tool-google-contacts";
import type {
  Contact,
  ContactAuth,
  GoogleContacts,
} from "@plotday/tool-google-contacts";

type ContactProvider = "google";

type StoredContactAuth = {
  provider: ContactProvider;
  authToken: string;
};

type ContactSelectionContext = {
  provider: ContactProvider;
  authToken: string;
};

export default class ContactsAgent extends Agent<ContactsAgent> {
  private googleContacts: GoogleContacts;
  private plot: Plot;
  private store: Store;

  constructor(tools: Tools) {
    super(tools);
    this.googleContacts = tools.get(GoogleContactsTool);
    this.plot = tools.get(Plot);
    this.store = tools.get(Store);
  }

  private getProviderTool(provider: ContactProvider): GoogleContacts {
    switch (provider) {
      case "google":
        return this.googleContacts;
      default:
        throw new Error(`Unknown contact provider: ${provider}`);
    }
  }

  private async getStoredAuths(): Promise<StoredContactAuth[]> {
    const stored = await this.store.get<StoredContactAuth[]>("contact_auths");
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

    await this.store.set("contact_auths", auths);
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
    const googleAuthLink = await this.googleContacts.requestAuth(
      "onAuthComplete",
      { provider: "google" }
    );

    // Create activity with auth link
    await this.plot.createActivity({
      type: ActivityType.Task,
      title: "Connect your contacts",
      start: new Date(),
      end: null,
      links: [googleAuthLink],
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
    await tool.startSync(authToken, "handleContacts", {
      context: { provider },
    });
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
    await this.plot.addContacts(contacts);
  }

  async onAuthComplete(authResult: ContactAuth, context?: any): Promise<void> {
    const provider = context?.provider as ContactProvider;
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
    const token = await this.callback("onSyncSelected", {
      provider,
      authToken,
    });

    const link: ActivityLink = {
      title: `🔄 Start syncing ${provider} contacts`,
      type: ActivityLinkType.callback,
      token: token,
    };

    // Create the sync confirmation activity
    await this.plot.createActivity({
      type: ActivityType.Task,
      title: `Would you like to sync your ${provider} contacts?`,
      start: new Date(),
      end: null,
      links: [link],
    });
  }

  async onSyncSelected(
    link: ActivityLink,
    context?: ContactSelectionContext
  ): Promise<void> {
    console.log("Sync selected:", link.title);

    if (!context) {
      console.error("No context found in sync selection callback");
      return;
    }

    try {
      // Start sync for the contacts
      const tool = this.getProviderTool(context.provider);
      await tool.startSync(context.authToken, "handleContacts", {
        context: {
          provider: context.provider,
        },
      });

      console.log(`Started syncing ${context.provider} contacts`);

      // Optionally create a confirmation activity
      await this.plot.createActivity({
        type: ActivityType.Task,
        title: `✅ Started syncing ${context.provider} contacts`,
        note: `Contact sync has been started for your ${context.provider} contacts.`,
        start: new Date(),
        end: null,
      });
    } catch (error) {
      console.error(
        `Failed to start sync for ${context.provider} contacts:`,
        error
      );
    }
  }
}
