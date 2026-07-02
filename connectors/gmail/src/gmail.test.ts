import { describe, expect, it, vi } from "vitest";
import { Gmail, recipientsFor } from "./gmail";
import {
  type GmailMessage,
  type GmailThread,
  transformGmailThread,
} from "./gmail-api";

type TestContact = { email?: string; name?: string };

/** Build a minimal single-message Gmail thread for transform tests. */
function threadWith(headers: Record<string, string>): GmailThread {
  const message: GmailMessage = {
    id: "msg-1",
    threadId: "thread-1",
    labelIds: ["INBOX"],
    snippet: "body snippet",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: {
      mimeType: "text/plain",
      headers: Object.entries(headers).map(([name, value]) => ({
        name,
        value,
      })),
      body: { size: 12, data: btoa("body snippet") },
    },
  };
  return { id: "thread-1", historyId: "1", messages: [message] };
}

function noteAuthor(thread: GmailThread): { email?: string; name?: string } {
  const plot = transformGmailThread(thread);
  return (plot.notes![0] as { author: { email?: string; name?: string } })
    .author;
}

function accessContactFor(
  thread: GmailThread,
  email: string
): TestContact | undefined {
  const plot = transformGmailThread(thread);
  return (plot.accessContacts as TestContact[]).find(
    (c) => c.email?.toLowerCase() === email.toLowerCase()
  );
}

describe("recipientsFor", () => {
  const self = "me@example.com";
  const alice = "alice@example.com";
  const bob = "bob@example.com";

  it("includes all candidates when accessContactEmails is null (no constraint)", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("always excludes self regardless of constraint", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("filters to only accessContactEmails when constraint is set", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([alice.toLowerCase()]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("private note (empty accessContactEmails) → empty recipient list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([]);
  });

  it("excludes self even when self is in accessContactEmails", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([self.toLowerCase(), alice.toLowerCase()]),
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("preserves candidate order from input list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([
          bob.toLowerCase(),
          alice.toLowerCase(),
        ]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("is case-insensitive when matching self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: ["ME@EXAMPLE.COM", alice],
        self,
      })
    ).toEqual([alice]);
  });

  it("is case-insensitive when matching candidate emails against set entries", () => {
    // The set holds lowercase emails (caller normalises on insert);
    // candidates may be mixed-case and are lowercased before lookup.
    expect(
      recipientsFor({
        accessContactEmails: new Set(["alice@example.com"]),
        candidates: ["ALICE@EXAMPLE.COM", bob],
        self,
      })
    ).toEqual(["ALICE@EXAMPLE.COM"]);
  });

  it("returns empty list when all candidates are self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, "ME@EXAMPLE.COM"],
        self,
      })
    ).toEqual([]);
  });

  it("handles empty candidates list gracefully", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [],
        self,
      })
    ).toEqual([]);
  });
});

describe("transformGmailThread — mailing-list From rewrite", () => {
  it("suppresses the From name when a Google Group rewrote the From address (DMARC)", () => {
    // Google Groups rewrites the From for DMARC: the original sender
    // "Cloudflare <noreply@cloudflare.com>" distributed through the
    // team@plot.day group arrives as "Cloudflare via Plot Team <team@plot.day>"
    // with X-Original-Sender preserving the real sender. The display name
    // belongs to a different identity than the From address (the group), so we
    // must NOT name the group contact "Cloudflare".
    const thread = threadWith({
      From: "Cloudflare via Plot Team <team@plot.day>",
      To: "member@plot.day",
      "X-Original-Sender": "noreply@cloudflare.com",
      Subject: "Cloudflare Workers usage reached your threshold",
    });

    expect(noteAuthor(thread)).toMatchObject({ email: "team@plot.day" });
    expect(noteAuthor(thread).name).toBeUndefined();
    expect(accessContactFor(thread, "team@plot.day")?.name).toBeUndefined();
  });

  it("suppresses the From name from the 'via' marker when no original-sender header is present", () => {
    const thread = threadWith({
      From: "noreply-spamdigest via Plot Team <team@plot.day>",
      To: "member@plot.day",
      Subject: "Moderator's spam report for team@plot.day",
    });

    expect(noteAuthor(thread).name).toBeUndefined();
    expect(accessContactFor(thread, "team@plot.day")?.name).toBeUndefined();
  });

  it("keeps the From name for ordinary direct mail", () => {
    const thread = threadWith({
      From: "Jane Doe <jane@example.com>",
      To: "member@plot.day",
      Subject: "Hello",
    });

    expect(noteAuthor(thread)).toMatchObject({
      email: "jane@example.com",
      name: "Jane Doe",
    });
    expect(accessContactFor(thread, "jane@example.com")?.name).toBe("Jane Doe");
  });

  it("keeps the From name when the list did NOT rewrite the address (X-Original-Sender matches From)", () => {
    // Legit list post that passed DMARC: From keeps the real sender's address,
    // so the display name still belongs to that address — keep it.
    const thread = threadWith({
      From: "Jane Doe <jane@example.com>",
      To: "team@plot.day",
      "X-Original-Sender": "jane@example.com",
      Subject: "Re: roadmap",
    });

    expect(accessContactFor(thread, "jane@example.com")?.name).toBe("Jane Doe");
  });
});

describe("transformGmailThread — link author (thread originator)", () => {
  function linkAuthor(
    thread: GmailThread
  ): { email?: string; name?: string } | null | undefined {
    return (
      transformGmailThread(thread) as {
        author?: { email?: string; name?: string } | null;
      }
    ).author;
  }

  /** Build a multi-message thread; each entry is the message's From header. */
  function threadFrom(...froms: string[]): GmailThread {
    const messages: GmailMessage[] = froms.map((from, i) => ({
      id: `msg-${i + 1}`,
      threadId: "thread-1",
      labelIds: ["INBOX"],
      snippet: `body ${i + 1}`,
      historyId: "1",
      internalDate: String(1700000000000 + i * 1000),
      sizeEstimate: 100,
      payload: {
        mimeType: "text/plain",
        headers: [
          { name: "From", value: from },
          { name: "To", value: "me@example.com" },
          { name: "Subject", value: "Workshop ideas" },
        ],
        body: { size: 6, data: btoa(`body ${i + 1}`) },
      },
    }));
    return { id: "thread-1", historyId: "1", messages };
  }

  it("credits the thread to the first message's sender", () => {
    const thread = threadWith({
      From: "Jane Doe <jane@example.com>",
      To: "me@example.com",
      Subject: "Workshop ideas",
    });
    expect(linkAuthor(thread)).toMatchObject({
      email: "jane@example.com",
      name: "Jane Doe",
    });
  });

  it("credits the ORIGINATOR, not a later replier", () => {
    // Phil started the thread; Stacy replied. The thread author stays Phil;
    // the replier (Stacy) is credited via the per-note author, which the
    // notification path reads for unread replies.
    const thread = threadFrom(
      "Phil <phil@example.com>",
      "Stacy <stacy@example.com>"
    );
    expect(linkAuthor(thread)).toMatchObject({
      email: "phil@example.com",
      name: "Phil",
    });
  });

  it("mirrors the note author's DMARC name suppression", () => {
    // When a Google Group rewrote the From address, the display name belongs
    // to a different identity — the link author must suppress it exactly like
    // the note author does.
    const thread = threadWith({
      From: "Cloudflare via Plot Team <team@plot.day>",
      To: "member@plot.day",
      "X-Original-Sender": "noreply@cloudflare.com",
      Subject: "Cloudflare Workers usage reached your threshold",
    });
    expect(linkAuthor(thread)).toMatchObject({ email: "team@plot.day" });
    expect(linkAuthor(thread)?.name).toBeUndefined();
  });
});

describe("processEmailThreads — no status set", () => {
  /**
   * Build a minimal Gmail thread with the given labelIds on its single message.
   * The payload provides headers required by transformGmailThread (From/To/Subject).
   */
  function makeGmailThread(labelIds: string[]): GmailThread {
    const message: GmailMessage = {
      id: "msg-archived",
      threadId: "thread-archived",
      labelIds,
      snippet: "archived message",
      historyId: "42",
      internalDate: "1700000000000",
      sizeEstimate: 100,
      payload: {
        mimeType: "text/plain",
        headers: [
          { name: "From", value: "sender@example.com" },
          { name: "To", value: "me@example.com" },
          { name: "Subject", value: "Test archived" },
          { name: "Message-ID", value: "<msg-archived@example.com>" },
          { name: "Date", value: "Mon, 01 Jan 2024 00:00:00 +0000" },
        ],
        body: { size: 16, data: btoa("archived message") },
      },
    };
    return {
      id: "thread-archived",
      historyId: "42",
      messages: [message],
    };
  }

  function makeGmail(): { gmail: Gmail; saveLink: ReturnType<typeof vi.fn> } {
    const storeMap = new Map<string, unknown>([
      ["enabled_channels", ["INBOX"]],
    ]);
    const store = {
      get: vi.fn(async (key: string) =>
        storeMap.has(key) ? storeMap.get(key) : null
      ),
      set: vi.fn(async (key: string, value: unknown) => {
        storeMap.set(key, value);
      }),
      clear: vi.fn(async (key: string) => {
        storeMap.delete(key);
      }),
      list: vi.fn(async (prefix: string) =>
        [...storeMap.keys()].filter((k) => k.startsWith(prefix))
      ),
    };

    const saveLink = vi.fn().mockResolvedValue("thread-archived");
    const tools = {
      store,
      integrations: {
        get: vi.fn().mockResolvedValue({ token: "tok", scopes: [] }),
        saveLink,
        setThreadToDo: vi.fn().mockResolvedValue(undefined),
      },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const gmail = new Gmail(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { gmail, saveLink };
  }

  it("saves an archived thread (IMPORTANT only, no INBOX) with no status", async () => {
    // IMPORTANT only — not in INBOX, not STARRED, not SENT.
    // Old code would have set status="archived"; new code must leave it unset.
    const { gmail, saveLink } = makeGmail();
    const thread = makeGmailThread(["IMPORTANT"]);

    await (gmail as unknown as {
      processEmailThreads: (
        threads: GmailThread[],
        initialSync: boolean,
        forceChannelId?: string
      ) => Promise<void>;
    }).processEmailThreads([thread], false, "INBOX");

    expect(saveLink).toHaveBeenCalledTimes(1);
    const saved = saveLink.mock.calls[0][0];
    // status must be absent (undefined) — not "archived", not any other value
    expect(saved.status).toBeUndefined();
  });

  describe("two-way unread status sync", () => {
    it("initialSync sets unread=false but caches current Gmail unread state", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX", "UNREAD"]);

      await (gmail as any).processEmailThreads([thread], true, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBe(false);

      const cached = await (gmail as any).tools.store.get(`unread:${thread.id}`);
      expect(cached).toBe(true);
    });

    it("incrementalSync sets unread=false if thread wasn't seen and is read in Gmail", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX"]);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBe(false);

      const cached = await (gmail as any).tools.store.get(`unread:${thread.id}`);
      expect(cached).toBe(false);
    });

    it("incrementalSync leaves unread=undefined if thread wasn't seen and is unread in Gmail (receipt-default)", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX", "UNREAD"]);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBeUndefined();

      const cached = await (gmail as any).tools.store.get(`unread:${thread.id}`);
      expect(cached).toBe(true);
    });

    it("incrementalSync propagates change and sets unread=false when thread changes from unread to read", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX"]);

      const store = (gmail as any).tools.store;
      await store.set(`unread:${thread.id}`, true);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBe(false);

      const cached = await store.get(`unread:${thread.id}`);
      expect(cached).toBe(false);
    });

    it("incrementalSync propagates change and sets unread=true when thread changes from read to unread", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX", "UNREAD"]);

      const store = (gmail as any).tools.store;
      await store.set(`unread:${thread.id}`, false);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBe(true);

      const cached = await store.get(`unread:${thread.id}`);
      expect(cached).toBe(true);
    });

    it("incrementalSync suppresses echo (leaves unread=undefined) when unread status has not changed", async () => {
      const { gmail, saveLink } = makeGmail();
      const thread = makeGmailThread(["INBOX", "UNREAD"]);

      const store = (gmail as any).tools.store;
      await store.set(`unread:${thread.id}`, true);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(saveLink).toHaveBeenCalledTimes(1);
      const saved = saveLink.mock.calls[0][0];
      expect(saved.unread).toBeUndefined();
    });
  });

  describe("star -> to-do write-back (no skip_todo_writeback echo guard)", () => {
    it("calls setThreadToDo and never writes a skip_todo_writeback key", async () => {
      const { gmail } = makeGmail();
      const store = (gmail as any).tools.store;
      const integrations = (gmail as any).tools.integrations;
      await store.set("auth_actor_id", "actor-1");
      const thread = makeGmailThread(["INBOX", "STARRED"]);

      await (gmail as any).processEmailThreads([thread], false, "INBOX");

      expect(integrations.setThreadToDo).toHaveBeenCalledWith(
        "https://mail.google.com/mail/u/0/#inbox/thread-archived",
        "actor-1",
        true
      );
      expect(store.set).not.toHaveBeenCalledWith(
        expect.stringContaining("skip_todo_writeback"),
        expect.anything()
      );
    });
  });
});

describe("recoverMailboxDelivery — durable recovery on upgrade", () => {
  function setup(entries: Array<[string, unknown]>) {
    const storeMap = new Map<string, unknown>(entries);
    const store = {
      get: vi.fn(async (k: string) =>
        storeMap.has(k) ? storeMap.get(k) : null
      ),
      set: vi.fn(async (k: string, v: unknown) => {
        storeMap.set(k, v);
      }),
      clear: vi.fn(async (k: string) => {
        storeMap.delete(k);
      }),
      list: vi.fn(async (p: string) =>
        [...storeMap.keys()].filter((k) => k.startsWith(p))
      ),
    };
    const tools = { store, integrations: {}, network: {}, files: {} };
    const gmail = new Gmail(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    const spies = {
      setupMailboxWebhook: vi
        .spyOn(gmail, "setupMailboxWebhook")
        .mockResolvedValue(undefined),
      scheduleSelfHealCheck: vi
        .spyOn(gmail, "scheduleSelfHealCheck")
        .mockResolvedValue(undefined),
      scheduleMailboxRenewal: vi
        .spyOn(gmail, "scheduleMailboxRenewal")
        .mockResolvedValue(undefined),
      requeueInitialSync: vi
        .spyOn(gmail, "requeueInitialSync")
        .mockResolvedValue(undefined),
    };
    return { gmail, spies };
  }

  const webhook = (expiration: Date) => ({
    topicName: "topic",
    historyId: "1",
    expiration,
    created: "2026-01-01T00:00:00.000Z",
  });
  const FUTURE = new Date(Date.now() + 5 * 24 * 60 * 60 * 1000);
  const PAST = new Date(Date.now() - 24 * 60 * 60 * 1000);

  it("stranded (no mailbox_webhook): re-establishes the watch and backfills every enabled label", async () => {
    const { gmail, spies } = setup([["enabled_channels", ["INBOX", "SENT"]]]);
    await gmail.recoverMailboxDelivery();
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("INBOX");
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("SENT");
    expect(spies.setupMailboxWebhook).toHaveBeenCalledTimes(1);
    expect(spies.scheduleSelfHealCheck).not.toHaveBeenCalled();
  });

  it("expired watch: treated as stranded — re-establishes and backfills", async () => {
    const { gmail, spies } = setup([
      ["enabled_channels", ["INBOX"]],
      ["mailbox_webhook", webhook(PAST)],
    ]);
    await gmail.recoverMailboxDelivery();
    expect(spies.requeueInitialSync).toHaveBeenCalledWith("INBOX");
    expect(spies.setupMailboxWebhook).toHaveBeenCalledTimes(1);
    expect(spies.scheduleMailboxRenewal).not.toHaveBeenCalled();
  });

  it("healthy watch: only re-asserts recurring tasks (no re-setup, no backfill)", async () => {
    const { gmail, spies } = setup([
      ["enabled_channels", ["INBOX"]],
      ["mailbox_webhook", webhook(FUTURE)],
    ]);
    await gmail.recoverMailboxDelivery();
    expect(spies.scheduleSelfHealCheck).toHaveBeenCalledTimes(1);
    expect(spies.scheduleMailboxRenewal).toHaveBeenCalledTimes(1);
    expect(spies.setupMailboxWebhook).not.toHaveBeenCalled();
    expect(spies.requeueInitialSync).not.toHaveBeenCalled();
  });

  it("no enabled channels: does nothing", async () => {
    const { gmail, spies } = setup([["enabled_channels", []]]);
    await gmail.recoverMailboxDelivery();
    expect(spies.setupMailboxWebhook).not.toHaveBeenCalled();
    expect(spies.scheduleSelfHealCheck).not.toHaveBeenCalled();
    expect(spies.requeueInitialSync).not.toHaveBeenCalled();
  });
});

describe("thread-state write-back when the connection has no auth token", () => {
  // A Gmail connection whose OAuth has lapsed/been revoked resolves no token
  // for its channel. The thread-state write-backs (to-do star, read-state)
  // are best-effort label syncs — the user's change already lives in Plot —
  // so they must degrade to a silent no-op rather than throwing. Throwing
  // pages error tracking on every to-do/read toggle for a re-auth-needed
  // connection (PostHog issue 019ed581: "No Google authentication token
  // available", 673 occurrences / 296 users).
  function makeGmail(token: { token: string; scopes: string[] } | null): {
    gmail: Gmail;
    integrationsGet: ReturnType<typeof vi.fn>;
  } {
    const storeMap = new Map<string, unknown>([["enabled_channels", ["INBOX"]]]);
    const store = {
      get: vi.fn(async (key: string) =>
        storeMap.has(key) ? storeMap.get(key) : null
      ),
      set: vi.fn(async (key: string, value: unknown) => {
        storeMap.set(key, value);
      }),
      clear: vi.fn(async (key: string) => {
        storeMap.delete(key);
      }),
      list: vi.fn(async (prefix: string) =>
        [...storeMap.keys()].filter((k) => k.startsWith(prefix))
      ),
    };
    const integrationsGet = vi.fn().mockResolvedValue(token);
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: {},
      files: {},
    };
    const gmail = new Gmail(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { gmail, integrationsGet };
  }

  const thread = {
    id: "thread-1",
    meta: { threadId: "gmail-thread-1", channelId: "INBOX" },
  } as never;
  const actor = { id: "actor-1" } as never;

  it("onThreadToDo resolves without throwing and never calls Gmail", async () => {
    const { gmail, integrationsGet } = makeGmail(null);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}"));

    await expect(
      gmail.onThreadToDo(thread, actor, true, {})
    ).resolves.toBeUndefined();

    expect(integrationsGet).toHaveBeenCalledWith("INBOX");
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it("onThreadRead resolves without throwing and never calls Gmail", async () => {
    const { gmail, integrationsGet } = makeGmail(null);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}"));

    await expect(
      gmail.onThreadRead(thread, actor, false)
    ).resolves.toBeUndefined();

    expect(integrationsGet).toHaveBeenCalledWith("INBOX");
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it("onThreadToDo still writes the STARRED/INBOX labels when a token is present", async () => {
    const { gmail } = makeGmail({ token: "tok", scopes: [] });
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}"));

    await gmail.onThreadToDo(thread, actor, true, {});

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0];
    expect(String(url)).toContain("/threads/gmail-thread-1/modify");
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({
      addLabelIds: ["STARRED", "INBOX"],
    });
    fetchSpy.mockRestore();
  });

  it("onThreadToDo writes back even if a stale skip_todo_writeback key is present", async () => {
    const { gmail } = makeGmail({ token: "tok", scopes: [] });
    const store = (gmail as any).tools.store;
    await store.set(`skip_todo_writeback:gmail-thread-1`, true);
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}"));

    await gmail.onThreadToDo(thread, actor, true, {});

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    fetchSpy.mockRestore();
  });
});
