// Cloudflare Workers provide Buffer/crypto globally; we use Web Crypto + btoa.
export type TrelloBoard = { id: string; name: string };
export type TrelloList = { id: string; name: string; pos: number };
export type TrelloMember = {
  id: string;
  fullName: string | null;
  username: string | null;
  avatarUrl: string | null;
};
export type TrelloAttachment = {
  id: string;
  name: string;
  url: string;
  bytes: number | null;
  mimeType: string | null;
};
export type TrelloCommentAction = {
  id: string;
  type: "commentCard";
  date: string;
  memberCreator: TrelloMember | null;
  data: { text: string };
};
export type TrelloCheckItem = {
  id: string;
  name: string;
  state: "complete" | "incomplete";
  pos: number;
  idMember: string | null;
};

export type TrelloChecklist = {
  id: string;
  name: string;
  pos: number;
  checkItems: TrelloCheckItem[];
};

export type TrelloCard = {
  id: string;
  name: string;
  desc: string;
  idList: string;
  idBoard: string;
  closed: boolean;
  url: string;
  idMembers: string[];
  members?: TrelloMember[];
  attachments?: TrelloAttachment[];
  actions?: TrelloCommentAction[];
  checklists?: TrelloChecklist[];
  dateLastActivity: string;
};

const BASE = "https://api.trello.com/1";
const CARD_FIELDS = "id,name,desc,idList,idBoard,closed,url,idMembers,dateLastActivity";
const MEMBER_FIELDS = "id,fullName,username,avatarUrl";

export class TrelloApi {
  constructor(
    private readonly key: string,
    private readonly token: string,
  ) {}

  private auth(extra = ""): string {
    const sep = extra ? "&" : "";
    return `key=${encodeURIComponent(this.key)}&token=${encodeURIComponent(this.token)}${sep}${extra}`;
  }

  private async req<T>(method: string, path: string, query = "", body?: string): Promise<T> {
    const url = `${BASE}${path}?${this.auth(body !== undefined ? "" : query)}`;
    const headers: Record<string, string> = { Accept: "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/x-www-form-urlencoded";
    const res = await fetch(url, { method, headers, ...(body !== undefined ? { body } : {}) });
    if (!res.ok) {
      throw new Error(`Trello ${method} ${path} failed: ${res.status} ${await res.text()}`);
    }
    return (await res.json()) as T;
  }

  getBoards(): Promise<TrelloBoard[]> {
    return this.req("GET", "/members/me/boards", "filter=open&fields=id,name");
  }

  getLists(boardId: string): Promise<TrelloList[]> {
    return this.req("GET", `/boards/${boardId}/lists`, "filter=open&fields=id,name,pos");
  }

  getCards(boardId: string, opts: { limit: number; before?: string }): Promise<TrelloCard[]> {
    const q = [
      "filter=open",
      `fields=${CARD_FIELDS}`,
      "members=true",
      `member_fields=${MEMBER_FIELDS}`,
      "attachments=true",
      "attachment_fields=id,name,url,bytes,mimeType",
      "actions=commentCard",
      "actions_limit=50",
      "checklists=all",
      "checklist_fields=name,pos",
      "checkItems=all",
      "checkItem_fields=name,state,pos,idMember",
      `limit=${opts.limit}`,
      ...(opts.before ? [`before=${opts.before}`] : []),
    ].join("&");
    return this.req("GET", `/boards/${boardId}/cards`, q);
  }

  getCard(cardId: string): Promise<TrelloCard> {
    const q = [
      `fields=${CARD_FIELDS}`,
      "members=true",
      `member_fields=${MEMBER_FIELDS}`,
      "attachments=true",
      "attachment_fields=id,name,url,bytes,mimeType",
      "actions=commentCard",
      "actions_limit=50",
      "checklists=all",
      "checklist_fields=name,pos",
      "checkItems=all",
      "checkItem_fields=name,state,pos,idMember",
    ].join("&");
    return this.req("GET", `/cards/${cardId}`, q);
  }

  createCard(p: { idList: string; name: string; desc?: string }): Promise<TrelloCard> {
    const q = [
      `idList=${encodeURIComponent(p.idList)}`,
      `name=${encodeURIComponent(p.name)}`,
      ...(p.desc ? [`desc=${encodeURIComponent(p.desc)}`] : []),
    ].join("&");
    return this.req("POST", "/cards", q);
  }

  updateCard(
    cardId: string,
    fields: { idList?: string; closed?: boolean; name?: string; desc?: string },
  ): Promise<TrelloCard> {
    const parts: string[] = [];
    if (fields.idList !== undefined) parts.push(`idList=${encodeURIComponent(fields.idList)}`);
    if (fields.closed !== undefined) parts.push(`closed=${fields.closed}`);
    if (fields.name !== undefined) parts.push(`name=${encodeURIComponent(fields.name)}`);
    if (fields.desc !== undefined) parts.push(`desc=${encodeURIComponent(fields.desc)}`);
    return this.req("PUT", `/cards/${cardId}`, parts.join("&"));
  }

  addComment(cardId: string, text: string): Promise<TrelloCommentAction> {
    return this.req("POST", `/cards/${cardId}/actions/comments`, `text=${encodeURIComponent(text)}`);
  }

  updateComment(actionId: string, text: string): Promise<{ id: string; data: { text: string } }> {
    return this.req("PUT", `/actions/${actionId}`, `text=${encodeURIComponent(text)}`);
  }

  createWebhook(boardId: string, callbackURL: string): Promise<{ id: string }> {
    const body = `idModel=${encodeURIComponent(boardId)}&callbackURL=${encodeURIComponent(callbackURL)}&description=${encodeURIComponent("Plot Trello sync")}`;
    return this.req("POST", "/webhooks", "", body);
  }

  deleteWebhook(webhookId: string): Promise<unknown> {
    return this.req("DELETE", `/webhooks/${webhookId}`);
  }
}

/** Trello object ids encode their creation time in the first 8 hex chars (unix seconds). */
export function cardCreatedAt(cardId: string): Date {
  const seconds = parseInt(cardId.substring(0, 8), 16);
  return new Date(seconds * 1000);
}

/** Verify a Trello webhook: base64(HMAC-SHA1(appSecret, rawBody + callbackURL)) === header. */
export async function verifyTrelloWebhook(
  secret: string,
  rawBody: string,
  callbackURL: string,
  signature: string,
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-1" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody + callbackURL));
    const expected = btoa(String.fromCharCode(...new Uint8Array(sig)));
    return expected === signature;
  } catch {
    return false;
  }
}
