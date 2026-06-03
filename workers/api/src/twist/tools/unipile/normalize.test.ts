import { describe, it, expect } from "vitest";
import {
  normalizeChat,
  normalizeMessage,
  normalizeInvitation,
  normalizeProfile,
  normalizeRelation,
} from "./normalize";

describe("normalize", () => {
  it("normalizes a 1:1 linkedin chat and includes self in participants with isSelf flag", () => {
    const chat = normalizeChat(
      {
        object: "Chat",
        id: "c1",
        account_id: "acct-1",
        account_type: "LINKEDIN",
        provider_id: "linkedin-thread-xyz",
        name: null,
        type: 0,
        timestamp: "2026-05-22T10:00:00.000Z",
        unread_count: 2,
        archived: 0,
        read_only: 0,
        muted_until: null,
        attendee_provider_id: "ACoAA12345",
      },
      [
        {
          object: "Attendee",
          provider_id: "ACoAA12345",
          name: "Jane Doe",
          profile_url: "https://www.linkedin.com/in/jdoe/",
          picture_url: "https://media.licdn.com/jdoe.jpg",
          is_self: 0,
          specifics: { public_identifier: "jdoe", headline: "PM" },
        },
        {
          object: "Attendee",
          provider_id: "ACoAAme00",
          name: "Me Myself",
          profile_url: null,
          picture_url: null,
          is_self: 1,
          specifics: {},
        },
      ],
      "linkedin"
    );
    expect(chat.id).toBe("c1");
    expect(chat.isGroup).toBe(false);
    expect(chat.participants).toHaveLength(2);
    const jane = chat.participants.find((p) => p.id === "ACoAA12345")!;
    expect(jane.name).toBe("Jane Doe");
    expect(jane.handle).toBe("jdoe");
    expect(jane.isSelf).toBe(false);
    const me = chat.participants.find((p) => p.id === "ACoAAme00")!;
    expect(me.isSelf).toBe(true);
    expect(chat.unreadCount).toBe(2);
    expect(chat.url).toBe(
      "https://www.linkedin.com/messaging/thread/linkedin-thread-xyz/"
    );
    expect(chat.folder).toBeNull();
  });

  it("normalizeChat with whatsapp provider yields null url and no linkedin.com profileUrl", () => {
    const chat = normalizeChat(
      {
        object: "Chat",
        id: "c2",
        account_id: "acct-2",
        account_type: "WHATSAPP",
        provider_id: "wa-thread-abc",
        name: "WhatsApp Group",
        type: 1,
        timestamp: "2026-05-22T11:00:00.000Z",
        unread_count: 0,
        archived: 0,
        read_only: 0,
        muted_until: null,
        attendee_provider_id: "+15551234567",
      },
      [
        {
          object: "Attendee",
          provider_id: "+15551234567",
          name: "Alice",
          profile_url: null,
          picture_url: null,
          is_self: 0,
          specifics: { public_identifier: "alice_wa" },
        },
      ],
      "whatsapp"
    );
    expect(chat.url).toBeNull();
    const alice = chat.participants.find((p) => p.id === "+15551234567")!;
    // profileUrl is null (no linkedin.com fallback for non-linkedin providers)
    expect(alice.profileUrl).toBeNull();
  });

  it("normalizes a message and flags sent-by-me when is_sender=1", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m1",
      chat_id: "c1",
      chat_provider_id: "linkedin-thread-xyz",
      provider_id: "lnk-msg-1",
      sender_id: "ACoAA12345",
      sender_attendee_id: "att-1",
      timestamp: "2026-05-22T10:05:00.000Z",
      is_sender: 1,
      is_event: 0,
      seen: 1,
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

  it("normalizes message reactions and flags sent-by-me reactor", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m2",
      chat_id: "c1",
      chat_provider_id: "linkedin-thread-xyz",
      provider_id: "lnk-msg-2",
      sender_id: "ACoAA12345",
      sender_attendee_id: "att-1",
      timestamp: "2026-05-22T10:06:00.000Z",
      is_sender: 0,
      is_event: 0,
      seen: 1,
      text: "Nice",
      attachments: [],
      reactions: [
        { value: "👍", sender_id: "ACoAAme00", is_sender: true },
        { value: "❤️", sender_id: "ACoAA12345", is_sender: false },
      ],
    });
    expect(msg.reactions).toEqual([
      { value: "👍", senderId: "ACoAAme00", sentByMe: true },
      { value: "❤️", senderId: "ACoAA12345", sentByMe: false },
    ]);
  });

  it("surfaces eventType for is_event=1 messages so connectors can skip them", () => {
    const msg = normalizeMessage({
      object: "Message",
      id: "m3",
      chat_id: "c1",
      chat_provider_id: "linkedin-thread-xyz",
      provider_id: "lnk-msg-3",
      sender_id: "ACoAAme00",
      sender_attendee_id: "att-self",
      timestamp: "2026-05-22T10:07:00.000Z",
      is_sender: 1,
      is_event: 1,
      event_type: "reaction",
      seen: 1,
      text: null,
      attachments: [],
    });
    expect(msg.eventType).toBe("reaction");
    expect(msg.text).toBe("");
  });

  it("normalizes an invitation with inviter profile", () => {
    const inv = normalizeInvitation({
      object: "InvitationReceived",
      id: "inv-1",
      parsed_datetime: "2026-05-22T09:00:00.000Z",
      invitation_text: "Let's connect",
      inviter: {
        inviter_id: "ACoAA999",
        inviter_name: "Carla Ng",
        inviter_public_identifier: "carlang",
        inviter_description: "PM",
        inviter_profile_picture_url: null,
      },
      specifics: { provider: "LINKEDIN", shared_secret: "ss-token" },
    });
    expect(inv.id).toBe("inv-1");
    expect(inv.sharedSecret).toBe("ss-token");
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
      object: "InvitationReceived",
      id: "inv-2",
      parsed_datetime: "2026-05-22T09:00:00.000Z",
      invitation_text: null,
      inviter: {
        inviter_id: "ACoAA000",
        inviter_name: null,
        inviter_public_identifier: null,
        inviter_description: null,
        inviter_profile_picture_url: null,
      },
      specifics: { provider: "LINKEDIN", shared_secret: "ss-token" },
    });
    expect(inv.inviter.id).toBe("ACoAA000");
    expect(inv.inviter.name).toBe("Unknown");
    expect(inv.inviter.profileUrl).toBeNull();
  });

  it("falls back to publicIdentifier when name missing", () => {
    const profile = normalizeProfile({
      object: "Attendee",
      provider_id: "ACoAA000",
      name: null,
      profile_url: null,
      picture_url: null,
      is_self: 0,
      specifics: { public_identifier: "ghost" },
    }, "linkedin");
    expect(profile.name).toBe("ghost");
  });

  it("normalizeRelation maps the flat relation shape to ChatProfile", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      member_id: "ACoAA111",
      member_urn: "urn:li:member:111",
      connection_urn: "urn:li:fs_miniProfile:111",
      first_name: "Grace",
      last_name: "Hopper",
      headline: "Rear Admiral, COBOL pioneer",
      public_identifier: "ghopper",
      public_profile_url: "https://www.linkedin.com/in/ghopper",
      profile_picture_url: "https://media.licdn.com/g.jpg",
      created_at: 1700000000,
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
      member_id: "ACoAA222",
      member_urn: "urn:li:member:222",
      connection_urn: "urn:li:fs_miniProfile:222",
      first_name: "",
      last_name: "",
      headline: "",
      public_identifier: "anon",
      public_profile_url: "https://www.linkedin.com/in/anon",
      created_at: 1700000000,
    });
    expect(profile.name).toBe("anon");
    expect(profile.subtitle).toBeNull();
    expect(profile.pictureUrl).toBeNull();
  });

  it("normalizeRelation falls back to Unknown when names and publicIdentifier are all empty", () => {
    const profile = normalizeRelation({
      object: "UserRelation",
      member_id: "ACoAA333",
      member_urn: "urn:li:member:333",
      connection_urn: "urn:li:fs_miniProfile:333",
      first_name: "",
      last_name: "",
      headline: "",
      public_identifier: "",
      public_profile_url: "",
      created_at: 1700000000,
    });
    expect(profile.id).toBe("ACoAA333");
    expect(profile.name).toBe("Unknown");
    expect(profile.handle).toBeNull();
    expect(profile.subtitle).toBeNull();
    expect(profile.profileUrl).toBeNull();
  });
});
