import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ImapMessage } from "@plotday/twister/tools/imap";

// Mocked so mailInitialSyncTask/mailPoll/mailPushDrain tests below never
// attempt a real IMAP session — only the mail sync lock's decision logic
// (acquire/skip/release) is under test here, not the sync functions
// themselves (covered by sync.test.ts). Hoisted by vitest above the imports
// below regardless of source position.
vi.mock("./mail/sync", () => ({
  mailInitialSync: vi.fn(),
  mailIncrementalSync: vi.fn(),
}));

import { Apple } from "./apple";
import { composeChannels } from "./compose";
import { mailIncrementalSync, mailInitialSync } from "./mail/sync";
import { appleProducts } from "./products";
import { parse } from "./product-channel";

describe("Apple composite wiring", () => {
  it("emits namespaced calendar channels and no mail channels (stub)", async () => {
    const products = appleProducts({
      getCalendarChannels: async () => [
        { id: "/1234/calendars/home/", title: "Home" },
      ],
      getMailChannels: async () => [],
    });
    const channels = await composeChannels(products);
    expect(channels.map((c) => c.id)).toEqual(["calendar:/1234/calendars/home/"]);
    expect(parse(channels[0].id).product).toBe("calendar");
  });

  it("parses a namespaced calendar id back to its raw CalDAV href", () => {
    expect(parse("calendar:/1234/calendars/home/").rawId).toBe(
      "/1234/calendars/home/"
    );
  });
});

describe("Apple.getAccountIdentity", () => {
  // getAccountIdentity is a matchable-identity hook (unlike getAccountName,
  // display-only) the runtime uses to link the connected Apple ID's email to
  // the signed-in Plot user — see AGENTS.md's runtime owner-identity recon
  // and getAccountIdentity's JSDoc in @plotday/twister/connector.
  function makeSelf(appleId: string | undefined) {
    return { tools: { options: { appleId } } } as unknown as Apple;
  }

  it("returns the configured Apple ID as the identity email", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(
      makeSelf("me@icloud.com")
    );
    expect(result).toEqual({ email: "me@icloud.com" });
  });

  it("returns null when no Apple ID is configured yet", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(makeSelf(""));
    expect(result).toBeNull();
  });

  it("returns null when the Apple ID option is unset", async () => {
    const result = await Apple.prototype.getAccountIdentity.call(
      makeSelf(undefined)
    );
    expect(result).toBeNull();
  });
});

describe("Apple.activate", () => {
  /** Fake self exposing just enough of `this.tools`/`this.set`/`this.get`/
   *  `this.clear` for `buildMailHost()` (copied onto `self` the same way
   *  the describe blocks below do) to construct a working MailHost. */
  function makeSelf() {
    const store = new Map<string, unknown>();
    const buildMailHost = (
      Apple.prototype as unknown as { buildMailHost: () => unknown }
    ).buildMailHost;
    const self = {
      buildMailHost,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap: {},
        smtp: {},
        integrations: {},
        files: {},
      },
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      get: async (key: string) => store.get(key),
      clear: async () => {},
    } as unknown as Apple;
    return { self, store };
  }

  it("stores the activating actor's id under the mail: namespace", async () => {
    const { self, store } = makeSelf();

    await Apple.prototype.activate.call(self, {
      auth: {} as never,
      actor: { id: "actor-123" } as never,
    });

    expect(store.get("mail:auth_actor_id")).toBe("actor-123");
  });
});

describe("Apple.downloadAttachment", () => {
  /** Fake self exposing just enough of `this.tools`/`this.set`/`this.get`/
   *  `this.clear` for `buildMailHost()` (called internally by the override)
   *  to construct a working MailHost. */
  function makeSelf(opts: {
    selectedMailboxes?: string[];
    fetchedParts?: Array<{ uid: number; partNumber: string }>;
    bytes?: Uint8Array;
    disconnected?: { count: number };
    fetchAttachmentImpl?: (
      session: string,
      uid: number,
      partNumber: string
    ) => Promise<Uint8Array>;
  }) {
    const selectedMailboxes = opts.selectedMailboxes ?? [];
    const fetchedParts = opts.fetchedParts ?? [];
    const disconnected = opts.disconnected ?? { count: 0 };
    // downloadAttachment() calls the private buildMailHost() helper. It's
    // not inherited by a bare object literal (unlike getAccountIdentity
    // above, which touches no private helper), and `tools` is a getter-only
    // accessor on the real Twist base class so we can't route through
    // Object.create(Apple.prototype) either — instead, copy the real
    // buildMailHost implementation onto `self` as an own property so
    // `this.buildMailHost()` inside downloadAttachment resolves to it,
    // called with `this` bound to our plain fake.
    const buildMailHost = (
      Apple.prototype as unknown as { buildMailHost: () => unknown }
    ).buildMailHost;
    return {
      buildMailHost,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap: {
          connect: async () => "session-1",
          selectMailbox: async (_session: string, mailbox: string) => {
            selectedMailboxes.push(mailbox);
            return { name: mailbox, exists: 0, recent: 0, uidValidity: 1, uidNext: 1 };
          },
          fetchAttachment:
            opts.fetchAttachmentImpl ??
            (async (_session: string, uid: number, partNumber: string) => {
              fetchedParts.push({ uid, partNumber });
              return opts.bytes ?? new Uint8Array([1, 2, 3]);
            }),
          disconnect: async () => {
            disconnected.count += 1;
          },
        },
        smtp: {},
        integrations: {},
        files: {},
      },
      set: async () => {},
      get: async () => undefined,
      clear: async () => {},
    } as unknown as Apple;
  }

  it("selects the ref's mailbox and fetches the part's bytes", async () => {
    const selectedMailboxes: string[] = [];
    const fetchedParts: Array<{ uid: number; partNumber: string }> = [];
    const bytes = new Uint8Array([5, 6, 7]);
    const self = makeSelf({ selectedMailboxes, fetchedParts, bytes });

    const result = await Apple.prototype.downloadAttachment.call(self, "INBOX:42:2");

    expect(selectedMailboxes).toEqual(["INBOX"]);
    expect(fetchedParts).toEqual([{ uid: 42, partNumber: "2" }]);
    expect(result).toEqual({ body: bytes, mimeType: "application/octet-stream" });
  });

  it("resolves a non-INBOX mailbox encoded in the ref", async () => {
    const selectedMailboxes: string[] = [];
    const fetchedParts: Array<{ uid: number; partNumber: string }> = [];
    const self = makeSelf({ selectedMailboxes, fetchedParts });

    await Apple.prototype.downloadAttachment.call(self, "Sent%20Messages:7:2.1");

    expect(selectedMailboxes).toEqual(["Sent Messages"]);
    expect(fetchedParts).toEqual([{ uid: 7, partNumber: "2.1" }]);
  });

  it("disconnects the IMAP session even when fetchAttachment throws", async () => {
    const disconnected = { count: 0 };
    const self = makeSelf({
      disconnected,
      fetchAttachmentImpl: async () => {
        throw new Error("part not found");
      },
    });

    await expect(
      Apple.prototype.downloadAttachment.call(self, "INBOX:42:2")
    ).rejects.toThrow("part not found");
    expect(disconnected.count).toBe(1);
  });

  it("throws a clear error for a malformed ref", async () => {
    const self = makeSelf({});
    await expect(
      Apple.prototype.downloadAttachment.call(self, "not-a-valid-ref")
    ).rejects.toThrow(/Invalid Apple Mail attachment ref/);
  });
});

describe("Apple.mailWritebackDrain", () => {
  /** Fake self exposing enough of `this.tools`/`this.set`/`this.get`/`this.clear`
   *  for `buildMailHost()` (copied onto `self` the same way `downloadAttachment`'s
   *  `makeSelf` above does) to construct a working MailHost. `inboxMessages`
   *  seeds one shared INBOX fixture (uids assigned by array order) that
   *  `resolveThreadMessages` filters down by each message's computed thread
   *  root, mirroring write.test.ts's mockHost. `initialStore` seeds the
   *  `mail:writeback:<kind>:<rootId>` payload keys `setThreadFlag` would have
   *  written on the original deferred failure. */
  function makeSelf(opts: {
    inboxMessages?: Partial<ImapMessage>[];
    searchError?: Error;
    setFlagsError?: Error;
    initialStore?: Record<string, unknown>;
  }) {
    const store = new Map<string, unknown>(Object.entries(opts.initialStore ?? {}));
    const flagCalls: Array<{ uids: number[]; flags: string[]; op: string }> = [];
    const messages = opts.inboxMessages ?? [];
    const uids = messages.map((_m, i) => i + 1);
    const imap = {
      connect: async () => "session-1",
      disconnect: async () => {},
      selectMailbox: async (_s: string, box: string) => ({
        name: box, exists: 0, recent: 0, uidValidity: 1, uidNext: 99,
      }),
      search: async () => {
        if (opts.searchError) throw opts.searchError;
        return uids;
      },
      fetchMessages: async (_s: string, u: number[]) =>
        u.map((uid) => ({ uid, flags: [], ...messages[uid - 1] }) as ImapMessage),
      setFlags: async (_s: string, u: number[], flags: string[], op: string) => {
        if (opts.setFlagsError) throw opts.setFlagsError;
        flagCalls.push({ uids: u, flags, op });
      },
    };
    const buildMailHost = (
      Apple.prototype as unknown as { buildMailHost: () => unknown }
    ).buildMailHost;
    const self = {
      buildMailHost,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap,
        smtp: {},
        integrations: {},
        files: {},
      },
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      get: async (key: string) => store.get(key),
      clear: async (key: string) => {
        store.delete(key);
      },
    } as unknown as Apple;
    return { self, flagCalls, store };
  }

  const pendingRead = { title: "Lunch?", flag: "\\Seen", operation: "add" };

  it("re-applies the flag over IMAP and clears the payload on success", async () => {
    const { self, flagCalls, store } = makeSelf({
      inboxMessages: [
        { messageId: "<root@x.com>", subject: "Lunch?", date: new Date("2026-07-15T10:00:00Z") },
      ],
      initialStore: { "mail:writeback:read:root@x.com": pendingRead },
    });

    const result = await Apple.prototype.mailWritebackDrain.call(self, ["read:root@x.com"]);

    expect(flagCalls).toEqual([{ uids: [1], flags: ["\\Seen"], op: "add" }]);
    expect(store.has("mail:writeback:read:root@x.com")).toBe(false);
    expect(result).toEqual({ retry: [] });
  });

  it("returns the id for retry and leaves the payload in place when IMAP fails again", async () => {
    const { self, flagCalls, store } = makeSelf({
      searchError: new Error("connection refused"),
      initialStore: { "mail:writeback:todo:root@x.com": { title: "Lunch?", flag: "\\Flagged", operation: "add" } },
    });

    const result = await Apple.prototype.mailWritebackDrain.call(self, ["todo:root@x.com"]);

    expect(flagCalls).toHaveLength(0);
    expect(store.has("mail:writeback:todo:root@x.com")).toBe(true);
    expect(result).toEqual({ retry: ["todo:root@x.com"] });
  });

  it("skips an id with no stored payload (already resolved by a fresher direct call) without retrying it", async () => {
    const { self, flagCalls } = makeSelf({ initialStore: {} });

    const result = await Apple.prototype.mailWritebackDrain.call(self, ["read:gone@x.com"]);

    expect(flagCalls).toHaveLength(0);
    expect(result).toEqual({ retry: [] });
  });
});

describe("Apple mail sync lock", () => {
  const channelId = "mail:INBOX";
  const lockKey = `mail_sync_${channelId}`;

  beforeEach(() => {
    vi.mocked(mailInitialSync).mockReset().mockResolvedValue(undefined);
    vi.mocked(mailIncrementalSync).mockReset().mockResolvedValue(undefined);
  });

  /**
   * Fake self for `mailInitialSyncTask`/`mailPoll`/`mailPushDrain`. Copies
   * the real (private) `buildMailHost`, `armMailWatch`, and
   * `scheduleMailPoll` onto a plain object the same way other describe
   * blocks above copy `buildMailHost` — these aren't inherited by a bare
   * object literal, so we pull them off `Apple.prototype` and let them run
   * for real against stubbed primitives (`get`/`set`/`clear`, `callback`,
   * `scheduleRecurring`, `scheduleDrain`, `tools.imap.watch`,
   * `tools.options`). This lets the tests below observe the REAL
   * downstream effects of "scheduleMailPoll/armMailWatch still ran" (a
   * `scheduleRecurring` call under the `mailpoll:` key, an `imap.watch`
   * call) rather than asserting against a stubbed-out spy standing in for
   * those helpers. `mailInitialSync`/`mailIncrementalSync` are mocked at
   * the module level (see top of file) so no real IMAP session is opened.
   */
  function makeSelf(opts: {
    enabled?: boolean;
    acquireLockResult?: boolean;
    initialStore?: Record<string, unknown>;
  }) {
    const store = new Map<string, unknown>(
      Object.entries({
        [`mail:enabled_${channelId}`]: opts.enabled ?? true,
        ...opts.initialStore,
      })
    );
    const acquireLockCalls: Array<{ key: string; ttlMs: number }> = [];
    const releaseLockCalls: string[] = [];
    const acquireLock = vi.fn(async (key: string, ttlMs: number) => {
      acquireLockCalls.push({ key, ttlMs });
      return opts.acquireLockResult ?? true;
    });
    const releaseLock = vi.fn(async (key: string) => {
      releaseLockCalls.push(key);
    });

    const scheduleDrainCalls: Array<{
      key: string;
      handler: unknown;
      options: unknown;
    }> = [];
    const scheduleDrain = vi.fn(
      async (key: string, handler: unknown, options: unknown) => {
        scheduleDrainCalls.push({ key, handler, options });
      }
    );

    const scheduleRecurringCalls: Array<{
      key: string;
      cb: unknown;
      options: unknown;
    }> = [];
    const scheduleRecurring = vi.fn(
      async (key: string, cb: unknown, options: unknown) => {
        scheduleRecurringCalls.push({ key, cb, options });
      }
    );

    const callback = vi.fn(async (..._args: unknown[]) => ({
      __callbackToken: true,
    }));

    const watchCalls: Array<{ channelId: string; config: unknown }> = [];
    const imapWatch = vi.fn(async (id: string, config: unknown) => {
      watchCalls.push({ channelId: id, config });
    });

    const buildMailHost = (
      Apple.prototype as unknown as { buildMailHost: () => unknown }
    ).buildMailHost;
    const armMailWatch = (
      Apple.prototype as unknown as {
        armMailWatch: (id: string) => Promise<void>;
      }
    ).armMailWatch;
    const scheduleMailPoll = (
      Apple.prototype as unknown as {
        scheduleMailPoll: (id: string) => Promise<void>;
      }
    ).scheduleMailPoll;

    const self = {
      buildMailHost,
      armMailWatch,
      scheduleMailPoll,
      mailPushDrain: Apple.prototype.mailPushDrain,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap: { watch: imapWatch },
        smtp: {},
        integrations: {},
        files: {},
        store: { acquireLock, releaseLock },
      },
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
      callback,
      scheduleDrain,
      scheduleRecurring,
    } as unknown as Apple;

    return {
      self,
      store,
      acquireLockCalls,
      releaseLockCalls,
      scheduleDrainCalls,
      scheduleRecurringCalls,
      watchCalls,
    };
  }

  describe("mailPoll", () => {
    it("acquires the lock, runs the incremental sync once, and releases it", async () => {
      const { self, acquireLockCalls, releaseLockCalls } = makeSelf({
        acquireLockResult: true,
      });

      await Apple.prototype.mailPoll.call(self, channelId);

      expect(acquireLockCalls).toEqual([
        { key: lockKey, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailIncrementalSync).toHaveBeenCalledTimes(1);
      expect(mailIncrementalSync).toHaveBeenCalledWith(
        expect.anything(),
        channelId
      );
      expect(releaseLockCalls).toEqual([lockKey]);
    });

    it("re-arms the watch but skips the sync when another pass holds the lock", async () => {
      const { self, watchCalls, releaseLockCalls } = makeSelf({
        acquireLockResult: false,
      });

      await Apple.prototype.mailPoll.call(self, channelId);

      expect(mailIncrementalSync).not.toHaveBeenCalled();
      // No lock we didn't take should be released.
      expect(releaseLockCalls).toEqual([]);
      // The watch re-arm runs BEFORE the lock check, so it must still fire.
      expect(watchCalls).toEqual([
        expect.objectContaining({ channelId }),
      ]);
    });

    it("releases the lock even when the incremental sync throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailIncrementalSync).mockRejectedValueOnce(
        new Error("IMAP timeout")
      );

      await expect(
        Apple.prototype.mailPoll.call(self, channelId)
      ).rejects.toThrow("IMAP timeout");

      expect(releaseLockCalls).toEqual([lockKey]);
    });

    it("does nothing when the channel is disabled", async () => {
      const { self, acquireLockCalls, watchCalls } = makeSelf({
        enabled: false,
      });

      await Apple.prototype.mailPoll.call(self, channelId);

      expect(acquireLockCalls).toEqual([]);
      expect(watchCalls).toEqual([]);
      expect(mailIncrementalSync).not.toHaveBeenCalled();
    });
  });

  describe("mailPushDrain", () => {
    it("acquires the lock, runs the incremental sync once, and releases it", async () => {
      const { self, acquireLockCalls, releaseLockCalls } = makeSelf({
        acquireLockResult: true,
      });

      await Apple.prototype.mailPushDrain.call(self, [], channelId);

      expect(acquireLockCalls).toEqual([
        { key: lockKey, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailIncrementalSync).toHaveBeenCalledTimes(1);
      expect(releaseLockCalls).toEqual([lockKey]);
    });

    it("reschedules the drain instead of dropping it when another pass holds the lock", async () => {
      const { self, scheduleDrainCalls, releaseLockCalls } = makeSelf({
        acquireLockResult: false,
      });

      await Apple.prototype.mailPushDrain.call(self, [], channelId);

      expect(mailIncrementalSync).not.toHaveBeenCalled();
      expect(releaseLockCalls).toEqual([]);
      expect(scheduleDrainCalls).toEqual([
        {
          key: `mail-push:${channelId}`,
          handler: Apple.prototype.mailPushDrain,
          options: { delayMs: 2000, handlerArgs: [channelId] },
        },
      ]);
    });

    it("releases the lock even when the incremental sync throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailIncrementalSync).mockRejectedValueOnce(
        new Error("IMAP timeout")
      );

      await expect(
        Apple.prototype.mailPushDrain.call(self, [], channelId)
      ).rejects.toThrow("IMAP timeout");

      expect(releaseLockCalls).toEqual([lockKey]);
    });

    it("does nothing when the channel is disabled", async () => {
      const { self, acquireLockCalls } = makeSelf({ enabled: false });

      await Apple.prototype.mailPushDrain.call(self, [], channelId);

      expect(acquireLockCalls).toEqual([]);
      expect(mailIncrementalSync).not.toHaveBeenCalled();
    });
  });

  describe("mailInitialSyncTask", () => {
    it("acquires the lock, runs the backfill, releases the lock, and still schedules the poll + watch", async () => {
      const { self, acquireLockCalls, releaseLockCalls, scheduleRecurringCalls, watchCalls } =
        makeSelf({ acquireLockResult: true });

      await Apple.prototype.mailInitialSyncTask.call(self, channelId);

      expect(acquireLockCalls).toEqual([
        { key: lockKey, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailInitialSync).toHaveBeenCalledTimes(1);
      expect(mailInitialSync).toHaveBeenCalledWith(
        expect.anything(),
        "INBOX",
        channelId,
        expect.any(String)
      );
      expect(releaseLockCalls).toEqual([lockKey]);
      // scheduleMailPoll's real effect: a scheduleRecurring call keyed
      // `mailpoll:<channelId>`.
      expect(scheduleRecurringCalls).toEqual([
        expect.objectContaining({ key: `mailpoll:${channelId}` }),
      ]);
      // armMailWatch's real effect: an imap.watch call for this channel.
      expect(watchCalls).toEqual([expect.objectContaining({ channelId })]);
    });

    it("skips the backfill but still schedules the poll + watch when another pass holds the lock", async () => {
      const { self, scheduleRecurringCalls, watchCalls, releaseLockCalls } =
        makeSelf({ acquireLockResult: false });

      await Apple.prototype.mailInitialSyncTask.call(self, channelId);

      expect(mailInitialSync).not.toHaveBeenCalled();
      // No lock we didn't take should be released.
      expect(releaseLockCalls).toEqual([]);
      // A re-dispatch that lost the race must not leave the channel without
      // scheduled work or a push watch.
      expect(scheduleRecurringCalls).toEqual([
        expect.objectContaining({ key: `mailpoll:${channelId}` }),
      ]);
      expect(watchCalls).toEqual([expect.objectContaining({ channelId })]);
    });

    it("releases the lock even when the backfill throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailInitialSync).mockRejectedValueOnce(
        new Error("IMAP auth failure")
      );

      await expect(
        Apple.prototype.mailInitialSyncTask.call(self, channelId)
      ).rejects.toThrow("IMAP auth failure");

      expect(releaseLockCalls).toEqual([lockKey]);
    });
  });
});
