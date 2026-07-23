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
import { InvalidSyncTokenError, PreconditionFailedError } from "./calendar/caldav";
import type { ICSEvent } from "./calendar/ics-parser";
import type { NewLinkWithNotes } from "@plotday/twister";
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

describe("Apple calendar incremental sync", () => {
  const calendarHref = "calendar:/1234/calendars/home/";
  const rawHref = "/1234/calendars/home/";
  const lockKey = `sync_${calendarHref}`;

  /** Pulls a private method off `Apple.prototype` for use against a plain
   *  fake `self` — same rationale as `buildMailHost`/`armMailWatch`/
   *  `scheduleMailPoll` above (not inherited by a bare object literal), just
   *  factored into a helper since the incremental-sync chain touches many
   *  more private methods (`runFastIncrementalSync`,
   *  `runFallbackIncrementalSync`, `archiveDeletedHrefs`,
   *  `processChangedHrefsChunked`, `completeIncrementalSync`, `calDavHref`,
   *  `schedulePoll`, `clearBuffers`) than any single prior describe block. */
  function privateMethod<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  const startIncrementalSync = privateMethod<
    (calendarHref: string) => Promise<void>
  >("startIncrementalSync");

  type FakeCollectionChanges = {
    token: string;
    changed: Array<{ href: string; etag: string }>;
    deletedHrefs: string[];
  };

  /**
   * Fake self for `startIncrementalSync`/`incrementalSyncContinue`.
   * `getCalDAV()` is entirely REPLACED (not copied from the prototype) with
   * a fake CalDAV client so no real network call is ever attempted; every
   * other private method the chain dispatches through `this.xxx(...)` is
   * copied onto `self` as an own property via `privateMethod` so runtime
   * dispatch resolves to the real implementation. `processCalDAVEvents` is
   * stubbed out entirely (mirrors how the mail-sync-lock tests above mock
   * `mailInitialSync`/`mailIncrementalSync`): these tests cover the
   * fast-path/fallback selection, chunking, deletion archiving, and sync-
   * cursor persistence ordering — not ICS parsing, which has its own
   * coverage elsewhere.
   *
   * `runTask` immediately invokes the queued continuation (simulating the
   * platform executing it) so a chunked run's full chain — including a
   * second `incrementalSyncContinue` execution — completes within one
   * `await startIncrementalSync(...)` in the test.
   */
  function makeSelf(opts: {
    storedToken?: string;
    syncEnabled?: boolean;
    acquireLockResult?: boolean;
    initialStore?: Record<string, unknown>;
    getCollectionChanges?: (
      href: string,
      token: string | null
    ) => Promise<FakeCollectionChanges>;
    getEventEtags?: (href: string) => Promise<Map<string, string>>;
    getCalendarCtag?: (href: string) => Promise<string | null>;
    getSyncToken?: (href: string) => Promise<string | null>;
  }) {
    const store = new Map<string, unknown>(
      Object.entries({
        [`sync_enabled_${calendarHref}`]: opts.syncEnabled ?? true,
        ...(opts.storedToken !== undefined
          ? { [`synctoken_${calendarHref}`]: opts.storedToken }
          : {}),
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

    const archiveLinksCalls: Array<{
      channelId?: string;
      meta?: Record<string, unknown>;
    }> = [];
    const archiveLinks = vi.fn(
      async (filter: { channelId?: string; meta?: Record<string, unknown> }) => {
        archiveLinksCalls.push(filter);
      }
    );

    const scheduleRecurringCalls: Array<{ key: string }> = [];
    const scheduleRecurring = vi.fn(async (key: string) => {
      scheduleRecurringCalls.push({ key });
    });

    const callback = vi.fn(
      async (fn: (...a: unknown[]) => unknown, ...args: unknown[]) => ({
        fn,
        args,
      })
    );
    const runTask = vi.fn(
      async (token: { fn: (...a: unknown[]) => Promise<unknown>; args: unknown[] }) => {
        await token.fn.call(self, ...token.args);
      }
    );

    const getCollectionChanges = vi.fn(
      opts.getCollectionChanges ??
        (async () => ({ token: "unused", changed: [], deletedHrefs: [] }))
    );
    const getEventEtags = vi.fn(
      opts.getEventEtags ?? (async () => new Map<string, string>())
    );
    const getCalendarCtag = vi.fn(opts.getCalendarCtag ?? (async () => null));
    const getSyncToken = vi.fn(opts.getSyncToken ?? (async () => null));
    const fetchEventsByHrefCalls: string[][] = [];
    const fetchEventsByHref = vi.fn(async (_href: string, hrefs: string[]) => {
      fetchEventsByHrefCalls.push(hrefs);
      return [];
    });

    const processCalDAVEventsCalls: Array<{
      events: unknown[];
      calendarHref: string;
      initialSync: boolean;
    }> = [];
    const processCalDAVEvents = vi.fn(
      async (events: unknown[], href: string, initialSync: boolean) => {
        processCalDAVEventsCalls.push({
          events,
          calendarHref: href,
          initialSync,
        });
      }
    );

    const self = {
      // Overridden — see the function-level doc above.
      getCalDAV: () => ({
        getCollectionChanges,
        getEventEtags,
        getCalendarCtag,
        getSyncToken,
        fetchEventsByHref,
      }),
      processCalDAVEvents,
      // Copied off the prototype so `this.xxx(...)` dispatch inside the real
      // (private) implementations resolves correctly against this fake.
      runFastIncrementalSync: privateMethod("runFastIncrementalSync"),
      runFallbackIncrementalSync: privateMethod("runFallbackIncrementalSync"),
      archiveDeletedHrefs: privateMethod("archiveDeletedHrefs"),
      processChangedHrefsChunked: privateMethod("processChangedHrefsChunked"),
      completeIncrementalSync: privateMethod("completeIncrementalSync"),
      calDavHref: privateMethod("calDavHref"),
      schedulePoll: privateMethod("schedulePoll"),
      clearBuffers: privateMethod("clearBuffers"),
      // Public — no cast needed.
      incrementalSyncContinue: Apple.prototype.incrementalSyncContinue,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        integrations: { archiveLinks },
        store: { acquireLock, releaseLock, list: vi.fn(async () => []) },
      },
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
      callback,
      runTask,
      scheduleRecurring,
    } as unknown as Apple;

    return {
      self,
      store,
      acquireLockCalls,
      releaseLockCalls,
      archiveLinksCalls,
      scheduleRecurringCalls,
      fetchEventsByHrefCalls,
      processCalDAVEventsCalls,
      getCollectionChanges,
      getEventEtags,
      getCalendarCtag,
      getSyncToken,
    };
  }

  it("fast path: skips getEventEtags, processes changed hrefs, and persists the returned token verbatim", async () => {
    const getCollectionChanges = vi.fn(async () => ({
      token: "new-token",
      changed: [{ href: "/cal/h1.ics", etag: "e1" }],
      deletedHrefs: [],
    }));
    const {
      self,
      store,
      acquireLockCalls,
      releaseLockCalls,
      scheduleRecurringCalls,
      fetchEventsByHrefCalls,
      processCalDAVEventsCalls,
      getEventEtags,
    } = makeSelf({ storedToken: "old-token", getCollectionChanges });

    await startIncrementalSync.call(self, calendarHref);

    expect(acquireLockCalls).toEqual([
      { key: lockKey, ttlMs: 2 * 60 * 60 * 1000 },
    ]);
    expect(getCollectionChanges).toHaveBeenCalledWith(rawHref, "old-token");
    expect(getEventEtags).not.toHaveBeenCalled(); // the whole win
    expect(fetchEventsByHrefCalls).toEqual([["/cal/h1.ics"]]);
    expect(processCalDAVEventsCalls).toEqual([
      { events: [], calendarHref, initialSync: false },
    ]);
    expect(store.get(`synctoken_${calendarHref}`)).toBe("new-token");
    expect(releaseLockCalls).toEqual([lockKey]);
    expect(scheduleRecurringCalls).toEqual([
      { key: `poll:${calendarHref}` },
    ]);
  });

  it("no stored token: runs the fallback path and seeds a token", async () => {
    const getEventEtags = vi.fn(
      async () => new Map([["/cal/h1.ics", "e1"]])
    );
    const getCalendarCtag = vi.fn(async () => "ctag-1");
    const getSyncToken = vi.fn(async () => "seeded-token");
    const getCollectionChanges = vi.fn(async () => ({
      token: "unused",
      changed: [],
      deletedHrefs: [],
    }));
    const { self, store, releaseLockCalls, fetchEventsByHrefCalls } =
      makeSelf({ getEventEtags, getCalendarCtag, getSyncToken, getCollectionChanges });

    await startIncrementalSync.call(self, calendarHref);

    expect(getCollectionChanges).not.toHaveBeenCalled(); // no token → never tries the fast path
    expect(getEventEtags).toHaveBeenCalledWith(rawHref);
    expect(fetchEventsByHrefCalls).toEqual([["/cal/h1.ics"]]);
    expect(store.get(`etags_${calendarHref}`)).toEqual({ "/cal/h1.ics": "e1" });
    expect(store.get(`ctag_${calendarHref}`)).toBe("ctag-1");
    expect(store.get(`synctoken_${calendarHref}`)).toBe("seeded-token");
    expect(releaseLockCalls).toEqual([lockKey]);
  });

  it("InvalidSyncTokenError: clears the stored token, runs the fallback, and lets no throw escape", async () => {
    const getCollectionChanges = vi.fn(async () => {
      throw new InvalidSyncTokenError();
    });
    const getEventEtags = vi.fn(async () => new Map<string, string>());
    const getSyncToken = vi.fn(async () => "fresh-token");
    const { self, store, releaseLockCalls } = makeSelf({
      storedToken: "stale-token",
      getCollectionChanges,
      getEventEtags,
      getSyncToken,
    });

    await expect(
      startIncrementalSync.call(self, calendarHref)
    ).resolves.toBeUndefined(); // no throw escapes

    expect(getCollectionChanges).toHaveBeenCalledWith(rawHref, "stale-token");
    expect(getEventEtags).toHaveBeenCalledTimes(1); // fallback ran
    expect(store.get(`synctoken_${calendarHref}`)).toBe("fresh-token"); // reseeded, not the stale one
    expect(releaseLockCalls).toEqual([lockKey]);
  });

  it("persists the token only after successful processing — a chunk failure leaves it unwritten", async () => {
    const getCollectionChanges = vi.fn(async () => ({
      token: "new-token",
      changed: [{ href: "/cal/h1.ics", etag: "e1" }],
      deletedHrefs: [],
    }));
    const { self, store, releaseLockCalls } = makeSelf({
      storedToken: "old-token",
      getCollectionChanges,
    });
    // Force the changed-href multiget to fail.
    (self as unknown as { getCalDAV: () => { fetchEventsByHref: unknown } }).getCalDAV =
      () => ({
        getCollectionChanges,
        getEventEtags: vi.fn(async () => new Map<string, string>()),
        getCalendarCtag: vi.fn(async () => null),
        getSyncToken: vi.fn(async () => null),
        fetchEventsByHref: vi.fn(async () => {
          throw new Error("network blip");
        }),
      });

    await expect(startIncrementalSync.call(self, calendarHref)).rejects.toThrow(
      "network blip"
    );

    // The OLD token is still there — never overwritten by the in-flight
    // "new-token" that was never fully applied.
    expect(store.get(`synctoken_${calendarHref}`)).toBe("old-token");
    // Cleanup still ran despite the failure.
    expect(releaseLockCalls).toEqual([lockKey]);
  });

  it("archives every deletedHref returned by the fast path, resolved to its uid", async () => {
    const getCollectionChanges = vi.fn(async () => ({
      token: "new-token",
      changed: [],
      deletedHrefs: ["/cal/d1.ics", "/cal/d2.ics"],
    }));
    const { self, archiveLinksCalls } = makeSelf({
      storedToken: "old-token",
      getCollectionChanges,
      initialStore: {
        [`event_uids_${calendarHref}`]: {
          "/cal/d1.ics": "uid-1",
          "/cal/d2.ics": "uid-2",
        },
      },
    });

    await startIncrementalSync.call(self, calendarHref);

    expect(archiveLinksCalls).toEqual([
      {
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref, uid: "uid-1" },
      },
      {
        channelId: calendarHref,
        meta: { syncProvider: "apple", syncableId: calendarHref, uid: "uid-2" },
      },
    ]);
  });

  it("chunks a >50 changed-href fast-path delta into multiple multigets and completes once, at the end", async () => {
    const hrefs = Array.from({ length: 120 }, (_, i) => `/cal/h${i}.ics`);
    const getCollectionChanges = vi.fn(async () => ({
      token: "final-token",
      changed: hrefs.map((href) => ({ href, etag: "e" })),
      deletedHrefs: [],
    }));
    const {
      self,
      store,
      releaseLockCalls,
      scheduleRecurringCalls,
      fetchEventsByHrefCalls,
    } = makeSelf({ storedToken: "old-token", getCollectionChanges });

    await startIncrementalSync.call(self, calendarHref);

    expect(fetchEventsByHrefCalls).toEqual([
      hrefs.slice(0, 50),
      hrefs.slice(50, 100),
      hrefs.slice(100, 120),
    ]);
    // Completed exactly once, only after every chunk succeeded.
    expect(store.get(`synctoken_${calendarHref}`)).toBe("final-token");
    expect(releaseLockCalls).toEqual([lockKey]);
    expect(scheduleRecurringCalls).toEqual([
      { key: `poll:${calendarHref}` },
    ]);
  });

  it("chunks a >50 changed-href fallback delta into multiple multigets and completes once, at the end", async () => {
    const hrefs = Array.from({ length: 75 }, (_, i) => `/cal/h${i}.ics`);
    const currentEtags = new Map(hrefs.map((href) => [href, "e"]));
    const getEventEtags = vi.fn(async () => currentEtags);
    const getCalendarCtag = vi.fn(async () => "ctag-final");
    const getSyncToken = vi.fn(async () => "fallback-final-token");
    const { self, store, releaseLockCalls, fetchEventsByHrefCalls } =
      makeSelf({ getEventEtags, getCalendarCtag, getSyncToken });

    await startIncrementalSync.call(self, calendarHref);

    expect(fetchEventsByHrefCalls).toEqual([
      hrefs.slice(0, 50),
      hrefs.slice(50, 75),
    ]);
    expect(store.get(`etags_${calendarHref}`)).toEqual(
      Object.fromEntries(currentEtags)
    );
    expect(store.get(`ctag_${calendarHref}`)).toBe("ctag-final");
    expect(store.get(`synctoken_${calendarHref}`)).toBe(
      "fallback-final-token"
    );
    expect(releaseLockCalls).toEqual([lockKey]);
  });
});

describe("Apple.prepareEvent — cancellation note vs mail cancel-email marker", () => {
  /** Pulls `prepareEvent` off `Apple.prototype` — same rationale as
   *  `privateMethod` in the incremental-sync describe block above (not
   *  inherited by a bare object literal). */
  function privateMethod<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  const prepareEvent = privateMethod<
    (
      icsEvent: ICSEvent,
      calendarHref: string,
      initialSync: boolean,
      eventHref?: string
    ) => Promise<NewLinkWithNotes | null>
  >("prepareEvent");

  /** Minimal fake self: `prepareEvent`'s cancelled-event branch only calls
   *  `this.get`/`this.clear`, both backed by a plain Map here. */
  function makeSelf(initialStore: Record<string, unknown> = {}) {
    const store = new Map<string, unknown>(Object.entries(initialStore));
    const clearedKeys: string[] = [];
    const self = {
      get: async <T>(key: string) => (store.get(key) as T | undefined) ?? null,
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      clear: async (key: string) => {
        clearedKeys.push(key);
        store.delete(key);
      },
    } as unknown as Apple;
    return { self, store, clearedKeys };
  }

  // Far-future so `cancellationIsForPastEventFn` never drops it as noise,
  // regardless of when this test runs.
  const cancelledEvent: ICSEvent = {
    uid: "evt-1",
    summary: "Team Sync",
    description: null,
    dtstart: { value: "20990101T100000Z", params: {} },
    dtend: { value: "20990101T110000Z", params: {} },
    duration: null,
    rrule: null,
    exdates: [],
    rdates: [],
    recurrenceId: null,
    status: "CANCELLED",
    location: null,
    organizer: { email: "organizer@example.com", name: "Pat Organizer" },
    attendees: [],
    sequence: 1,
    created: null,
    lastModified: "20990101T090000Z",
    url: null,
  };

  it("suppresses the generic cancellation note and consumes the marker when the mail sync already bundled the cancellation email", async () => {
    const { self, store, clearedKeys } = makeSelf({
      "mail:cancel-email:evt-1": { at: "2026-07-20T00:00:00.000Z" },
    });

    const link = await prepareEvent.call(
      self,
      cancelledEvent,
      "cal-href",
      false,
      "/cal/evt-1.ics"
    );

    expect(link).not.toBeNull();
    // Redundant note suppressed — the real cancellation email is already on
    // this thread via icaluid bundling.
    expect(link!.notes).toEqual([]);
    // Structural cancellation still applied unconditionally.
    expect(link!.status).toBe("Cancelled");
    expect(link!.schedules?.[0]?.archived).toBe(true);
    // One-shot marker consumed.
    expect(store.has("mail:cancel-email:evt-1")).toBe(false);
    expect(clearedKeys).toContain("mail:cancel-email:evt-1");
  });

  it("writes the generic cancellation note when there is no mail cancellation marker (regression guard)", async () => {
    const { self, clearedKeys } = makeSelf({});

    const link = await prepareEvent.call(
      self,
      cancelledEvent,
      "cal-href",
      false,
      "/cal/evt-1.ics"
    );

    expect(link).not.toBeNull();
    expect(link!.notes).toHaveLength(1);
    expect(link!.notes?.[0]).toMatchObject({
      key: "cancellation",
      content: "Pat Organizer cancelled this event.",
    });
    expect(link!.status).toBe("Cancelled");
    expect(link!.schedules?.[0]?.archived).toBe(true);
    // Nothing to consume — no marker was ever written for this uid.
    expect(clearedKeys).toEqual([]);
  });

  it("consumes the marker even on initial sync, where the cancelled event itself is skipped as noise", async () => {
    const { self, store, clearedKeys } = makeSelf({
      "mail:cancel-email:evt-1": { at: "2026-07-20T00:00:00.000Z" },
    });

    const link = await prepareEvent.call(
      self,
      cancelledEvent,
      "cal-href",
      true, // initialSync
      "/cal/evt-1.ics"
    );

    expect(link).toBeNull();
    expect(store.has("mail:cancel-email:evt-1")).toBe(false);
    expect(clearedKeys).toContain("mail:cancel-email:evt-1");
  });
});

describe("Apple.onMailChannelDisabled — mail:cancel-email: marker sweep", () => {
  function privateMethod<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  const onMailChannelDisabled = privateMethod<
    (channel: { id: string }) => Promise<void>
  >("onMailChannelDisabled");

  it("sweeps leftover mail:cancel-email: markers alongside compose/writeback/flagged, on disable", async () => {
    const cleared: string[] = [];
    const listedPrefixes: string[] = [];
    const self = {
      cancelScheduledTask: vi.fn(async () => {}),
      cancelDrain: vi.fn(async () => {}),
      deleteCallback: vi.fn(async () => {}),
      get: async () => null,
      clear: async (key: string) => {
        cleared.push(key);
      },
      tools: {
        imap: { unwatch: vi.fn(async () => {}) },
        store: {
          releaseLock: vi.fn(async () => {}),
          list: vi.fn(async (prefix: string) => {
            listedPrefixes.push(prefix);
            if (prefix === "mail:cancel-email:") {
              return ["mail:cancel-email:evt-1", "mail:cancel-email:evt-2"];
            }
            return [];
          }),
        },
        integrations: { archiveLinks: vi.fn(async () => {}) },
      },
    } as unknown as Apple;

    await onMailChannelDisabled.call(self, { id: "mail:default" });

    expect(listedPrefixes).toContain("mail:cancel-email:");
    expect(cleared).toEqual(
      expect.arrayContaining(["mail:cancel-email:evt-1", "mail:cancel-email:evt-2"])
    );
  });
});

describe("Apple.updateRSVP — If-Match etag + 412 retry", () => {
  function privateMethod<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  const updateRSVP = privateMethod<
    (
      calendarHref: string,
      eventHref: string,
      email: string,
      partstat: string
    ) => Promise<void>
  >("updateRSVP");

  const icsFixture = [
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT",
    "UID:evt-1",
    "ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:kris@plot.day",
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n");

  function makeSelf(caldav: {
    fetchEventICS: (
      href: string
    ) => Promise<{ icsData: string; etag: string | null } | null>;
    updateEventICS: (
      href: string,
      ics: string,
      etag?: string
    ) => Promise<boolean>;
  }) {
    const self = {
      getCalDAV: () => caldav,
    } as unknown as Apple;
    return self;
  }

  it("passes the etag read from fetchEventICS through to updateEventICS (If-Match)", async () => {
    const updateCalls: Array<{ href: string; ics: string; etag?: string }> = [];
    const fetchEventICS = vi.fn(async () => ({
      icsData: icsFixture,
      etag: "etag-1",
    }));
    const updateEventICS = vi.fn(
      async (href: string, ics: string, etag?: string) => {
        updateCalls.push({ href, ics, etag });
        return true;
      }
    );
    const self = makeSelf({ fetchEventICS, updateEventICS });

    await updateRSVP.call(
      self,
      "cal-href",
      "/cal/evt-1.ics",
      "kris@plot.day",
      "ACCEPTED"
    );

    expect(updateCalls).toHaveLength(1);
    expect(updateCalls[0].etag).toBe("etag-1");
    expect(updateCalls[0].ics).toContain("PARTSTAT=ACCEPTED");
  });

  it("on 412, re-reads the event, re-applies the PARTSTAT patch, and retries once — succeeding without throwing", async () => {
    // Second read simulates a concurrent edit that changed the server's
    // etag without touching this attendee's PARTSTAT line — the patch must
    // still apply cleanly to this fresh copy.
    let fetchCount = 0;
    const fetchEventICS = vi.fn(async () => {
      fetchCount++;
      return fetchCount === 1
        ? { icsData: icsFixture, etag: "etag-1" }
        : { icsData: icsFixture, etag: "etag-2" };
    });
    const updateCalls: Array<{ etag?: string }> = [];
    let updateCount = 0;
    const updateEventICS = vi.fn(
      async (_href: string, _ics: string, etag?: string) => {
        updateCount++;
        updateCalls.push({ etag });
        if (updateCount === 1) throw new PreconditionFailedError();
        return true;
      }
    );
    const self = makeSelf({ fetchEventICS, updateEventICS });

    await expect(
      updateRSVP.call(
        self,
        "cal-href",
        "/cal/evt-1.ics",
        "kris@plot.day",
        "ACCEPTED"
      )
    ).resolves.toBeUndefined();

    expect(fetchEventICS).toHaveBeenCalledTimes(2);
    expect(updateEventICS).toHaveBeenCalledTimes(2);
    // The retry PUT carries the freshly re-read etag, not the stale one.
    expect(updateCalls[0].etag).toBe("etag-1");
    expect(updateCalls[1].etag).toBe("etag-2");
  });

  it("on a 412 that recurs on the retry, propagates instead of silently swallowing", async () => {
    const fetchEventICS = vi.fn(async () => ({
      icsData: icsFixture,
      etag: "etag-1",
    }));
    const updateEventICS = vi.fn(async () => {
      throw new PreconditionFailedError();
    });
    const self = makeSelf({ fetchEventICS, updateEventICS });

    await expect(
      updateRSVP.call(
        self,
        "cal-href",
        "/cal/evt-1.ics",
        "kris@plot.day",
        "ACCEPTED"
      )
    ).rejects.toThrow();

    // Read once + retry read once; wrote once + retried write once.
    expect(fetchEventICS).toHaveBeenCalledTimes(2);
    expect(updateEventICS).toHaveBeenCalledTimes(2);
  });

  it("a non-412 write failure still throws directly, with no retry", async () => {
    const fetchEventICS = vi.fn(async () => ({
      icsData: icsFixture,
      etag: "etag-1",
    }));
    const updateEventICS = vi.fn(async () => false);
    const self = makeSelf({ fetchEventICS, updateEventICS });

    await expect(
      updateRSVP.call(
        self,
        "cal-href",
        "/cal/evt-1.ics",
        "kris@plot.day",
        "ACCEPTED"
      )
    ).rejects.toThrow(/Failed to update event/);

    expect(fetchEventICS).toHaveBeenCalledTimes(1);
    expect(updateEventICS).toHaveBeenCalledTimes(1);
  });
});
