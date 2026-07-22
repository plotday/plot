import type { ImapAddress, ImapMessage } from "@plotday/twister/tools/imap";
import type { NewContact, NewLinkWithNotes } from "@plotday/twister";

import { looksLikeHtml } from "./html";

/** Strip surrounding angle brackets and whitespace from a Message-ID. */
export function stripAngle(id: string): string {
  return id.replace(/[<>]/g, "").trim();
}

/** Thread root id: first Reference if present, else the message's own id. */
export function rootMessageId(msg: ImapMessage): string | null {
  const ref = msg.references && msg.references.length > 0 ? msg.references[0] : null;
  const raw = ref ?? msg.messageId ?? null;
  if (!raw) return null;
  const stripped = stripAngle(raw);
  return stripped.length > 0 ? stripped : null;
}

/** Global dedup key for a mail thread. */
export function mailSource(rootId: string): string {
  return `icloud-mail:thread:${rootId}`;
}

export type TransformCtx = {
  /** Namespaced enabled channel id, e.g. "mail:INBOX". */
  channelId: string;
  /** The connection owner's Apple ID (their own address). */
  appleId: string;
  /** True when these messages came from the Sent mailbox. */
  fromSent: boolean;
  initialSync: boolean;
};

function toContact(a: ImapAddress): NewContact {
  return { email: a.address, name: a.name ?? "" };
}

function isSeen(msg: ImapMessage): boolean {
  return msg.flags.includes("\\Seen");
}

/** Pick body content + contentType for one message. */
function bodyOf(msg: ImapMessage): { content: string; contentType: "html" | "text" } | null {
  if (msg.bodyHtml && msg.bodyHtml.trim().length > 0) {
    return { content: msg.bodyHtml, contentType: "html" };
  }
  if (msg.bodyText && msg.bodyText.trim().length > 0) {
    return {
      content: msg.bodyText,
      contentType: looksLikeHtml(msg.bodyText) ? "html" : "text",
    };
  }
  return null;
}

/**
 * Group a batch of messages by thread root and build one NewLinkWithNotes per
 * thread. Notes are keyed by (stripped) Message-ID for idempotent upsert; the
 * link author is the earliest message's sender; accessContacts is the union of
 * every participant seen; the owner's own messages are credited via
 * authoredBySelf.
 */
export function transformMessages(
  messages: ImapMessage[],
  ctx: TransformCtx
): NewLinkWithNotes[] {
  const ownEmail = ctx.appleId.toLowerCase();
  // Group by thread root (skip messages with no id to thread on).
  const byRoot = new Map<string, ImapMessage[]>();
  for (const m of messages) {
    const root = rootMessageId(m);
    if (!root) continue;
    const list = byRoot.get(root) ?? [];
    list.push(m);
    byRoot.set(root, list);
  }

  const links: NewLinkWithNotes[] = [];
  for (const [root, msgs] of byRoot.entries()) {
    // Earliest message drives the thread's title + author.
    const ordered = [...msgs].sort(
      (a, b) => (a.date?.getTime() ?? 0) - (b.date?.getTime() ?? 0)
    );
    const originator = ordered[0];
    const originatorFrom = originator.from && originator.from[0] ? originator.from[0] : null;

    // Union of participants for thread access.
    const participants = new Map<string, NewContact>();
    for (const m of msgs) {
      for (const a of [...(m.from ?? []), ...(m.to ?? []), ...(m.cc ?? [])]) {
        participants.set(a.address.toLowerCase(), toContact(a));
      }
    }

    const notes = ordered.map((m) => {
      const key = m.messageId ? stripAngle(m.messageId) : `uid-${m.uid}`;
      const body = bodyOf(m);
      const from = m.from && m.from[0] ? m.from[0] : null;
      const isOwner = ctx.fromSent || (from?.address.toLowerCase() === ownEmail);
      return {
        key,
        content: body?.content ?? "",
        contentType: body?.contentType ?? ("text" as const),
        created: m.date,
        // Owner's own messages: credit via authoredBySelf, leave author unset.
        ...(isOwner
          ? { authoredBySelf: true as const }
          : { author: from ? toContact(from) : null }),
      };
    });

    const anyUnseen = msgs.some((m) => !isSeen(m));
    const link: NewLinkWithNotes = {
      source: mailSource(root),
      type: "email",
      title: originator.subject ?? "",
      channelId: ctx.channelId,
      accessContacts: [...participants.values()],
      meta: {
        syncProvider: "apple-mail",
        syncableId: ctx.channelId,
        rootMessageId: root,
      },
      notes,
      // Thread author = originating sender (the owner's own address for
      // owner-sent threads); explicit null when the sender is unknown, so a
      // From-less message is never mis-credited to the connector.
      author: originatorFrom ? toContact(originatorFrom) : null,
      ...(ctx.initialSync
        ? { unread: false, archived: false }
        : { unread: anyUnseen }),
    };
    links.push(link);
  }
  return links;
}
