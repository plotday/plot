import { ActionType } from "@plotday/twister/plot";
import type {
  Action,
  NewActor,
  NewContact,
  NewNote,
  NewReactions,
} from "@plotday/twister/plot";
import type { NewLinkWithNotes } from "@plotday/twister";

import type {
  ChatAttachment,
  ChatMessage,
  ChatProfile,
  ChatThread,
  UnipileMessaging,
} from "./messaging";

/**
 * Build a Plot contact from a provider profile.
 *
 * Identity is the provider-side id (`source.accountId` = `profile.id`), which
 * `addContacts` persists as a `contact_external_account` row scoped to the
 * connection. A real `profile.email` (rare on LinkedIn, more common on other
 * providers) is set so the contact can merge across connectors; when absent we
 * leave `email` unset and let the source-only path key the contact on the
 * stable provider id.
 *
 * We deliberately do NOT manufacture a `<handle|phone>@<provider>.invalid`
 * placeholder: a synthetic email gets stored as the contact's real email
 * (surfacing in share/mention pickers), forces the contact down the global
 * email-dedup path, blocks cross-connector merge with the same person's real
 * email, and re-keys identity onto the mutable handle (e.g. a LinkedIn vanity
 * URL) instead of the stable provider id — spawning duplicate contacts when it
 * changes.
 */
export function profileToContact(profile: ChatProfile): NewContact {
  const source = { accountId: profile.id };
  const avatar = profile.pictureUrl ?? undefined;
  if (profile.email) return { email: profile.email, name: profile.name, avatar, source };
  return { name: profile.name, avatar, source };
}

export function senderFallbackContact(msg: ChatMessage, provider: string): NewContact {
  return { name: msg.sentByMe ? "You" : `${titleCase(provider)} user`, source: { accountId: msg.senderId } };
}

function titleCase(s: string): string {
  return s.length ? s[0]!.toUpperCase() + s.slice(1) : s;
}

export function joinParticipantNames(profiles: ChatProfile[]): string {
  if (profiles.length === 0) return "Group";
  if (profiles.length === 1) return profiles[0]!.name;
  if (profiles.length === 2) return `${profiles[0]!.name}, ${profiles[1]!.name}`;
  return `${profiles[0]!.name}, ${profiles[1]!.name} +${profiles.length - 2}`;
}

/**
 * Pick the single emoji to push as the connected account's reaction, given
 * Plot's emoji→reactors map. With `allowed` (fixed-set platforms like
 * LinkedIn) iterate that order; otherwise (open-unicode) iterate the reaction
 * keys in sorted order for determinism. Returns null to signal "clear".
 *
 * Accepts any emoji→reactors map: the connectors pass `note.reactions`
 * (`Reactions` = branded `ActorId[]`), while tests/builders pass
 * `NewReactions` (`NewActor[]`). The function only inspects array length, so
 * the param is widened to `Record<string, readonly unknown[]>` to accept both.
 */
export function pickDesiredReaction(
  reactions: Record<string, readonly unknown[]>,
  allowed?: readonly string[]
): string | null {
  const order = allowed ?? Object.keys(reactions).sort();
  for (const emoji of order) {
    const reactors = reactions[emoji];
    if (reactors && reactors.length > 0) return emoji;
  }
  return null;
}

/**
 * The single outbound action for a one-reaction-per-user platform (LinkedIn,
 * Instagram, WhatsApp via Unipile — each member holds at most one reaction per
 * message). `lastSent` is the emoji this connector last pushed for THIS user on
 * THIS message (tracked in per-user connector state); `(emoji, added)` is the
 * incoming transition from `onNoteReactionChanged`. `allowed` (fixed-set
 * platforms like LinkedIn) filters emoji the platform can't represent.
 *
 * Limitation: because the reaction dispatch does not carry the full
 * `note.reactions` map, a single user who stacks multiple emoji on one message
 * is reconciled to last-write-wins; removing the last-pushed emoji clears the
 * user's platform reaction even if another Plot emoji of theirs remains. Plot
 * retains all reactions; the external platform is inherently one-per-user.
 */
export type ReactionWriteback =
  | { action: "set"; emoji: string }
  | { action: "clear" }
  | { action: "none" };

export function reconcilePerUserReaction(
  lastSent: string | null,
  emoji: string,
  added: boolean,
  allowed?: readonly string[]
): ReactionWriteback {
  if (added) {
    if (allowed && !allowed.includes(emoji)) return { action: "none" };
    if (lastSent === emoji) return { action: "none" };
    return { action: "set", emoji };
  }
  if (lastSent === emoji) return { action: "clear" };
  return { action: "none" };
}

export function buildReactionsFromMessage(
  msg: ChatMessage,
  chat: ChatThread,
  provider: string
): NewReactions | undefined {
  if (!msg.reactions || msg.reactions.length === 0) return undefined;
  const byEmoji = new Map<string, NewActor[]>();
  for (const r of msg.reactions) {
    const participant = chat.participants.find((p) => p.id === r.senderId);
    const actor: NewActor = participant
      ? profileToContact(participant)
      : { name: `${titleCase(provider)} user`, source: { accountId: r.senderId } };
    const existing = byEmoji.get(r.value);
    if (existing) existing.push(actor);
    else byEmoji.set(r.value, [actor]);
  }
  const out: NewReactions = {};
  for (const [emoji, actors] of byEmoji) out[emoji] = actors;
  return out;
}

export function buildNoteFromMessage(
  msg: ChatMessage,
  chat: ChatThread,
  provider: string,
  threadPersonId?: string
): NewNote {
  const sender = chat.participants.find((p) => p.id === msg.senderId) ?? null;
  const author = sender ? profileToContact(sender) : senderFallbackContact(msg, provider);
  const actions: Action[] = msg.attachments.map((a: ChatAttachment) => ({
    type: ActionType.fileRef as typeof ActionType.fileRef,
    ref: `${msg.id}:${a.id}`,
    fileName: a.name ?? "attachment",
    fileSize: a.byteSize ?? null,
    mimeType: a.contentType ?? "application/octet-stream",
  }));
  const threadSource = threadPersonId ? `${provider}:person:${threadPersonId}` : `${provider}:chat:${chat.id}`;
  const reactions = buildReactionsFromMessage(msg, chat, provider);
  return {
    thread: { source: threadSource },
    key: `message-${msg.id}`,
    created: msg.sentAt,
    content: msg.text,
    contentType: "text",
    author,
    ...(reactions ? { reactions } : {}),
    ...(actions.length > 0 ? { actions } : {}),
  };
}

/** Assemble a 1:1 conversation link (person-keyed) from already-fetched messages. */
export function assembleConversationLink(opts: {
  provider: string;
  channelId: string;
  chat: ChatThread;
  messages: ChatMessage[];
  initialSync: boolean;
  status?: string; // defaults to "inbox" on initial sync
}): NewLinkWithNotes | null {
  const { provider, channelId, chat, messages, initialSync } = opts;
  const other = chat.participants.find((p) => !p.isSelf);
  if (!other) return null;
  const items = messages.filter((m) => m.eventType === null);
  const notes: NewNote[] = items.slice().reverse().map((m) => buildNoteFromMessage(m, chat, provider, other.id));
  const status = opts.status ?? "inbox";
  return {
    source: `${provider}:person:${other.id}`,
    sources: [`${provider}:person:${other.id}`, `${provider}:chat:${chat.id}`],
    type: "conversation",
    ...(initialSync ? { status } : {}),
    title: other.name,
    preview: chat.lastMessagePreview ?? null,
    sourceUrl: chat.url,
    created: chat.lastActivityAt,
    accessContacts: [profileToContact(other)],
    notes,
    meta: { syncProvider: provider, channelId, profileId: other.id, chatId: chat.id },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}

/**
 * Assemble a group/named-group link (chat-keyed) from already-fetched messages.
 *
 * `type` defaults to `"group"` (WhatsApp/Instagram named groups), but LinkedIn
 * has no named-group entity — a multi-person chat is still a `"conversation"` —
 * so LinkedIn passes `type: "conversation"` to keep its single composable type.
 */
export function assembleGroupLink(opts: {
  provider: string;
  channelId: string;
  chat: ChatThread;
  messages: ChatMessage[];
  initialSync: boolean;
  type?: string;
}): NewLinkWithNotes {
  const { provider, channelId, chat, messages, initialSync } = opts;
  const items = messages.filter((m) => m.eventType === null);
  const others = chat.participants.filter((p) => !p.isSelf);
  const notes: NewNote[] = items.slice().reverse().map((m) => buildNoteFromMessage(m, chat, provider));
  return {
    source: `${provider}:chat:${chat.id}`,
    sources: [`${provider}:chat:${chat.id}`],
    type: opts.type ?? "group",
    ...(initialSync ? { status: "inbox" } : {}),
    title: chat.title ?? joinParticipantNames(others),
    preview: chat.lastMessagePreview ?? null,
    sourceUrl: chat.url,
    created: chat.lastActivityAt,
    accessContacts: others.map((p) => profileToContact(p)),
    notes,
    meta: { syncProvider: provider, channelId, chatId: chat.id },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}

/**
 * Fetch a chat's recent messages via the tool and assemble its link. Used by
 * both backfill and the new-message webhook. `onAttachmentMessage` is called
 * for each message that has attachments so the connector can cache
 * message→channel for downloadAttachment.
 */
export async function buildLinkForChat(opts: {
  tool: UnipileMessaging;
  provider: string;
  channelId: string;
  chat: ChatThread;
  initialSync: boolean;
  since?: Date;
  msgLimit?: number;
  /** Link type for multi-person/group chats; defaults to `"group"`. LinkedIn passes `"conversation"`. */
  groupType?: string;
  /**
   * 1:1 conversation status override (e.g. Instagram message requests →
   * `"pending"`). Forwarded to `assembleConversationLink`, which only applies
   * a status on initial sync, so passing it on the webhook path is a no-op.
   */
  conversationStatus?: string;
  onAttachmentMessage?: (messageId: string) => Promise<void>;
}): Promise<NewLinkWithNotes | null> {
  const { tool, provider, channelId, chat, initialSync, since } = opts;
  const page = await tool.listMessages({
    channelId,
    chatId: chat.id,
    limit: opts.msgLimit ?? 20,
    since: initialSync ? undefined : since,
  });
  // The assemblers filter out synthetic events themselves; pass raw messages
  // and only filter here for the attachment-cache loop.
  if (opts.onAttachmentMessage) {
    for (const m of page.messages) {
      if (m.eventType === null && m.attachments.length > 0) await opts.onAttachmentMessage(m.id);
    }
  }
  return chat.isGroup
    ? assembleGroupLink({ provider, channelId, chat, messages: page.messages, initialSync, type: opts.groupType })
    : assembleConversationLink({ provider, channelId, chat, messages: page.messages, initialSync, status: opts.conversationStatus });
}

/**
 * One-time backfill: page through chats and assemble links. Returns the links;
 * the connector saves them via integrations.saveLinks and tracks the
 * high-water timestamp. No recurring scheduling — webhooks drive steady state.
 */
export async function backfillChats(opts: {
  tool: UnipileMessaging;
  provider: string;
  channelId: string;
  listLimit?: number;
  msgLimit?: number;
  /** Link type for multi-person/group chats; defaults to `"group"`. LinkedIn passes `"conversation"`. */
  groupType?: string;
  onAttachmentMessage?: (messageId: string) => Promise<void>;
}): Promise<{ links: NewLinkWithNotes[]; lastActivityMs: number }> {
  const { tool, provider, channelId } = opts;
  const result = await tool.listChats({ channelId, limit: opts.listLimit ?? 20 });
  const links: NewLinkWithNotes[] = [];
  let lastActivityMs = 0;
  for (const chat of result.chats) {
    const link = await buildLinkForChat({
      tool, provider, channelId, chat, initialSync: true, msgLimit: opts.msgLimit,
      groupType: opts.groupType,
      onAttachmentMessage: opts.onAttachmentMessage,
    });
    if (link) links.push(link);
    const t = chat.lastActivityAt.getTime();
    if (t > lastActivityMs) lastActivityMs = t;
  }
  return { links, lastActivityMs };
}
