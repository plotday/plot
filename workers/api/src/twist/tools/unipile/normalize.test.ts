import { describe, it, expect } from "vitest";
import {
  normalizeChat,
  normalizeMessage,
  normalizeInvitation,
  normalizeProfile,
  normalizeRelation,
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
    // v2 has no shared_secret on the request payload.
    expect(inv.sharedSecret).toBe("");
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
