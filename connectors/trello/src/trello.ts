import { Connector, type Link, type ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  Integrations,
  type AuthToken,
  type Authorization,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { TrelloApi, verifyTrelloWebhook } from "./trello-api";
import { buildCardLinkType } from "./trello-channels";
import { transformCard } from "./trello-sync";

const CARDS_PER_PAGE = 100;
type TrelloSyncState = { before: string | null; batchNumber: number; initialSync: boolean };

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

  /**
   * Resolve Trello credentials for a given channel. If a token is provided
   * (e.g. passed by the runtime to getChannels), it is used directly.
   * Otherwise the token is fetched from integrations by channelId.
   */
  private async getApi(channelId: string, token?: AuthToken | null): Promise<TrelloApi> {
    const tok = token ?? (await this.tools.integrations.get(channelId));
    const key = tok?.provider?.["key"];
    if (!tok?.token || !key) {
      throw new Error(`No Trello credentials for channel ${channelId}`);
    }
    return new TrelloApi(key, tok.token);
  }

  /**
   * Returns one Channel per Trello board, each with per-board dynamic
   * statuses derived from the board's lists.
   *
   * Matches Linear's getChannels pattern: the runtime passes the account
   * token as the second argument; getApi falls back to integrations.get for
   * per-board calls in later tasks.
   */
  async getChannels(_auth?: Authorization | null, token?: AuthToken | null): Promise<Channel[]> {
    const api = await this.getApi("", token ?? undefined);
    const boards = await api.getBoards();
    return Promise.all(
      boards.map(async (board) => {
        const lists = await api.getLists(board.id);
        return {
          id: board.id,
          title: board.name,
          linkTypes: [buildCardLinkType(lists)],
        };
      }),
    );
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue webhook setup as a separate task (never inline — blocks the HTTP response).
    const webhookCb = await this.callback(this.setupWebhook, channel.id);
    await this.runTask(webhookCb);

    if (!context?.observeOnly) {
      await this.startBatchSync(channel.id);
    }
  }

  async onChannelDisabled(): Promise<void> {}

  async setupWebhook(boardId: string): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook({}, this.onWebhook, boardId);
      if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) return; // dev guard
      const api = await this.getApi(boardId);
      const webhook = await api.createWebhook(boardId, webhookUrl);
      if (webhook?.id) {
        await this.set(`webhook_id_${boardId}`, webhook.id);
        await this.set(`webhook_url_${boardId}`, webhookUrl);
      }
    } catch (error) {
      console.error("Failed to set up Trello webhook — real-time updates will not work:", error);
    }
  }

  private async onWebhook(request: WebhookRequest, boardId: string): Promise<void> {
    // Trello sends a HEAD to verify the callback URL on creation; nothing to do.
    if (request.method === "HEAD") return;
    if (!request.rawBody) return;

    const signature = request.headers["x-trello-webhook"];
    const callbackUrl = await this.get<string>(`webhook_url_${boardId}`);
    const token = await this.tools.integrations.get(boardId);
    const secret = token?.provider?.secret;
    if (!signature || !callbackUrl || !secret) return;

    const valid = await verifyTrelloWebhook(secret, request.rawBody, callbackUrl, signature);
    if (!valid) {
      console.warn("Trello webhook signature verification failed");
      return;
    }

    const action = (request.body as { action?: { data?: { card?: { id?: string } } } })?.action;
    const cardId = action?.data?.card?.id;
    if (!cardId) return;

    // Re-fetch the card for fresh, complete data (webhook payloads are partial).
    const api = await this.getApi(boardId);
    const card = await api.getCard(cardId);
    await this.tools.integrations.saveLink(transformCard(card, boardId, false));
  }

  private async startBatchSync(boardId: string): Promise<void> {
    await this.set(`sync_state_${boardId}`, {
      before: null,
      batchNumber: 1,
      initialSync: true,
    } as TrelloSyncState);
    const cb = await this.callback(this.syncBatch, boardId);
    await this.runTask(cb);
  }

  async onLinkUpdated(link: Link): Promise<void> {
    const cardId = link.meta?.cardId as string | undefined;
    const boardId = link.meta?.boardId as string | undefined;
    if (!cardId || !boardId) return;
    // Note: archive write-back is intentionally not supported yet. The Link read
    // type has no `archived` field; supporting it would require a runtime
    // `fromDbLink` change to surface it here.
    const fields: { idList?: string; name?: string } = {};
    if (link.status) fields.idList = link.status; // status === Trello list id
    if (link.title) fields.name = link.title;
    if (Object.keys(fields).length === 0) return;
    try {
      const api = await this.getApi(boardId);
      await api.updateCard(cardId, fields);
    } catch (error) {
      console.error("[trello] onLinkUpdated write-back failed:", error);
    }
  }

  private async syncBatch(boardId: string): Promise<void> {
    const state = await this.get<TrelloSyncState>(`sync_state_${boardId}`);
    if (!state) throw new Error(`Trello sync state not found for board ${boardId}`);

    const api = await this.getApi(boardId);
    const cards = await api.getCards(boardId, {
      limit: CARDS_PER_PAGE,
      before: state.before ?? undefined,
    });

    for (const card of cards) {
      await this.tools.integrations.saveLink(transformCard(card, boardId, state.initialSync));
    }

    if (cards.length === CARDS_PER_PAGE) {
      // Full page → more cards remain; paginate before the last (oldest) card id.
      await this.set(`sync_state_${boardId}`, {
        before: cards[cards.length - 1].id,
        batchNumber: state.batchNumber + 1,
        initialSync: state.initialSync,
      } as TrelloSyncState);
      const cb = await this.callback(this.syncBatch, boardId);
      await this.runTask(cb);
    } else {
      if (state.initialSync) await this.tools.integrations.channelSyncCompleted(boardId);
      await this.clear(`sync_state_${boardId}`);
    }
  }
}

export default Trello;
