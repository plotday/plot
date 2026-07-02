import { describe, it, expect } from "vitest";
import {
  normalizeChat,
  normalizeMessage,
  normalizeInvitation,
  normalizeProfile,
  normalizeRelation,
  normalizePost,
  normalizeComment,
  normalizePostReaction,
} from "./normalize";

describe("normalize (v2)", () => {
  it("normalizes a group linkedin chat from embedded participants with isSelf flags", () => {
    const chat = normalizeChat(
      {
        object: "Chat",
        id: "c1",
        provider: "linkedin",
        name: null,
        type: "group",
        is_group: true,
        is_archived: false,
        unread_count: 2,
        last_message_timestamp: "2026-05-22T10:00:00.000Z",
        folders: [],
        participants: [
          {
            object: "GroupParticipant",
            is_self: false,
            user: {
              object: "User",
              id: "ACoAA12345",
              display_name: "Jane Doe",
              public_identifier: "jdoe",
              public_picture_url: "https://media.licdn.com/jdoe.jpg",
              specifics: { headline: "PM" },
            },
          },
          {
            object: "GroupParticipant",
            is_self: true,
            user: {
              object: "User",
              id: "ACoAAme00",
              display_name: "Me Myself",
              public_identifier: null,
            },
          },
        ],
      },
      "linkedin"
    );
    expect(chat.id).toBe("c1");
    expect(chat.isGroup).toBe(true);
    expect(chat.participants).toHaveLength(2);
    const jane = chat.participants.find((p) => p.id === "ACoAA12345")!;
    expect(jane.name).toBe("Jane Doe");
    expect(jane.handle).toBe("jdoe");
    expect(jane.subtitle).toBe("PM");
    expect(jane.isSelf).toBe(false);
    const me = chat.participants.find((p) => p.id === "ACoAAme00")!;
    expect(me.isSelf).toBe(true);
    expect(chat.unreadCount).toBe(2);
    expect(chat.url).toBe("https://www.linkedin.com/messaging/thread/c1/");
    expect(chat.folder).toBeNull();
  });

  it("normalizes a 1:1 whatsapp chat from the embedded user; null url and profileUrl", () => {
    const chat = normalizeChat(
      {
        object: "Chat",
        id: "c2",
        provider: "whatsapp",
        name: null,
        type: "1to1",
        is_group: false,
        is_1to1: true,
        is_archived: false,
        unread_count: 0,
        last_message_timestamp: "2026-05-22T11:00:00.000Z",
        folders: [],
        user_id: "15551234567@s.whatsapp.net",
        user: {
          object: "User",
          id: "15551234567@s.whatsapp.net",
          display_name: "Alice",
          public_identifier: "alice_wa",
        },
      },
      "whatsapp"
    );
    expect(chat.isGroup).toBe(false);
    expect(chat.url).toBeNull();
    expect(chat.participants).toHaveLength(1);
    const alice = chat.participants[0]!;
    expect(alice.name).toBe("Alice");
    expect(alice.profileUrl).toBeNull();
  });

  it("normalizes a message and flags sent-by-me when is_sender is true", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m1",
      chat_id: "c1",
      sender_id: "ACoAA12345",
      timestamp: "2026-05-22T10:05:00.000Z",
      is_sender: true,
      is_seen: true,
      is_event: false,
      text: "Hello",
      attachments: [],
    });
    expect(msg.sentByMe).toBe(true);
    expect(msg.text).toBe("Hello");
    expect(msg.sentAt.toISOString()).toBe("2026-05-22T10:05:00.000Z");
    expect(msg.attachments).toEqual([]);
    expect(msg.eventType).toBeNull();
    expect(msg.reactions).toEqual([]);
  });

  it("normalizes reactions_counter and flags reacted-by-me", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m2",
      chat_id: "c1",
      sender_id: "ACoAA12345",
      timestamp: "2026-05-22T10:06:00.000Z",
      is_sender: false,
      is_event: false,
      text: "Nice",
      attachments: [],
      reactions_counter: [
        { value: "👍", count: 2, reacted: true },
        { value: "❤️", count: 1, reacted: false },
      ],
    });
    expect(msg.reactions).toEqual([
      { value: "👍", senderId: "", sentByMe: true },
      { value: "❤️", senderId: "", sentByMe: false },
    ]);
  });

  it("drops reactions_counter entries with no value", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m2b",
      chat_id: "c1",
      sender_id: "ACoAA12345",
      timestamp: "2026-05-22T10:06:00.000Z",
      is_sender: false,
      is_event: false,
      text: "Nice",
      attachments: [],
      reactions_counter: [
        { value: undefined as unknown as string, count: 1, reacted: false },
        { value: "👍", count: 2, reacted: true },
      ],
    });
    expect(msg.reactions).toEqual([{ value: "👍", senderId: "", sentByMe: true }]);
  });

  it("surfaces eventType for is_event messages so connectors can skip them", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m3",
      chat_id: "c1",
      sender_id: "ACoAAme00",
      timestamp: "2026-05-22T10:07:00.000Z",
      is_sender: true,
      is_event: true,
      event_type: "reaction",
      text: null,
      attachments: [],
    });
    expect(msg.eventType).toBe("reaction");
    expect(msg.text).toBe("");
  });

  it("normalizes a v2 received invitation (inviter under `user`)", () => {
    const inv = normalizeInvitation({
      object: "RelationRequest",
      id: "inv-1",
      type: "received",
      created_at: "2026-05-22T09:00:00.000Z",
      message: "Let's connect",
      user: {
        object: "User",
        id: "ACoAA999",
        display_name: "Carla Ng",
        public_identifier: "carlang",
        description: "PM",
      },
    });
    expect(inv.id).toBe("inv-1");
    expect(inv.message).toBe("Let's connect");
    expect(inv.inviter.id).toBe("ACoAA999");
    expect(inv.inviter.name).toBe("Carla Ng");
    expect(inv.inviter.handle).toBe("carlang");
    expect(inv.inviter.subtitle).toBe("PM");
    expect(inv.inviter.profileUrl).toBe("https://www.linkedin.com/in/carlang");
    expect(inv.sentAt.toISOString()).toBe("2026-05-22T09:00:00.000Z");
  });

  it("falls back to Unknown when inviter name and public id are missing", () => {
    const inv = normalizeInvitation({
      id: "inv-2",
      created_at: "2026-05-22T09:00:00.000Z",
      message: null,
      user: {
        object: "User",
        id: "ACoAA000",
        display_name: null,
        public_identifier: null,
      },
    });
    expect(inv.inviter.id).toBe("ACoAA000");
    expect(inv.inviter.name).toBe("Unknown");
    expect(inv.inviter.profileUrl).toBeNull();
  });

  it("falls back to publicIdentifier when display name missing", () => {
    const profile = normalizeProfile(
      {
        object: "User",
        id: "ACoAA000",
        display_name: null,
        public_identifier: "ghost",
      },
      "linkedin"
    );
    expect(profile.name).toBe("ghost");
    expect(profile.isSelf).toBe(false);
  });

  it("normalizeRelation maps the v2 relation shape (profile under `user`) to ChatProfile", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      id: "rel-1",
      created_at: "2008-10-30T12:26:43.000Z",
      user: {
        object: "User",
        id: "ACoAA111",
        display_name: "Grace Hopper",
        first_name: "Grace",
        last_name: "Hopper",
        public_identifier: "ghopper",
        description: "Rear Admiral, COBOL pioneer",
        profile_url: "https://www.linkedin.com/in/ghopper",
        public_picture_url: "https://media.licdn.com/g.jpg",
      },
    });
    expect(profile.id).toBe("ACoAA111");
    expect(profile.name).toBe("Grace Hopper");
    expect(profile.handle).toBe("ghopper");
    expect(profile.subtitle).toBe("Rear Admiral, COBOL pioneer");
    expect(profile.pictureUrl).toBe("https://media.licdn.com/g.jpg");
    expect(profile.profileUrl).toBe("https://www.linkedin.com/in/ghopper");
    expect(profile.email).toBeNull();
    expect(profile.isSelf).toBe(false);
  });

  it("normalizeRelation falls back to publicIdentifier when names are empty", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      id: "rel-2",
      user: {
        object: "User",
        id: "ACoAA222",
        display_name: null,
        public_identifier: "anon",
        profile_url: "https://www.linkedin.com/in/anon",
      },
    });
    expect(profile.name).toBe("anon");
    expect(profile.subtitle).toBeNull();
    expect(profile.pictureUrl).toBeNull();
  });
});

describe("normalizePost", () => {
  it("uses social_id as id and parses date", () => {
    const post = normalizePost(
      {
        social_id: "urn:li:activity:7",
        text: "Hello world",
        date: "2026-06-20T12:00:00Z",
        share_url: "https://www.linkedin.com/feed/update/urn:li:activity:7/",
        author: { object: "User", id: "auth1", display_name: "Kris Braun", public_identifier: "krisbraun" },
      },
      "linkedin"
    );
    expect(post.id).toBe("urn:li:activity:7");
    expect(post.text).toBe("Hello world");
    expect(post.createdAt.toISOString()).toBe("2026-06-20T12:00:00.000Z");
    expect(post.author.name).toBe("Kris Braun");
    expect(post.url).toBe("https://www.linkedin.com/feed/update/urn:li:activity:7/");
  });
});

describe("normalizeComment", () => {
  it("top-level comment has null parent", () => {
    const c = normalizeComment(
      { id: "c1", text: "nice", date: "2026-06-20T12:05:00Z", author: { object: "User", id: "u2", display_name: "Ada", public_identifier: null } },
      "linkedin"
    );
    expect(c.id).toBe("c1");
    expect(c.parentCommentId).toBeNull();
    expect(c.author.name).toBe("Ada");
  });
  it("reply carries parent_comment_id", () => {
    const c = normalizeComment(
      { id: "c2", text: "thanks", parent_comment_id: "c1", author: { object: "User", id: "u3", display_name: "Bo", public_identifier: null } },
      "linkedin"
    );
    expect(c.parentCommentId).toBe("c1");
  });
});

describe("normalizePostReaction", () => {
  it("maps reactor + type", () => {
    const r = normalizePostReaction(
      { reaction_type: "like", author: { object: "User", id: "u9", display_name: "Cy", public_identifier: null, public_picture_url: "http://x/y.jpg" } },
      "linkedin"
    );
    expect(r).toEqual({ reactorId: "u9", reactorName: "Cy", reactorPictureUrl: "http://x/y.jpg", reactionType: "like" });
  });
});
