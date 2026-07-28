import { ActionType } from "@plotday/twister/plot";
import type {
  Action,
  NewContact,
  NewLinkWithNotes,
  NewNote,
} from "@plotday/twister/plot";

import {
  extractSlackMessageReactions,
  formatSlackText,
  slackUserToNewActor,
  type SlackMessage,
  type SlackUserInfoMap,
} from "./slack-api";

/** A DM link note, checked against the SDK's `NewNote` shape, with a guaranteed `key`. */
export type SlackDmNote = Omit<NewNote, "thread"> & { key: string };

/** A DM link with the same guarantee applied to every note. */
export type SlackDmLink = Omit<NewLinkWithNotes, "notes"> & {
  notes: SlackDmNote[];
};

export type SlackDmLinkOptions = {
  /** The DM (`D…`) or group-DM conversation id. */
  channelId: string;
  /**
   * The other party's Slack user id for a 1:1 DM, or `null` for a group DM.
   * Drives the link key: a 1:1 conversation is identified by the person, so it
   * survives Slack re-creating the conversation, and matches how every other
   * messaging connector keys direct conversations.
   */
  counterpartyUserId: string | null;
  /** Every message fetched for this conversation, in any order. */
  messages: SlackMessage[];
  initialSync: boolean;
  userInfos?: SlackUserInfoMap;
  teamId?: string;
  customEmojiNames?: ReadonlySet<string>;
};

/**
 * The identity of one Slack direct or group conversation, as Plot keys it.
 *
 * A 1:1 is identified by the PERSON, so the link survives Slack re-creating
 * the conversation and matches how every other messaging connector keys a
 * direct conversation; the conversation id is carried alongside so the link
 * still resolves from a raw conversation reference. A group conversation has
 * no single counterparty and is keyed on the conversation alone.
 *
 * Exported because a conversation started from Plot has to land on exactly
 * the same link as the same conversation arriving from Slack. Deriving both
 * from here is what stops one chat from becoming two permanent threads.
 */
export function slackConversationIdentity(opts: {
  channelId: string;
  counterpartyUserId: string | null;
}): { source: string; sources: string[] } {
  const personSource = opts.counterpartyUserId
    ? `slack:person:${opts.counterpartyUserId}`
    : null;
  const chatSource = `slack:chat:${opts.channelId}`;
  return {
    source: personSource ?? chatSource,
    sources: personSource ? [personSource, chatSource] : [chatSource],
  };
}

/**
 * Assemble the single, permanent link for one Slack DM or group DM.
 *
 * Unlike channel content — where Slack's own reply threads are a real,
 * user-visible grouping worth preserving — a DM reads as one continuous
 * conversation. Every message becomes a note on one link, and Slack's
 * occasional threaded reply is represented as a note reply rather than a
 * separate Plot thread.
 */
export function assembleSlackDmLink(
  opts: SlackDmLinkOptions
): SlackDmLink | null {
  const {
    channelId,
    counterpartyUserId,
    messages,
    initialSync,
    userInfos,
    teamId,
    customEmojiNames,
  } = opts;

  // Slack's `ts` is a fixed-format decimal string ("1234567890.123456") that
  // is monotonically increasing within a workspace. Comparing the strings
  // directly (rather than `parseFloat`) avoids precision loss — `ts` sits at
  // the edge of what a double can represent exactly.
  const ordered = [...messages].sort((a, b) =>
    a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0
  );
  if (ordered.length === 0) return null;

  const { source, sources } = slackConversationIdentity({
    channelId,
    counterpartyUserId,
  });

  // A single code path resolves the counterparty for BOTH `accessContacts`
  // and the title below. `slackUserToNewActor` always returns a usable
  // contact — even with no `users.info` entry it falls back to the raw user
  // id as the name (a healing placeholder that self-corrects once
  // `users.info` resolves) — so `accessContacts` must never be gated on
  // `userInfos` having an entry: a cold or rate-limited sync still needs a
  // counterparty contact for filing, since link creation happens once.
  const counterpartyInfo = counterpartyUserId
    ? userInfos?.get(counterpartyUserId)
    : undefined;
  const counterparty: NewContact | null = counterpartyUserId
    ? slackUserToNewActor(counterpartyUserId, counterpartyInfo)
    : null;

  const notes: SlackDmNote[] = ordered.map((message) => {
    const userId = message.user || message.bot_id;
    const reactions = extractSlackMessageReactions(
      message,
      userInfos,
      teamId,
      customEmojiNames
    );
    // A `thread_ts` equal to the message's own `ts` marks the thread PARENT,
    // not a reply — only a differing value is an actual reply.
    const isReply = !!message.thread_ts && message.thread_ts !== message.ts;

    // Carry file/image attachments across as `fileRef` actions, same as
    // `transformSlackThread` does for channel messages — otherwise every
    // file shared in a DM silently stops appearing in Plot.
    const actions: Action[] = (message.files ?? []).map((f) => ({
      type: ActionType.fileRef as ActionType.fileRef,
      ref: f.id,
      fileName: f.name ?? "file",
      fileSize: f.size ?? null,
      mimeType: f.mimetype ?? "application/octet-stream",
      imageWidth: f.original_w ?? null,
      imageHeight: f.original_h ?? null,
    }));

    return {
      key: message.ts,
      content: formatSlackText(message.text ?? ""),
      created: new Date(parseFloat(message.ts) * 1000),
      // DMs are exactly where implicit tasks most often appear — every
      // other Slack message note gets this, DM notes must too.
      checkForTasks: true,
      actions: actions.length > 0 ? actions : null,
      ...(userId
        ? { author: slackUserToNewActor(userId, userInfos?.get(userId)) }
        : {}),
      ...(isReply ? { reNote: { key: message.thread_ts as string } } : {}),
      ...(reactions ? { reactions } : {}),
    };
  });

  const last = ordered[ordered.length - 1]!;

  // Only trust a resolved `users.info` name/email for the TITLE. The
  // no-`userInfos` fallback inside `slackUserToNewActor` (the raw Slack user
  // id) is a fine placeholder for `author`/`accessContacts` — it
  // self-corrects the moment `users.info` succeeds — but this link is
  // permanent and its title is upserted (and overwritten) on every incoming
  // message. Writing the raw id into it would permanently rename a real
  // person's thread to "U01234" on the very next cold/rate-limited sync.
  // Omitting the field instead preserves whatever title is already stored.
  const title = counterpartyInfo
    ? (counterparty?.name ?? counterparty?.email ?? undefined)
    : undefined;

  // Canonical "open in Slack" URL, same `app_redirect` scheme every other
  // Slack link uses. We anchor on the MOST RECENT message's `ts` rather than
  // the oldest: this link represents an ongoing, ever-growing conversation
  // (not a single fixed thread), so "open in Slack" should land the user
  // where the conversation currently stands — matching what they're looking
  // at in Plot — rather than scrolling them back to its very first message.
  const sourceUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${last.ts}`;

  return {
    source,
    sources,
    channelId,
    type: "dm",
    ...(title ? { title } : {}),
    preview: formatSlackText(last.text ?? ""),
    created: new Date(parseFloat(ordered[0]!.ts) * 1000),
    sourceUrl,
    ...(counterparty
      ? { author: counterparty, accessContacts: [counterparty] }
      : {}),
    // `direct: true` is what the write-back path keys on to decide that a
    // reply with no explicit target must post top-level rather than nesting
    // under this link's (permanent, possibly ancient) anchor message.
    meta: {
      syncProvider: "slack",
      channelId,
      direct: true,
      // The message a to-do star should land on (see onThreadToDo). A DM is
      // one permanent, ever-growing link with no single message of its own,
      // so this anchors on the same message `sourceUrl` above already picks
      // as "where the conversation currently stands" — the most recent one.
      threadTs: last.ts,
      ...(counterpartyUserId ? { profileId: counterpartyUserId } : {}),
    },
    notes,
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies SlackDmLink;
}
