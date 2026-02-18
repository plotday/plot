import GoogleContactsTool from "@plotday/tool-google-contacts";
import {
  type NewContact,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class ContactsTwist extends Twist<ContactsTwist> {
  build(build: ToolBuilder) {
    return {
      googleContacts: build(GoogleContactsTool, {
        onItem: this.handleContacts,
      }),
      plot: build(Plot),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth is now handled in the twist edit modal.
    // Contact sync starts automatically via the tool's onSyncEnabled lifecycle.
  }

  async handleContacts(contacts: NewContact[], context?: any): Promise<void> {
    console.log("Received contacts:", {
      count: contacts.length,
      provider: context?.provider,
    });

    // Process the contacts through the plot tool
    await this.tools.plot.addContacts(contacts);
  }
}
