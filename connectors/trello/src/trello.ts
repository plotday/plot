import { Connector, type ToolBuilder } from "@plotday/twister";
import { AuthProvider, Integrations, type StatusIcon } from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

export class Trello extends Connector<Trello> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Trello;
  readonly scopes = ["read", "write"];
  readonly dynamicLinkTypes = true; // per-board statuses are attached in getChannels
  readonly access = [
    "Reads your boards, cards, comments, and attachments",
    "Creates and updates cards and posts comments you make in Plot",
    "Keeps Plot up to date as cards change in Trello",
  ];
  readonly linkTypes = [
    {
      type: "card",
      label: "Card",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      composePlaceholder: "Create a Trello card",
      composeVerb: "Create",
      replyPlaceholder: "Add a comment",
      replyVerb: "Comment",
      logo: "https://api.iconify.design/logos/trello.svg",
      supportsAssignee: false,
      // statuses + compose are attached per-board in getChannels()
      statuses: [
        { status: "todo", label: "To Do", icon: "todo" as StatusIcon },
        { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
      ],
      compose: { status: "todo" },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.trello.com/*"] }),
    };
  }

  // Lifecycle + sync + write-back methods are added in later tasks.
  async getChannels(): Promise<import("@plotday/twister/tools/integrations").Channel[]> {
    return [];
  }
  async onChannelEnabled(): Promise<void> {}
  async onChannelDisabled(): Promise<void> {}
}

export default Trello;
