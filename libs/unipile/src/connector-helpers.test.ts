import { describe, expect, test } from "vitest";
import {
  profileToContact,
  joinParticipantNames,
  pickDesiredReaction,
  reconcilePerUserReaction,
  buildReactionsFromMessage,
  buildNoteFromMessage,
  assembleConversationLink,
  assembleGroupLink,
} from "./connector-helpers";
import type { ChatMessage, ChatProfile, ChatThread } from "./messaging";

const prof = (over: Partial<ChatProfile>): ChatProfile => ({
  id: "p1", isSelf: false, name: "Alice", handle: null, subtitle: null,
  email: null, phone: null, pictureUrl: null, profileUrl: null, ...over,
});
const msg = (over: Partial<ChatMessage>): ChatMessage => ({
  id: "m1", chatId: "c1", senderId: "p1", sender: null, sentByMe: false, eventType: null,
  sentAt: new Date("2026-06-01T00:00:00Z"), text: "hi", attachments: [],
  reactions: [], ...over,
});
const chat = (over: Partial<ChatThread>): ChatThread => ({
  id: "c1", title: null, isGroup: false, participants: [], lastMessagePreview: null,
  lastActivityAt: new Date("2026-06-01T00:00:00Z"), unreadCount: 0, archived: false,
  folder: null, url: null, ...over,
});

describe("profileToContact", () => {
  test("uses email when present", () => {
    const c = profileToContact(prof({ email: "a@x.com", name: "Alice" }));
    expect(c.email).toBe("a@x.com");
    expect(c.source).toEqual({ accountId: "p1" });
  });
  // Providers like LinkedIn rarely expose a real email. We must NOT manufacture
  // a `<handle>@<provider>.invalid` address: a synthetic email forces the
  // contact down addContacts' global email-dedup path and is stored as the
  // contact's real email (surfacing in pickers, blocking cross-connector merge,
  // and re-keying onto a mutable handle). Source-only keys identity on the
  // stable provider id via contact_external_account instead.
  test("source-only (no synthetic email) when only a handle is known", () => {
    const c = profileToContact(prof({ handle: "alice", email: null }));
    expect(c.email).toBeUndefined();
    expect(c.name).toBe("Alice");
    expect(c.source).toEqual({ accountId: "p1" });
  });
  test("source-only when only a phone is known", () => {
    const c = profileToContact(prof({ phone: "15551234567", handle: null, email: null }));
    expect(c.email).toBeUndefined();
    expect(c.source).toEqual({ accountId: "p1" });
  });
  test("source-only when nothing addressable", () => {
    const c = profileToContact(prof({ handle: null, email: null, phone: null }));
    expect(c.email).toBeUndefined();
    expect(c.name).toBe("Alice");
    expect(c.source).toEqual({ accountId: "p1" });
  });
});

describe("pickDesiredReaction", () => {
  test("fixed set: first allowed emoji with a reactor", () => {
    expect(pickDesiredReaction({ "❤️": [{ name: "x" }] }, ["👍", "❤️"])).toBe("❤️");
  });
  test("open-unicode: deterministic first key with a reactor", () => {
    expect(pickDesiredReaction({ "🎉": [{ name: "x" }], "🙏": [{ name: "y" }] })).toBe("🎉");
  });
  test("null when no reactors", () => {
    expect(pickDesiredReaction({})).toBeNull();
  });
});

describe("joinParticipantNames", () => {
  test("truncates with +N", () => {
    expect(joinParticipantNames([prof({ name: "A" }), prof({ name: "B" }), prof({ name: "C" })]))
      .toBe("A, B +1");
  });
});

describe("assembleConversationLink", () => {
  test("1:1 is person-keyed and includes secondary chat source", () => {
    const other = prof({ id: "p2", name: "Bob" });
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1", chat: chat({ participants: [prof({ isSelf: true }), other] }),
      messages: [msg({ senderId: "p2" })], initialSync: true,
    });
    expect(link).not.toBeNull();
    expect(link!.source).toBe("whatsapp:person:p2");
    expect(link!.sources).toContain("whatsapp:chat:c1");
    expect(link!.status).toBe("inbox");
    expect(link!.meta).toMatchObject({ syncProvider: "whatsapp", channelId: "acc1", chatId: "c1", profileId: "p2" });
    expect(link!.notes).toHaveLength(1);
  });
  test("returns null when no counterparty", () => {
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1", chat: chat({ participants: [prof({ isSelf: true })] }),
      messages: [], initialSync: true,
    });
    expect(link).toBeNull();
  });
  test("incremental sync omits status", () => {
    const link = assembleConversationLink({
      provider: "whatsapp", channelId: "acc1",
      chat: chat({ participants: [prof({ isSelf: true }), prof({ id: "p2" })] }),
      messages: [msg({ senderId: "p2" })], initialSync: false,
    });
    expect(link!.status).toBeUndefined();
  });
  test("status override applies on initial sync (Instagram message request → pending)", () => {
    const link = assembleConversationLink({
      provider: "instagram", channelId: "acc1",
      chat: chat({ participants: [prof({ isSelf: true }), prof({ id: "p2" })] }),
      messages: [msg({ senderId: "p2" })], initialSync: true, status: "pending",
    });
    expect(link!.status).toBe("pending");
  });
});

describe("buildReactionsFromMessage", () => {
  const c = chat({
    participants: [prof({ id: "p2", name: "Bob" }), prof({ id: "p3", name: "Cy" })],
  });
  test("groups reactors by emoji; resolves known participants", () => {
    const m = msg({
      reactions: [
        { value: "👍", senderId: "p2", sentByMe: false },
        { value: "👍", senderId: "p3", sentByMe: false },
      ],
    });
    const out = buildReactionsFromMessage(m, c, "instagram")!;
    expect(Object.keys(out)).toEqual(["👍"]);
    expect((out["👍"] as Array<{ name: string }>).map((a) => a.name)).toEqual(["Bob", "Cy"]);
  });
  test("unknown senders fall back to a provider-named stub actor", () => {
    const m = msg({ reactions: [{ value: "❤️", senderId: "pX", sentByMe: false }] });
    const out = buildReactionsFromMessage(m, c, "instagram")!;
    expect(out["❤️"]).toEqual([{ name: "Instagram user", source: { accountId: "pX" } }]);
  });
  test("undefined when no reactions", () => {
    expect(buildReactionsFromMessage(msg({ reactions: [] }), c, "whatsapp")).toBeUndefined();
  });
  test("skips reactions with a missing emoji value (no `undefined` key)", () => {
    const m = msg({
      reactions: [
        // Simulates the live API omitting `value` on a counter entry.
        { value: undefined as unknown as string, senderId: "p2", sentByMe: false },
        { value: "👍", senderId: "p3", sentByMe: false },
      ],
    });
    const out = buildReactionsFromMessage(m, c, "linkedin")!;
    expect(Object.keys(out)).toEqual(["👍"]);
    expect(out).not.toHaveProperty("undefined");
  });
  test("undefined when all reactions lack a value", () => {
    const m = msg({
      reactions: [{ value: undefined as unknown as string, senderId: "p2", sentByMe: false }],
    });
    expect(buildReactionsFromMessage(m, c, "linkedin")).toBeUndefined();
  });
});

describe("buildNoteFromMessage", () => {
  test("1:1 note is person-keyed and maps attachments to fileRef actions", () => {
    const c = chat({ participants: [prof({ id: "p2", name: "Bob" })] });
    const m = msg({
      id: "m9", senderId: "p2", text: "see file",
      attachments: [{ id: "att1", kind: "file", name: "doc.pdf", url: "u", contentType: "application/pdf", byteSize: 10 }],
    });
    const note = buildNoteFromMessage(m, c, "whatsapp", "p2");
    expect((note as { key?: string }).key).toBe("message-m9");
    expect(note.thread).toEqual({ source: "whatsapp:person:p2" });
    expect(note.actions).toHaveLength(1);
    expect(note.actions![0]).toMatchObject({ ref: "m9:att1", fileName: "doc.pdf", mimeType: "application/pdf" });
  });
  test("group note (no threadPersonId) is chat-keyed", () => {
    const c = chat({ id: "g1", isGroup: true, participants: [prof({ id: "p2", name: "Bob" })] });
    const note = buildNoteFromMessage(msg({ senderId: "p2" }), c, "instagram");
    expect(note.thread).toEqual({ source: "instagram:chat:g1" });
  });
  // WhatsApp group chats carry no participant roster, so `senderId` matches no
  // participant. The embedded per-message `sender` is the only identity source —
  // use it instead of the generic "Whatsapp user" fallback.
  test("uses the message sender when senderId matches no participant", () => {
    const c = chat({ id: "g1", isGroup: true, participants: [] });
    const m = msg({
      senderId: "277510822584518@lid",
      sender: prof({ id: "277510822584518@lid", name: "Andrew Karram" }),
    });
    const note = buildNoteFromMessage(m, c, "whatsapp");
    expect(note.author).toEqual({ name: "Andrew Karram", avatar: undefined, source: { accountId: "277510822584518@lid" } });
  });
  // Unipile sometimes reports a real person's group message with the group's own
  // JID as the sender (sender.id === chat.id, display_name = the group name).
  // That is not a person — never label the note with the group name; use the
  // generic stub so it is not mistaken for someone speaking as the group.
  test("ignores a sender that is the group itself (@g.us) and uses the fallback", () => {
    const c = chat({ id: "120363@g.us", isGroup: true, participants: [] });
    const m = msg({
      senderId: "120363@g.us",
      sender: prof({ id: "120363@g.us", name: "2026 Fam Canoe Trip" }),
    });
    const note = buildNoteFromMessage(m, c, "whatsapp");
    expect(note.author).toEqual({ name: "Whatsapp user", source: { accountId: "120363@g.us" } });
  });
  test("falls back to the provider-named stub when neither participant nor sender is known", () => {
    const c = chat({ id: "g1", isGroup: true, participants: [] });
    const note = buildNoteFromMessage(msg({ senderId: "277510822584518@lid", sender: null }), c, "whatsapp");
    expect(note.author).toEqual({ name: "Whatsapp user", source: { accountId: "277510822584518@lid" } });
  });
  // Own ("sent-by-me") messages are flagged `authoredBySelf` so the runtime
  // credits the connection owner's own contact. Provider self ids are
  // unreliable (empty `senderId`, self absent from 1:1 rosters), so the note's
  // own `author` stays a best-effort stub — the flag is what carries the truth.
  test("own group message is flagged authoredBySelf", () => {
    const c = chat({ id: "g1", isGroup: true, participants: [] });
    const m = msg({
      senderId: "self@lid",
      sentByMe: true,
      sender: prof({ id: "self@lid", name: "You", isSelf: true }),
    });
    const note = buildNoteFromMessage(m, c, "whatsapp");
    expect((note as { authoredBySelf?: boolean }).authoredBySelf).toBe(true);
  });
  test("own 1:1 message with empty senderId is flagged authoredBySelf", () => {
    const c = chat({ participants: [prof({ id: "them", name: "Komal" })] });
    const m = msg({ senderId: "", sentByMe: true, sender: null, text: "thanks!" });
    const note = buildNoteFromMessage(m, c, "linkedin", "them");
    expect((note as { authoredBySelf?: boolean }).authoredBySelf).toBe(true);
  });
  test("messages from other people are NOT flagged authoredBySelf and keep their sender author", () => {
    const c = chat({ participants: [prof({ id: "them", name: "Komal" })] });
    const m = msg({ senderId: "them", sentByMe: false });
    const note = buildNoteFromMessage(m, c, "linkedin", "them");
    expect((note as { authoredBySelf?: boolean }).authoredBySelf).toBeUndefined();
    expect(note.author).toEqual({ name: "Komal", avatar: undefined, source: { accountId: "them" } });
  });
});

describe("assembleGroupLink", () => {
  test("chat-keyed, contacts exclude self, title falls back to names", () => {
    const link = assembleGroupLink({
      provider: "instagram", channelId: "acc1",
      chat: chat({ isGroup: true, participants: [prof({ isSelf: true }), prof({ id: "p2", name: "Bob" }), prof({ id: "p3", name: "Cy" })] }),
      messages: [msg({ senderId: "p2" })], initialSync: true,
    });
    expect(link.source).toBe("instagram:chat:c1");
    expect(link.accessContacts).toHaveLength(2);
    expect(link.title).toBe("Bob, Cy");
  });
  // WhatsApp groups return no participant roster, so `others` is empty. Derive
  // the member contacts from the distinct non-self message senders instead, so
  // the group thread has real members rather than only the connected user.
  test("derives member contacts from message senders when the roster is empty", () => {
    const link = assembleGroupLink({
      provider: "whatsapp", channelId: "acc1",
      chat: chat({ id: "g1", isGroup: true, title: "Fam Trip", participants: [] }),
      messages: [
        msg({ id: "a", senderId: "p2@lid", sender: prof({ id: "p2@lid", name: "Andrew" }) }),
        msg({ id: "b", senderId: "p3@lid", sender: prof({ id: "p3@lid", name: "Grace" }) }),
        // duplicate sender — must be deduped
        msg({ id: "c", senderId: "p2@lid", sender: prof({ id: "p2@lid", name: "Andrew" }) }),
        // own message — must be excluded from members
        msg({ id: "d", senderId: "self@lid", sentByMe: true, sender: prof({ id: "self@lid", name: "You", isSelf: true }) }),
        // group-self sender (Unipile quirk) — must NOT become a member
        msg({ id: "e", senderId: "g1", sender: prof({ id: "g1", name: "Fam Trip" }) }),
      ],
      initialSync: true,
    });
    expect(link.accessContacts).toEqual([
      { name: "Andrew", avatar: undefined, source: { accountId: "p2@lid" } },
      { name: "Grace", avatar: undefined, source: { accountId: "p3@lid" } },
    ]);
  });
  test("keeps roster-derived members when participants are present (does not double up from senders)", () => {
    const link = assembleGroupLink({
      provider: "instagram", channelId: "acc1",
      chat: chat({ isGroup: true, participants: [prof({ isSelf: true }), prof({ id: "p2", name: "Bob" })] }),
      messages: [msg({ senderId: "p2", sender: prof({ id: "p2", name: "Bob" }) })],
      initialSync: true,
    });
    expect(link.accessContacts).toEqual([{ name: "Bob", avatar: undefined, source: { accountId: "p2" } }]);
  });
  test("type defaults to group; can be overridden to conversation (LinkedIn)", () => {
    const groupChat = chat({
      isGroup: true,
      participants: [prof({ isSelf: true }), prof({ id: "p2", name: "Bob" }), prof({ id: "p3", name: "Cy" })],
    });
    const messages = [msg({ senderId: "p2" })];
    const dflt = assembleGroupLink({ provider: "whatsapp", channelId: "acc1", chat: groupChat, messages, initialSync: true });
    expect(dflt.type).toBe("group");
    const linkedin = assembleGroupLink({ provider: "linkedin", channelId: "acc1", chat: groupChat, messages, initialSync: true, type: "conversation" });
    expect(linkedin.type).toBe("conversation");
  });
});

describe("reconcilePerUserReaction", () => {
  test("sets a newly added emoji when none was pushed", () => {
    expect(reconcilePerUserReaction(null, "👍", true)).toEqual({ action: "set", emoji: "👍" });
  });
  test("replaces the previously pushed emoji when a different one is added", () => {
    expect(reconcilePerUserReaction("👍", "❤️", true)).toEqual({ action: "set", emoji: "❤️" });
  });
  test("no-ops when the added emoji is already the pushed one", () => {
    expect(reconcilePerUserReaction("👍", "👍", true)).toEqual({ action: "none" });
  });
  test("clears when the removed emoji is the one currently pushed", () => {
    expect(reconcilePerUserReaction("👍", "👍", false)).toEqual({ action: "clear" });
  });
  test("no-ops when removing an emoji that is not the one currently pushed", () => {
    expect(reconcilePerUserReaction("❤️", "👍", false)).toEqual({ action: "none" });
  });
  test("no-ops when removing while nothing is pushed", () => {
    expect(reconcilePerUserReaction(null, "👍", false)).toEqual({ action: "none" });
  });
  test("no-ops when adding an emoji outside the allowed set (fixed-set platforms)", () => {
    expect(reconcilePerUserReaction(null, "🎉", true, ["👍", "❤️"])).toEqual({ action: "none" });
  });
  test("sets an allowed emoji on a fixed-set platform", () => {
    expect(reconcilePerUserReaction(null, "❤️", true, ["👍", "❤️"])).toEqual({ action: "set", emoji: "❤️" });
  });
});
