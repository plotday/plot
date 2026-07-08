import { describe, it, expect, vi } from "vitest";

import { invitationNoteContent, LinkedIn } from "./linkedin";

function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (k: string) => (map.has(k) ? map.get(k) : null)),
    set: vi.fn(async (k: string, v: unknown) => {
      map.set(k, v);
    }),
    clear: vi.fn(async (k: string) => {
      map.delete(k);
    }),
    list: vi.fn(async (p: string) => [...map.keys()].filter((k) => k.startsWith(p))),
  };
}

function makeLinkedIn(over: {
  store?: ReturnType<typeof makeStore>;
  linkedin?: Record<string, unknown>;
  integrations?: Record<string, unknown>;
} = {}) {
  const store = over.store ?? makeStore();
  const tools = {
    store,
    integrations: {
      saveLinks: vi.fn().mockResolvedValue(["t1"]),
      saveNote: vi.fn().mockResolvedValue("n1"),
      saveContacts: vi.fn().mockResolvedValue([]),
      ...over.integrations,
    },
    linkedin: {
      acceptInvitation: vi.fn().mockResolvedValue(undefined),
      ignoreInvitation: vi.fn().mockResolvedValue(undefined),
      getProfile: vi.fn(),
      ...over.linkedin,
    },
  };
  const conn = new LinkedIn("twist-instance-1" as never, {
    getTools: () => tools,
  } as never);
  // this.get/this.set/this.clear delegate to tools.store. Mint tokens keyed by
  // the target handler so Accept/Ignore get distinct tokens.
  const mint = vi.fn(
    async (fn: { name?: string } | undefined, ...args: unknown[]) =>
      `cb:${fn?.name ?? "fn"}:${args.join(",")}`
  );
  (conn as unknown as { callback: unknown }).callback = mint;
  (conn as unknown as { actionCallback: unknown }).actionCallback = mint;
  const deleteCallback = vi.fn(async () => {});
  (conn as unknown as { deleteCallback: unknown }).deleteCallback = deleteCallback;
  return { conn, tools, store, mint, deleteCallback };
}

describe("invitationNoteContent", () => {
  it("links the name to the profile and appends the headline", () => {
    const md = invitationNoteContent({
      name: "Héctor Hernán Godoy",
      subtitle: "Designer | Product/Investment Manager",
      profileUrl: "https://www.linkedin.com/in/hector",
    });
    expect(md).toBe(
      "**[Héctor Hernán Godoy](https://www.linkedin.com/in/hector)** requested to connect.\n" +
        "Designer | Product/Investment Manager"
    );
  });

  it("omits the headline line when there is no subtitle", () => {
    const md = invitationNoteContent({
      name: "Arijit Banerjee",
      subtitle: null,
      profileUrl: "https://www.linkedin.com/in/arijit",
    });
    expect(md).toBe(
      "**[Arijit Banerjee](https://www.linkedin.com/in/arijit)** requested to connect."
    );
  });

  it("renders bold plain text (no link) when profileUrl is null", () => {
    const md = invitationNoteContent({
      name: "Samuel Hebeisen",
      subtitle: null,
      profileUrl: null,
    });
    expect(md).toBe("**Samuel Hebeisen** requested to connect.");
  });

  it("escapes markdown link brackets in the name", () => {
    const md = invitationNoteContent({
      name: "Jane [Doe]",
      subtitle: null,
      profileUrl: "https://example.com/jane",
    });
    expect(md).toBe(
      "**[Jane \\[Doe\\]](https://example.com/jane)** requested to connect."
    );
  });
});

import { ActionType } from "@plotday/twister/plot";
import type { Action } from "@plotday/twister/plot";
import type { LinkedInInvitation } from "@plotday/unipile";
import { buildInvitationLink } from "./linkedin";

function fakeInvitation(over: Partial<LinkedInInvitation> = {}): LinkedInInvitation {
  return {
    id: "inv-1",
    message: null,
    sentAt: new Date("2026-07-01T00:00:00Z"),
    inviter: {
      id: "prof-1",
      isSelf: false,
      name: "Héctor Hernán Godoy",
      handle: "hector",
      subtitle: "Designer",
      email: null,
      phone: null,
      pictureUrl: null,
      profileUrl: "https://www.linkedin.com/in/hector",
    },
    ...over,
  } as LinkedInInvitation;
}

const fakeActions: Action[] = [
  { type: ActionType.callback, title: "Accept", callback: "cb-accept" as never },
  { type: ActionType.callback, title: "Ignore", callback: "cb-ignore" as never },
];

// `NewLinkWithNotes.notes` is typed `Omit<NewNote, "thread">[]`, but `NewNote`
// is `Partial<...> & ({ id: Uuid } | { key: string } | {}) & { thread: ... }`.
// TS computes `keyof` over a union as the intersection of each member's keys,
// which is empty here (id/key/{} share nothing), so `Omit` silently drops
// `key` from the picked type even though it's set at runtime. Pre-existing
// SDK type gap (public/twister), not something to work around by editing the
// SDK from a connector task — cast locally so the tests can assert on `key`.
type NoteWithKey = ReturnType<typeof buildInvitationLink>["notes"] extends
  | (infer N)[]
  | undefined
  ? N & { key?: string }
  : never;

describe("buildInvitationLink", () => {
  it("emits the system note first with the two actions", () => {
    const link = buildInvitationLink("chan-1", fakeInvitation(), true, fakeActions);
    expect(link.notes).toHaveLength(1);
    const sys = link.notes![0] as NoteWithKey;
    expect(sys.key).toBe("invite-request-inv-1");
    expect(sys.content).toContain("requested to connect");
    expect(sys.actions).toEqual(fakeActions);
    // Connector-authored: no human author.
    expect(sys.author).toBeUndefined();
  });

  it("keeps the inviter's message note below the system note", () => {
    const link = buildInvitationLink(
      "chan-1",
      fakeInvitation({ message: "Hi, let's connect!" }),
      false,
      fakeActions
    );
    expect(link.notes).toHaveLength(2);
    expect((link.notes![0] as NoteWithKey).key).toBe("invite-request-inv-1");
    expect(link.notes![0].actions).toEqual(fakeActions);
    expect((link.notes![1] as NoteWithKey).key).toBe("invitation-inv-1");
    expect(link.notes![1].content).toBe("Hi, let's connect!");
    // Message note stays authored by the inviter, no actions.
    expect(link.notes![1].actions ?? null).toBeNull();
  });

  it("sets top-level channelId (not just inside meta)", () => {
    // link.channelId is what the platform persists and later reads back to
    // populate thread.meta.channelId for connector callbacks — a channelId
    // set only inside meta leaves accept/ignore write-back unable to resolve
    // a client for the connection.
    const link = buildInvitationLink("chan-1", fakeInvitation(), true, fakeActions);
    expect(link.channelId).toBe("chan-1");
  });
});

type BuildActions = (c: string, i: LinkedInInvitation) => Promise<Action[]>;

describe("buildInvitationActions", () => {
  it("mints Accept + Ignore callbacks and records the pending marker with tokens + sentAt", async () => {
    const { conn, store, deleteCallback } = makeLinkedIn();
    const inv = fakeInvitation();
    const actions = await (
      conn as unknown as { buildInvitationActions: BuildActions }
    ).buildInvitationActions("chan-1", inv);

    expect(actions).toHaveLength(2);
    expect(actions[0]).toMatchObject({ type: ActionType.callback, title: "Accept" });
    expect(actions[1]).toMatchObject({ type: ActionType.callback, title: "Ignore" });

    const marker = store.map.get("pending_invitation:prof-1") as {
      invitationId: string;
      sentAt: string;
      acceptToken: string;
      ignoreToken: string;
    };
    expect(marker.invitationId).toBe("inv-1");
    expect(marker.sentAt).toBe("2026-07-01T00:00:00.000Z");
    // Narrow the Action union to the callback variant to read `.callback`.
    const callbackOf = (a: Action) =>
      (a as Extract<Action, { type: ActionType.callback }>).callback;
    expect(marker.acceptToken).toBe(callbackOf(actions[0]));
    expect(marker.ignoreToken).toBe(callbackOf(actions[1]));
    expect(marker.acceptToken).not.toBe(marker.ignoreToken);
    // No prior marker → nothing to clean up.
    expect(deleteCallback).not.toHaveBeenCalled();
  });

  it("deletes the previously-minted tokens before re-minting for the same invitation", async () => {
    const store = makeStore({
      "pending_invitation:prof-1": {
        invitationId: "inv-1",
        sentAt: "2026-07-01T00:00:00.000Z",
        acceptToken: "old-accept",
        ignoreToken: "old-ignore",
      },
    });
    const { conn, deleteCallback } = makeLinkedIn({ store });
    await (
      conn as unknown as { buildInvitationActions: BuildActions }
    ).buildInvitationActions("chan-1", fakeInvitation());
    expect(deleteCallback).toHaveBeenCalledWith("old-accept");
    expect(deleteCallback).toHaveBeenCalledWith("old-ignore");
  });
});

const fakeAction: Action = {
  type: ActionType.callback,
  title: "Accept",
  callback: "cb" as never,
};

type AcceptFn = (a: Action, c: string, i: string, p: string) => Promise<void>;
type IgnoreFn = AcceptFn;

// A fully-populated pending marker as buildInvitationActions would write it.
function pendingMarker(over: Record<string, unknown> = {}) {
  return {
    invitationId: "inv-1",
    sentAt: "2026-07-01T00:00:00.000Z",
    acceptToken: "tok-accept",
    ignoreToken: "tok-ignore",
    ...over,
  };
}

describe("onAcceptInvitation", () => {
  it("accepts, flips status to inbox, clears buttons, records outcome, cleans up", async () => {
    const store = makeStore({ "pending_invitation:prof-1": pendingMarker() });
    const { conn, tools, deleteCallback } = makeLinkedIn({ store });

    await (conn as unknown as { onAcceptInvitation: AcceptFn }).onAcceptInvitation(
      fakeAction,
      "chan-1",
      "inv-1",
      "prof-1"
    );

    expect(tools.linkedin.acceptInvitation).toHaveBeenCalledWith({
      channelId: "chan-1",
      invitationId: "inv-1",
    });
    // Status flipped to inbox via a merge-save on the person-keyed link.
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({
        source: "linkedin:person:prof-1",
        type: "conversation",
        status: "inbox",
      }),
    ]);
    // Note rewritten: Connected, no buttons, position preserved via `created`.
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Connected.",
        actions: [],
        created: new Date("2026-07-01T00:00:00.000Z"),
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accepted");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
    // Consumed callback tokens deleted.
    expect(deleteCallback).toHaveBeenCalledWith("tok-accept");
    expect(deleteCallback).toHaveBeenCalledWith("tok-ignore");
  });

  it("skips the external accept but still reconciles when already resolved (self-heal)", async () => {
    const store = makeStore({
      "invitation_writeback:inv-1": "accepted",
      "pending_invitation:prof-1": pendingMarker(),
    });
    const { conn, tools } = makeLinkedIn({ store });
    await (conn as unknown as { onAcceptInvitation: AcceptFn }).onAcceptInvitation(
      fakeAction,
      "chan-1",
      "inv-1",
      "prof-1"
    );
    // The one-shot external call is guarded...
    expect(tools.linkedin.acceptInvitation).not.toHaveBeenCalled();
    // ...but the idempotent reconcile still clears the buttons (self-heal).
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Connected.",
        actions: [],
      })
    );
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ source: "linkedin:person:prof-1", status: "inbox" }),
    ]);
  });

  it("records `unavailable` and clears buttons when accept fails", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = makeStore({ "pending_invitation:prof-1": pendingMarker() });
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { acceptInvitation: vi.fn().mockRejectedValue(new Error("gone")) },
    });
    await (conn as unknown as { onAcceptInvitation: AcceptFn }).onAcceptInvitation(
      fakeAction,
      "chan-1",
      "inv-1",
      "prof-1"
    );
    // Did NOT flip status to Connected on failure.
    expect(tools.integrations.saveLinks).not.toHaveBeenCalled();
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "This request is no longer available.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("unavailable");
    warnSpy.mockRestore();
  });
});

describe("onLinkUpdated invitation accept", () => {
  const link = {
    type: "conversation",
    status: "inbox",
    source: "linkedin:person:prof-1",
    meta: { channelId: "chan-1", invitationId: "inv-1", profileId: "prof-1" },
  } as never;

  it("clears the connection-request buttons when accepted via the status picker", async () => {
    const store = makeStore();
    const { conn, tools } = makeLinkedIn({ store });

    await (conn as unknown as { onLinkUpdated: (l: never) => Promise<void> }).onLinkUpdated(link);

    expect(tools.linkedin.acceptInvitation).toHaveBeenCalledWith({
      channelId: "chan-1",
      invitationId: "inv-1",
    });
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Connected.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accepted");
  });

  it("records `unavailable` and clears buttons when the write-back accept fails", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = makeStore();
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { acceptInvitation: vi.fn().mockRejectedValue(new Error("gone")) },
    });

    await (conn as unknown as { onLinkUpdated: (l: never) => Promise<void> }).onLinkUpdated(link);

    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "This request is no longer available.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("unavailable");
    warnSpy.mockRestore();
  });
});

describe("onIgnoreInvitation", () => {
  it("ignores, archives the thread, clears buttons, records outcome, cleans up", async () => {
    const store = makeStore({ "pending_invitation:prof-1": pendingMarker() });
    const { conn, tools, deleteCallback } = makeLinkedIn({ store });

    await (conn as unknown as { onIgnoreInvitation: IgnoreFn }).onIgnoreInvitation(
      fakeAction,
      "chan-1",
      "inv-1",
      "prof-1"
    );

    expect(tools.linkedin.ignoreInvitation).toHaveBeenCalledWith({
      channelId: "chan-1",
      invitationId: "inv-1",
    });
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({
        source: "linkedin:person:prof-1",
        type: "conversation",
        archived: true,
      }),
    ]);
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({
        key: "invite-request-inv-1",
        content: "Ignored.",
        actions: [],
      })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("ignored");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
    expect(deleteCallback).toHaveBeenCalledWith("tok-accept");
    expect(deleteCallback).toHaveBeenCalledWith("tok-ignore");
  });

  it("skips the external ignore but still reconciles when already resolved (self-heal)", async () => {
    const store = makeStore({
      "invitation_writeback:inv-1": "ignored",
      "pending_invitation:prof-1": pendingMarker(),
    });
    const { conn, tools } = makeLinkedIn({ store });
    await (conn as unknown as { onIgnoreInvitation: IgnoreFn }).onIgnoreInvitation(
      fakeAction,
      "chan-1",
      "inv-1",
      "prof-1"
    );
    expect(tools.linkedin.ignoreInvitation).not.toHaveBeenCalled();
    // Reconcile still archives + clears buttons.
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ source: "linkedin:person:prof-1", archived: true }),
    ]);
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({ key: "invite-request-inv-1", content: "Ignored.", actions: [] })
    );
  });
});

describe("onWebhookEvent relation.new reconciliation", () => {
  const profile = {
    id: "prof-1",
    isSelf: false,
    name: "Héctor",
    handle: "hector",
    subtitle: null,
    email: null,
    phone: null,
    pictureUrl: null,
    profileUrl: null,
  };

  type WebhookFn = (e: unknown, c: string) => Promise<void>;

  it("flips a pending invitation to Connected and clears its buttons", async () => {
    const store = makeStore({ "pending_invitation:prof-1": pendingMarker() });
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { getProfile: vi.fn().mockResolvedValue(profile) },
    });

    await (conn as unknown as { onWebhookEvent: WebhookFn }).onWebhookEvent(
      { kind: "relation.new", profileId: "prof-1" },
      "chan-1"
    );

    expect(tools.integrations.saveContacts).toHaveBeenCalled();
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ source: "linkedin:person:prof-1", status: "inbox" }),
    ]);
    expect(tools.integrations.saveNote).toHaveBeenCalledWith(
      expect.objectContaining({ key: "invite-request-inv-1", content: "Connected.", actions: [] })
    );
    expect(store.map.get("invitation_writeback:inv-1")).toBe("accepted");
    expect(store.map.has("pending_invitation:prof-1")).toBe(false);
  });

  it("respects a prior in-Plot ignore when the relation later appears", async () => {
    const store = makeStore({
      "invitation_writeback:inv-1": "ignored",
      "pending_invitation:prof-1": pendingMarker(),
    });
    const { conn, tools } = makeLinkedIn({
      store,
      linkedin: { getProfile: vi.fn().mockResolvedValue(profile) },
    });

    await (conn as unknown as { onWebhookEvent: WebhookFn }).onWebhookEvent(
      { kind: "relation.new", profileId: "prof-1" },
      "chan-1"
    );

    // Keeps the recorded "ignored" resolution: archives, does not flip to inbox.
    expect(tools.integrations.saveLinks).toHaveBeenCalledWith([
      expect.objectContaining({ source: "linkedin:person:prof-1", archived: true }),
    ]);
    expect(store.map.get("invitation_writeback:inv-1")).toBe("ignored");
  });

  it("just saves the contact when there is no pending invitation", async () => {
    const { conn, tools } = makeLinkedIn({
      linkedin: { getProfile: vi.fn().mockResolvedValue(profile) },
    });
    await (conn as unknown as { onWebhookEvent: WebhookFn }).onWebhookEvent(
      { kind: "relation.new", profileId: "prof-1" },
      "chan-1"
    );
    expect(tools.integrations.saveContacts).toHaveBeenCalled();
    expect(tools.integrations.saveLinks).not.toHaveBeenCalled();
    expect(tools.integrations.saveNote).not.toHaveBeenCalled();
  });
});
