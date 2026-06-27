import { Connector, type CreateLinkDraft, type Link, type NewLinkWithNotes, type Note, type NoteWriteBackResult, type Thread, type ToolBuilder } from "@plotday/twister";
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
import { TrelloApi, cardCreatedAt, verifyTrelloWebhook, type TrelloCard } from "./trello-api";
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

  async onChannelDisabled(channel: Channel): Promise<void> {
    const boardId = channel.id;
    const webhookId = await this.get<string>(`webhook_id_${boardId}`);
    if (webhookId) {
      try {
        const api = await this.getApi(boardId);
        await api.deleteWebhook(webhookId);
      } catch (error) {
        console.warn("Failed to delete Trello webhook:", error);
      }
    }
    await this.clear(`webhook_id_${boardId}`);
    await this.clear(`webhook_url_${boardId}`);
    await this.clear(`sync_state_${boardId}`);
    await this.clear(`sync_enabled_${boardId}`);
    await this.tools.integrations.archiveLinks({ channelId: boardId });
  }

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

  async onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "card") return null;
    const boardId = draft.channelId;
    const api = await this.getApi(boardId);
    const card = await api.createCard({
      idList: draft.status ?? "",
      name: draft.title,
      ...(draft.noteContent ? { desc: draft.noteContent } : {}),
    });
    if (!card?.id) return null;
    return {
      source: `trello:card:${card.id}`,
      type: "card",
      title: card.name,
      status: card.idList,
      created: cardCreatedAt(card.id),
      channelId: boardId,
      sourceUrl: card.url,
      meta: { syncProvider: "trello", boardId, cardId: card.id, idList: card.idList },
      // Use || not ?? so empty-string desc ("") yields undefined, matching transformCard's null for empty desc.
      originatingNote: { key: "description", externalContent: card.desc || undefined },
    };
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

  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const cardId = thread.meta?.cardId as string | undefined;
    const boardId = thread.meta?.boardId as string | undefined;
    if (!cardId || !boardId) return;
    const api = await this.getApi(boardId);
    const action = await api.addComment(cardId, note.content ?? "");
    if (!action?.id) return;
    return { key: `comment-${action.id}`, externalContent: action.data.text };
  }

  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    if (!note.key) return;
    const cardId = thread.meta?.cardId as string | undefined;
    const boardId = thread.meta?.boardId as string | undefined;
    if (!cardId || !boardId) return;
    const api = await this.getApi(boardId);
    if (note.key === "description") {
      const card = await api.updateCard(cardId, { desc: note.content ?? "" });
      return { externalContent: card.desc ?? note.content ?? "" };
    }
    const m = note.key.match(/^comment-(.+)$/);
    if (!m) return;
    const updated = await api.updateComment(m[1], note.content ?? "");
    return { externalContent: updated.data.text };
  }

  /** The connection owner's Trello member id, cached for Done-attribution on unassigned-complete items. */
  private async getOwnerMemberId(boardId: string): Promise<string | undefined> {
    const cached = await this.get<string>("me_member_id");
    if (cached) return cached;
    try {
      const api = await this.getApi(boardId);
      const me = await api.me();
      if (me?.id) {
        await this.set("me_member_id", me.id);
        return me.id;
      }
    } catch (error) {
      console.warn("Failed to fetch Trello member id for owner attribution:", error);
    }
    return undefined;
  }

  /** Persist the card's checklist→checkItem-id map so checklist removal can archive the right notes. */
  private async recordChecklistItems(cardId: string, card: TrelloCard): Promise<void> {
    const map: Record<string, string[]> = {};
    for (const cl of card.checklists ?? []) {
      map[cl.id] = cl.checkItems.map((i) => i.id);
    }
    await this.set(`checklist_items_${cardId}`, map);
  }

  private async syncBatch(boardId: string): Promise<void> {
    const state = await this.get<TrelloSyncState>(`sync_state_${boardId}`);
    if (!state) throw new Error(`Trello sync state not found for board ${boardId}`);

    const api = await this.getApi(boardId);
    const cards = await api.getCards(boardId, {
      limit: CARDS_PER_PAGE,
      before: state.before ?? undefined,
    });

    const ownerMemberId = await this.getOwnerMemberId(boardId);
    for (const card of cards) {
      await this.tools.integrations.saveLink(transformCard(card, boardId, state.initialSync, ownerMemberId));
      await this.recordChecklistItems(card.id, card);
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
