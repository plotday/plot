import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ImapMessage } from "@plotday/twister/tools/imap";

// Mocked so the mailSyncTask/mailSyncDrain/mailPoll/mailPushDrain tests below
// never attempt a real IMAP session — what's under test here is the
// connection-level scheduling (which channels a pass covers, which lock/drain/
// poll keys it uses), not the merged sync pass itself (covered by
// mail/sync.test.ts). Hoisted by vitest above the imports below regardless of
// source position.
vi.mock("./mail/sync", async (importOriginal) => {
  // Keep the real DEFAULT_HISTORY_MS/widestFloor exports — apple.ts's
  // resolveMailHistoryMin/persistGrantedHistoryMin depend on both — and mock
  // only mailSync itself.
  const actual = await importOriginal<typeof import("./mail/sync")>();
  return { ...actual, mailSync: vi.fn() };
});

import { Apple } from "./apple";
import {
  AuthenticationError,
  InvalidSyncTokenError,
  PreconditionFailedError,
} from "./calendar/caldav";
import type { ICSEvent } from "./calendar/ics-parser";
import type { NewLinkWithNotes } from "@plotday/twister";
import { composeChannels } from "./compose";
import { mailSync } from "./mail/sync";
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

describe("Apple.knownEventUids (via buildMailHost) — FIX 1 support", () => {
  /** Fake self exposing `this.tools.store.list` (for the `sync_enabled_`
   *  scan) plus `this.get`/`this.set`/`this.clear`, matching the shape
   *  `buildMailHost()`'s `knownEventUids` member needs. */
  function makeSelf(initialStore: Record<string, unknown> = {}) {
    const store = new Map<string, unknown>(Object.entries(initialStore));
    const buildMailHost = (
      Apple.prototype as unknown as { buildMailHost: () => unknown }
    ).buildMailHost;
    // `buildMailHost()`'s `knownEventUids` member calls `this.knownEventUids()`
    // (a private method) — copy it onto the fake self the same way
    // `buildMailHost` itself is copied, so that dispatch resolves.
    const knownEventUids = (
      Apple.prototype as unknown as { knownEventUids: () => Promise<Set<string>> }
    ).knownEventUids;
    const list = async (prefix: string) =>
      Array.from(store.keys()).filter((k) => k.startsWith(prefix));
    const self = {
      buildMailHost,
      knownEventUids,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap: {},
        smtp: {},
        integrations: {},
        files: {},
        store: { list },
      },
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      get: async (key: string) => store.get(key),
      clear: async () => {},
    } as unknown as Apple;
    return { self, store };
  }

  it("unions titled_uids_ across every enabled calendar", async () => {
    const { self } = makeSelf({
      "sync_enabled_calendar:/home/": true,
      "sync_enabled_calendar:/work/": true,
      "titled_uids_calendar:/home/": { "evt-1": true },
      "titled_uids_calendar:/work/": { "evt-2": true },
    });

    const host = (self as unknown as { buildMailHost: () => { knownEventUids: () => Promise<Set<string>> } }).buildMailHost();
    const uids = await host.knownEventUids();

    expect(uids).toEqual(new Set(["evt-1", "evt-2"]));
  });

  it("excludes a DISABLED calendar's titled_uids_ even if it's still stored", async () => {
    const { self } = makeSelf({
      "sync_enabled_calendar:/home/": true,
      "titled_uids_calendar:/home/": { "evt-1": true },
      // "calendar:/work/" was disabled — its sync_enabled_ key was cleared,
      // but suppose a stray titled_uids_ entry lingered; it must not count.
      "titled_uids_calendar:/work/": { "evt-2": true },
    });

    const host = (self as unknown as { buildMailHost: () => { knownEventUids: () => Promise<Set<string>> } }).buildMailHost();
    const uids = await host.knownEventUids();

    expect(uids).toEqual(new Set(["evt-1"]));
  });

  it("FIX 1 regression guard: does NOT report a uid known from event_uids_ alone — only titled_uids_ counts", async () => {
    const { self } = makeSelf({
      "sync_enabled_calendar:/home/": true,
      // event_uids_ has the uid (CalDAV returned it — e.g. a cancelled
      // event skipped during initial sync), but titled_uids_ does NOT
      // (no link/title was ever created for it). knownEventUids() must
      // report false here — using event_uids_ instead would silently
      // reintroduce the "Untitled" bug FIX 1 exists to fix.
      "event_uids_calendar:/home/": { "/cal/skipped.ics": "evt-skipped" },
    });

    const host = (self as unknown as { buildMailHost: () => { knownEventUids: () => Promise<Set<string>> } }).buildMailHost();
    const uids = await host.knownEventUids();

    expect(uids.has("evt-skipped")).toBe(false);
  });

  it("returns an empty set with no enabled calendars", async () => {
    const { self } = makeSelf({});

    const host = (self as unknown as { buildMailHost: () => { knownEventUids: () => Promise<Set<string>> } }).buildMailHost();
    const uids = await host.knownEventUids();

    expect(uids.size).toBe(0);
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

describe("Apple mail sync — connection-level scheduling", () => {
  const INBOX = "mail:INBOX";
  const ARCHIVE = "mail:Archive";
  // ONE lock for the whole connection, not one per channel: two overlapping
  // passes would each read-modify-write the single `mail:state` document and
  // the later writer would restore the other mailbox's pre-pass cursor.
  const LOCK_KEY = "mail_sync";

  beforeEach(() => {
    vi.mocked(mailSync).mockReset().mockResolvedValue(undefined);
  });

  /**
   * Fake self for `mailSyncTask`/`mailSyncDrain`/`mailPoll`/`mailPushed`/
   * `mailPushDrain`. Copies the real (private) `buildMailHost`,
   * `enabledMailChannels`, `armMailWatches`, and `scheduleMailPoll` onto a
   * plain object the same way other describe blocks above copy
   * `buildMailHost` — these aren't inherited by a bare object literal, so we
   * pull them off `Apple.prototype` and let them run for real against stubbed
   * primitives (`get`/`set`/`clear`, `tools.store.list`, `callback`,
   * `scheduleRecurring`, `scheduleDrain`, `tools.imap.watch`,
   * `tools.options`). This lets the tests below observe the REAL downstream
   * effects of "scheduleMailPoll/armMailWatches still ran" (a
   * `scheduleRecurring` call under the `mailpoll` key, one `imap.watch` call
   * per enabled channel) rather than asserting against stubbed-out spies.
   * `mailSync` is mocked at the module level (see top of file) so no real IMAP
   * session is opened.
   *
   * `channels` seeds the `mail:enabled_<channelId>` markers the connector
   * enumerates to build the connection's channel list.
   */
  function makeSelf(opts: {
    channels?: string[];
    acquireLockResult?: boolean;
    initialStore?: Record<string, unknown>;
  }) {
    const enabled = opts.channels ?? [INBOX];
    const store = new Map<string, unknown>(
      Object.entries({
        ...Object.fromEntries(enabled.map((id) => [`mail:enabled_${id}`, true])),
        ...opts.initialStore,
      })
    );
    // Ordered log of the lock acquire and every watch arm, so a test can prove
    // the poll re-arms watches BEFORE it consults the lock.
    const order: string[] = [];
    const acquireLockCalls: Array<{ key: string; ttlMs: number }> = [];
    const releaseLockCalls: string[] = [];
    const acquireLock = vi.fn(async (key: string, ttlMs: number) => {
      order.push(`acquireLock:${key}`);
      acquireLockCalls.push({ key, ttlMs });
      return opts.acquireLockResult ?? true;
    });
    const releaseLock = vi.fn(async (key: string) => {
      releaseLockCalls.push(key);
    });
    const list = vi.fn(async (prefix: string) =>
      [...store.keys()].filter((k) => k.startsWith(prefix))
    );

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

    const callbackCalls: unknown[][] = [];
    const callback = vi.fn(async (...args: unknown[]) => {
      callbackCalls.push(args);
      return { __callbackToken: true };
    });
    const runTaskCalls: unknown[] = [];
    const runTask = vi.fn(async (cb: unknown) => {
      runTaskCalls.push(cb);
    });

    const watchCalls: Array<{ channelId: string; config: unknown }> = [];
    const imapWatch = vi.fn(async (id: string, config: unknown) => {
      order.push(`watch:${id}`);
      watchCalls.push({ channelId: id, config });
    });

    function priv<T>(name: string): T {
      return (Apple.prototype as unknown as Record<string, T>)[name];
    }

    const self = {
      buildMailHost: priv<() => unknown>("buildMailHost"),
      enabledMailChannels: priv<() => Promise<unknown>>("enabledMailChannels"),
      armMailWatches: priv<(c: unknown) => Promise<void>>("armMailWatches"),
      scheduleMailPoll: priv<() => Promise<void>>("scheduleMailPoll"),
      resolveMailHistoryMin: priv<() => Promise<string>>("resolveMailHistoryMin"),
      persistGrantedHistoryMin: priv<(incoming: string) => Promise<string>>(
        "persistGrantedHistoryMin"
      ),
      mailSyncTask: Apple.prototype.mailSyncTask,
      mailPushDrain: Apple.prototype.mailPushDrain,
      mailSyncDrain: Apple.prototype.mailSyncDrain,
      mailPushed: Apple.prototype.mailPushed,
      tools: {
        options: { appleId: "me@icloud.com", appPassword: "pw" },
        imap: { watch: imapWatch },
        smtp: {},
        integrations: {},
        files: {},
        store: { acquireLock, releaseLock, list },
      },
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      setMany: async (entries: [string, unknown][]) => {
        for (const [key, value] of entries) store.set(key, value);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
      callback,
      runTask,
      scheduleDrain,
      scheduleRecurring,
    } as unknown as Apple;

    return {
      self,
      store,
      order,
      acquireLockCalls,
      releaseLockCalls,
      scheduleDrainCalls,
      scheduleRecurringCalls,
      callbackCalls,
      runTaskCalls,
      watchCalls,
    };
  }

  /** The channel list `mailSync` should receive, in its deterministic order. */
  const BOTH_CHANNELS = [
    { channelId: ARCHIVE, mailbox: "Archive" },
    { channelId: INBOX, mailbox: "INBOX" },
  ];

  describe("mailPoll", () => {
    it("takes ONE connection-level lock and hands mailSync every enabled channel", async () => {
      const { self, acquireLockCalls, releaseLockCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        acquireLockResult: true,
      });

      await Apple.prototype.mailPoll.call(self);

      // One lock key regardless of how many channels are enabled — two
      // concurrent passes would clobber each other's `mail:state` cursors.
      expect(acquireLockCalls).toEqual([
        { key: LOCK_KEY, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailSync).toHaveBeenCalledTimes(1);
      // Not `undefined`: a poll with no persisted granted floor still hands
      // mailSync a computed (default) floor — see the "history floor"
      // describe block below for the exact value.
      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        BOTH_CHANNELS,
        expect.any(String)
      );
      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("ignores the legacy per-channel argument deployed callbacks still carry", async () => {
      const { self } = makeSelf({ channels: [INBOX, ARCHIVE] });

      // A `mailpoll:mail:INBOX` task scheduled before this version still
      // resolves by method name and passes its channel id. The pass must
      // cover the whole connection anyway.
      await Apple.prototype.mailPoll.call(self, INBOX);

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        BOTH_CHANNELS,
        expect.any(String)
      );
    });

    it("re-arms EVERY enabled channel's watch BEFORE consulting the lock", async () => {
      const { self, order, watchCalls, releaseLockCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        acquireLockResult: false,
      });

      await Apple.prototype.mailPoll.call(self);

      expect(mailSync).not.toHaveBeenCalled();
      // No lock we didn't take should be released.
      expect(releaseLockCalls).toEqual([]);
      // A dropped IDLE watch must self-heal even while another pass holds the
      // lock, so every watch arm precedes the acquire.
      expect(order).toEqual([
        `watch:${ARCHIVE}`,
        `watch:${INBOX}`,
        `acquireLock:${LOCK_KEY}`,
      ]);
      expect(watchCalls.map((c) => c.channelId)).toEqual([ARCHIVE, INBOX]);
    });

    it("watches each channel's own raw mailbox", async () => {
      const { self, watchCalls } = makeSelf({ channels: [INBOX, ARCHIVE] });

      await Apple.prototype.mailPoll.call(self);

      expect(watchCalls).toEqual([
        expect.objectContaining({
          channelId: ARCHIVE,
          config: expect.objectContaining({ mailbox: "Archive" }),
        }),
        expect.objectContaining({
          channelId: INBOX,
          config: expect.objectContaining({ mailbox: "INBOX" }),
        }),
      ]);
    });

    it("releases the lock even when the merged pass throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailSync).mockRejectedValueOnce(new Error("IMAP timeout"));

      await expect(Apple.prototype.mailPoll.call(self)).rejects.toThrow(
        "IMAP timeout"
      );

      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("does nothing when no mail channel is enabled", async () => {
      const { self, acquireLockCalls, watchCalls } = makeSelf({ channels: [] });

      await Apple.prototype.mailPoll.call(self);

      expect(acquireLockCalls).toEqual([]);
      expect(watchCalls).toEqual([]);
      expect(mailSync).not.toHaveBeenCalled();
    });
  });

  describe("mailPushed", () => {
    it("schedules the SINGLE connection-level drain whichever channel pushed", async () => {
      const { self, scheduleDrainCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
      });

      await Apple.prototype.mailPushed.call(self, INBOX);
      await Apple.prototype.mailPushed.call(self, ARCHIVE);

      // Both pushes coalesce onto one drain key, so a burst spanning folders
      // folds into one merged pass.
      expect(scheduleDrainCalls).toEqual([
        {
          key: "mail-push",
          handler: Apple.prototype.mailPushDrain,
          options: { delayMs: 2000, handlerArgs: [] },
        },
        {
          key: "mail-push",
          handler: Apple.prototype.mailPushDrain,
          options: { delayMs: 2000, handlerArgs: [] },
        },
      ]);
    });

    it("does nothing when every mail channel is disabled", async () => {
      const { self, scheduleDrainCalls } = makeSelf({ channels: [] });

      await Apple.prototype.mailPushed.call(self, INBOX);

      expect(scheduleDrainCalls).toEqual([]);
    });

    it("still schedules the connection-level drain for the remaining channels when the push names a since-disabled channel", async () => {
      // Per-channel push filtering no longer exists — a push arrives with
      // the id of the mailbox that pushed, but `mailPushed` only checks
      // whether ANY mail channel is enabled, never whether THIS one still
      // is. INBOX is disabled here (absent from the enabled set) while
      // ARCHIVE stays enabled, and a push naming the disabled INBOX must
      // still schedule the merged pass that will cover ARCHIVE.
      const { self, scheduleDrainCalls } = makeSelf({ channels: [ARCHIVE] });

      await Apple.prototype.mailPushed.call(self, INBOX);

      expect(scheduleDrainCalls).toEqual([
        {
          key: "mail-push",
          handler: Apple.prototype.mailPushDrain,
          options: { delayMs: 2000, handlerArgs: [] },
        },
      ]);
    });
  });

  describe("mailPushDrain", () => {
    it("takes the connection-level lock and hands mailSync every enabled channel", async () => {
      const { self, acquireLockCalls, releaseLockCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        acquireLockResult: true,
      });

      await Apple.prototype.mailPushDrain.call(self, []);

      expect(acquireLockCalls).toEqual([
        { key: LOCK_KEY, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailSync).toHaveBeenCalledTimes(1);
      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        BOTH_CHANNELS,
        expect.any(String)
      );
      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("reschedules the single drain instead of dropping it when another pass holds the lock", async () => {
      const { self, scheduleDrainCalls, releaseLockCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        acquireLockResult: false,
      });

      await Apple.prototype.mailPushDrain.call(self, []);

      expect(mailSync).not.toHaveBeenCalled();
      expect(releaseLockCalls).toEqual([]);
      expect(scheduleDrainCalls).toEqual([
        {
          key: "mail-push",
          handler: Apple.prototype.mailPushDrain,
          options: { delayMs: 2000, handlerArgs: [] },
        },
      ]);
    });

    it("releases the lock even when the merged pass throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailSync).mockRejectedValueOnce(new Error("IMAP timeout"));

      await expect(
        Apple.prototype.mailPushDrain.call(self, [])
      ).rejects.toThrow("IMAP timeout");

      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("does nothing when no mail channel is enabled", async () => {
      const { self, acquireLockCalls } = makeSelf({ channels: [] });

      await Apple.prototype.mailPushDrain.call(self, []);

      expect(acquireLockCalls).toEqual([]);
      expect(mailSync).not.toHaveBeenCalled();
    });
  });

  describe("mailSyncTask", () => {
    it("runs one merged pass over every enabled channel, then arms the connection-level poll and every watch", async () => {
      const {
        self,
        acquireLockCalls,
        releaseLockCalls,
        scheduleRecurringCalls,
        watchCalls,
      } = makeSelf({ channels: [INBOX, ARCHIVE], acquireLockResult: true });

      await Apple.prototype.mailSyncTask.call(self, ARCHIVE);

      expect(acquireLockCalls).toEqual([
        { key: LOCK_KEY, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailSync).toHaveBeenCalledTimes(1);
      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        BOTH_CHANNELS,
        expect.any(String)
      );
      expect(releaseLockCalls).toEqual([LOCK_KEY]);
      // scheduleMailPoll's real effect: ONE recurring task for the whole
      // connection, with no channel suffix.
      expect(scheduleRecurringCalls).toEqual([
        expect.objectContaining({ key: "mailpoll" }),
      ]);
      // armMailWatches' real effect: one imap.watch per enabled channel.
      expect(watchCalls.map((c) => c.channelId)).toEqual([ARCHIVE, INBOX]);
    });

    it("passes the granted history floor straight through to the merged pass", async () => {
      const { self } = makeSelf({ acquireLockResult: true });

      await Apple.prototype.mailSyncTask.call(
        self,
        INBOX,
        "2020-01-01T00:00:00.000Z"
      );

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        [{ channelId: INBOX, mailbox: "INBOX" }],
        "2020-01-01T00:00:00.000Z"
      );
    });

    it("RESCHEDULES itself when another pass holds the lock, still arms the watches, but does NOT re-arm the poll", async () => {
      const {
        self,
        scheduleDrainCalls,
        scheduleRecurringCalls,
        watchCalls,
        releaseLockCalls,
      } = makeSelf({ channels: [INBOX, ARCHIVE], acquireLockResult: false });

      await Apple.prototype.mailSyncTask.call(
        self,
        ARCHIVE,
        "2020-01-01T00:00:00.000Z"
      );

      expect(mailSync).not.toHaveBeenCalled();
      expect(releaseLockCalls).toEqual([]);
      // An in-flight pass enumerated its channel list BEFORE this channel was
      // marked enabled, so it cannot cover it — skipping would strand the
      // channel's "syncing…" state forever. Retry instead, carrying the floor
      // so the granted history isn't lost with the dropped attempt.
      expect(scheduleDrainCalls).toEqual([
        {
          key: "mail-sync",
          handler: Apple.prototype.mailSyncDrain,
          options: {
            delayMs: 5000,
            handlerArgs: ["2020-01-01T00:00:00.000Z"],
          },
        },
      ]);
      // A crashed lock holder is retried every 5s for up to the 30-minute
      // TTL — re-arming the recurring poll on EVERY one of those ~360
      // retries would push its next fire 15 minutes into the future every
      // time, starving the poll's safety-net role for the whole window.
      // Watches still self-heal on every retry; only the poll re-arm is
      // deferred to the acquired branch (see the next test).
      expect(scheduleRecurringCalls).toEqual([]);
      expect(watchCalls.map((c) => c.channelId)).toEqual([ARCHIVE, INBOX]);
    });

    it("re-arms the recurring poll once the pass actually acquires the lock and runs", async () => {
      const { self, scheduleRecurringCalls } = makeSelf({
        channels: [INBOX],
        acquireLockResult: true,
      });

      await Apple.prototype.mailSyncTask.call(self, INBOX);

      expect(scheduleRecurringCalls).toEqual([
        expect.objectContaining({ key: "mailpoll" }),
      ]);
    });

    it("releases the lock even when the merged pass throws", async () => {
      const { self, releaseLockCalls } = makeSelf({ acquireLockResult: true });
      vi.mocked(mailSync).mockRejectedValueOnce(
        new Error("IMAP auth failure")
      );

      await expect(
        Apple.prototype.mailSyncTask.call(self, INBOX)
      ).rejects.toThrow("IMAP auth failure");

      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("schedules nothing when the last channel was disabled before the task ran", async () => {
      const { self, acquireLockCalls, scheduleRecurringCalls, watchCalls } =
        makeSelf({ channels: [] });

      await Apple.prototype.mailSyncTask.call(self, INBOX);

      expect(acquireLockCalls).toEqual([]);
      expect(mailSync).not.toHaveBeenCalled();
      expect(scheduleRecurringCalls).toEqual([]);
      expect(watchCalls).toEqual([]);
    });
  });

  describe("mailSyncDrain", () => {
    it("re-enters the merged pass with the floor the dropped attempt carried", async () => {
      const { self, acquireLockCalls, releaseLockCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        acquireLockResult: true,
      });

      await Apple.prototype.mailSyncDrain.call(
        self,
        [],
        "2020-01-01T00:00:00.000Z"
      );

      expect(acquireLockCalls).toEqual([
        { key: LOCK_KEY, ttlMs: 30 * 60 * 1000 },
      ]);
      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        BOTH_CHANNELS,
        "2020-01-01T00:00:00.000Z"
      );
      expect(releaseLockCalls).toEqual([LOCK_KEY]);
    });

    it("reschedules again when the lock is still held", async () => {
      const { self, scheduleDrainCalls } = makeSelf({
        acquireLockResult: false,
      });

      await Apple.prototype.mailSyncDrain.call(self, [], null);

      expect(scheduleDrainCalls).toEqual([
        expect.objectContaining({
          key: "mail-sync",
          handler: Apple.prototype.mailSyncDrain,
        }),
      ]);
    });
  });

  describe("onMailChannelEnabled", () => {
    function privateMethod<T>(name: string): T {
      return (Apple.prototype as unknown as Record<string, T>)[name];
    }
    const onMailChannelEnabled = privateMethod<
      (
        channel: { id: string },
        context?: { syncHistoryMin?: Date }
      ) => Promise<void>
    >("onMailChannelEnabled");

    it("marks the channel enabled and queues the merged pass carrying the granted floor", async () => {
      const { self, store, callbackCalls, runTaskCalls } = makeSelf({
        channels: [INBOX],
      });

      await onMailChannelEnabled.call(self, { id: ARCHIVE }, {
        syncHistoryMin: new Date("2020-01-01T00:00:00.000Z"),
      });

      expect(store.get(`mail:enabled_${ARCHIVE}`)).toBe(true);
      expect(callbackCalls).toEqual([
        [Apple.prototype.mailSyncTask, ARCHIVE, "2020-01-01T00:00:00.000Z"],
      ]);
      expect(runTaskCalls).toHaveLength(1);
    });

    it("is idempotent on re-dispatch: overwrites the marker and re-queues unconditionally", async () => {
      const { self, store, callbackCalls, runTaskCalls } = makeSelf({
        channels: [INBOX],
      });

      await onMailChannelEnabled.call(self, { id: INBOX });
      await onMailChannelEnabled.call(self, { id: INBOX });

      expect(store.get(`mail:enabled_${INBOX}`)).toBe(true);
      expect(callbackCalls).toEqual([
        [Apple.prototype.mailSyncTask, INBOX, null],
        [Apple.prototype.mailSyncTask, INBOX, null],
      ]);
      expect(runTaskCalls).toHaveLength(2);
    });
  });

  // I1 fix: the granted history floor must survive even when BOTH carriers
  // that would otherwise carry it are lost — the enabling task's own
  // callback argument (queue exhaustion) and a coalesced drain's frozen
  // `handlerArgs`. `MAIL_GRANTED_HISTORY_MIN_KEY` persists it independently
  // of `mail:state`, and every entry point that can run with no explicit
  // floor of its own (`mailSyncTask`'s fallback, `mailPoll`, `mailPushDrain`)
  // reads it back via `resolveMailHistoryMin`.
  describe("granted history floor persistence", () => {
    function privateMethod<T>(name: string): T {
      return (Apple.prototype as unknown as Record<string, T>)[name];
    }
    const onMailChannelEnabled = privateMethod<
      (
        channel: { id: string },
        context?: { syncHistoryMin?: Date }
      ) => Promise<void>
    >("onMailChannelEnabled");

    const GRANTED_KEY = "mail:granted_history_min";
    const WIDE = "2020-01-01T00:00:00.000Z";
    const NARROWER = "2025-06-01T00:00:00.000Z";

    it("onMailChannelEnabled persists the granted floor to its own key, independent of mail:state", async () => {
      const { self, store } = makeSelf({ channels: [INBOX] });

      await onMailChannelEnabled.call(self, { id: ARCHIVE }, {
        syncHistoryMin: new Date(WIDE),
      });

      expect(store.get(GRANTED_KEY)).toBe(WIDE);
    });

    it("never narrows the persisted granted floor on a later, narrower enable", async () => {
      const { self, store, callbackCalls } = makeSelf({ channels: [INBOX] });

      await onMailChannelEnabled.call(self, { id: INBOX }, {
        syncHistoryMin: new Date(WIDE),
      });
      await onMailChannelEnabled.call(self, { id: ARCHIVE }, {
        syncHistoryMin: new Date(NARROWER),
      });

      // The stored floor stays at the earlier (wider) value...
      expect(store.get(GRANTED_KEY)).toBe(WIDE);
      // ...and the second enable's queued task carries that same wide floor,
      // not the narrower value its own plan happened to report.
      expect(callbackCalls[1]).toEqual([
        Apple.prototype.mailSyncTask,
        ARCHIVE,
        WIDE,
      ]);
    });

    it("survives the enabling task being lost entirely: the next poll still uses the granted floor, not the 7-day default", async () => {
      const { self, store } = makeSelf({ channels: [INBOX] });

      // Enable persists the floor to its own key AND queues mailSyncTask —
      // simulate the queued task exhausting its retries (or acking on a
      // terminal auth error) by simply never invoking it. Only the
      // independent key survives.
      await onMailChannelEnabled.call(self, { id: INBOX }, {
        syncHistoryMin: new Date(WIDE),
      });
      expect(store.get(GRANTED_KEY)).toBe(WIDE);

      // The next scheduled connection-level poll runs with no floor of its
      // own — this is the "next poll" the fix is required to protect.
      await Apple.prototype.mailPoll.call(self);

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        [{ channelId: INBOX, mailbox: "INBOX" }],
        WIDE
      );
    });

    it("mailPushDrain also recovers the persisted granted floor when it carries no explicit one", async () => {
      const { self } = makeSelf({
        channels: [INBOX],
        acquireLockResult: true,
        initialStore: { [GRANTED_KEY]: WIDE },
      });

      await Apple.prototype.mailPushDrain.call(self, []);

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        [{ channelId: INBOX, mailbox: "INBOX" }],
        WIDE
      );
    });

    it("mailSyncTask falls back to the persisted granted floor, not the 7-day default, when its own argument is absent", async () => {
      const { self } = makeSelf({
        channels: [INBOX],
        acquireLockResult: true,
        initialStore: { [GRANTED_KEY]: WIDE },
      });

      await Apple.prototype.mailSyncTask.call(self, INBOX, null);

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        [{ channelId: INBOX, mailbox: "INBOX" }],
        WIDE
      );
    });

    it("falls back to the ~7-day default only when no floor was ever granted", async () => {
      const { self } = makeSelf({ channels: [INBOX] });
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;

      const before = Date.now();
      await Apple.prototype.mailPoll.call(self);
      const after = Date.now();

      const [, , floorArg] = vi.mocked(mailSync).mock.calls.at(-1)!;
      const floorMs = new Date(floorArg as string).getTime();
      // Bounded by [before, after] minus exactly 7 days — proves the default
      // really is ~7 days, not merely "some string" (a mutation to a
      // different span would still pass a looser `expect.any(String)` check).
      expect(floorMs).toBeGreaterThanOrEqual(before - sevenDaysMs);
      expect(floorMs).toBeLessThanOrEqual(after - sevenDaysMs);
    });
  });

  describe("enabledMailChannels", () => {
    it("enumerates only mail markers, and never mistakes a folder name containing ':' for a product prefix", async () => {
      const nested = "mail:Archive/2024";
      const colon = "mail:Notes:Work";
      const { self } = makeSelf({
        channels: [INBOX, nested, colon],
        initialStore: { "sync_enabled_calendar:/1/home/": true },
      });

      await Apple.prototype.mailPoll.call(self);

      expect(mailSync).toHaveBeenCalledWith(
        expect.anything(),
        [
          { channelId: nested, mailbox: "Archive/2024" },
          { channelId: INBOX, mailbox: "INBOX" },
          { channelId: colon, mailbox: "Notes:Work" },
        ],
        expect.any(String)
      );
    });
  });
});

describe("Apple calendar incremental sync", () => {
  const calendarHref = "calendar:/1234/calendars/home/";
  const rawHref = "/1234/calendars/home/";
  const lockKey = `sync_${calendarHref}`;

  /** Pulls a private method off `Apple.prototype` for use against a plain
   *  fake `self` — same rationale as `buildMailHost`/`armMailWatches`/
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
   * `mailSync`): these tests cover the
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

  it("FIX 3: prunes event_uids_/etags_ entries for hrefs the fast path reported deleted, leaving other entries intact", async () => {
    const getCollectionChanges = vi.fn(async () => ({
      token: "new-token",
      changed: [],
      deletedHrefs: ["/cal/d1.ics"],
    }));
    const { self, store } = makeSelf({
      storedToken: "old-token",
      getCollectionChanges,
      initialStore: {
        [`event_uids_${calendarHref}`]: {
          "/cal/d1.ics": "uid-1",
          "/cal/keep.ics": "uid-2",
        },
        [`etags_${calendarHref}`]: {
          "/cal/d1.ics": "etag-1",
          "/cal/keep.ics": "etag-2",
        },
      },
    });

    await startIncrementalSync.call(self, calendarHref);

    expect(store.get(`event_uids_${calendarHref}`)).toEqual({
      "/cal/keep.ics": "uid-2",
    });
    expect(store.get(`etags_${calendarHref}`)).toEqual({
      "/cal/keep.ics": "etag-2",
    });
  });

  it("FIX 3: a fast-path pass with no deletions leaves event_uids_/etags_ untouched", async () => {
    const getCollectionChanges = vi.fn(async () => ({
      token: "new-token",
      changed: [],
      deletedHrefs: [],
    }));
    const initialUids = { "/cal/keep.ics": "uid-2" };
    const initialEtags = { "/cal/keep.ics": "etag-2" };
    const { self, store } = makeSelf({
      storedToken: "old-token",
      getCollectionChanges,
      initialStore: {
        [`event_uids_${calendarHref}`]: initialUids,
        [`etags_${calendarHref}`]: initialEtags,
      },
    });

    await startIncrementalSync.call(self, calendarHref);

    expect(store.get(`event_uids_${calendarHref}`)).toEqual(initialUids);
    expect(store.get(`etags_${calendarHref}`)).toEqual(initialEtags);
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

describe("Apple.pollForChanges", () => {
  const calendarHref = "calendar:/1234/calendars/home/";

  /** Pulls a private method off `Apple.prototype` for use against a plain
   *  fake `self` — same rationale as the incremental-sync describe block's
   *  `privateMethod` above. */
  function privateMethod<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  /**
   * Fake self for `pollForChanges`. Unlike the incremental-sync describe
   * block above, `startIncrementalSync` is REPLACED with a plain spy
   * (never the real implementation) — these tests are about
   * `pollForChanges`'s own gating/error-handling logic (FIX 2 / FIX 5), not
   * the incremental-sync chain itself (already covered above), so a spy
   * keeps them focused and lets a test simulate an error from "deep in the
   * chain" without wiring up a full CalDAV fake.
   */
  function makeSelf(opts: {
    syncEnabled?: boolean;
    storedToken?: string;
    storedCtag?: string;
    getCalendarCtag?: (href: string) => Promise<string | null>;
    startIncrementalSyncImpl?: (calendarHref: string) => Promise<void>;
  }) {
    const store = new Map<string, unknown>(
      Object.entries({
        [`sync_enabled_${calendarHref}`]: opts.syncEnabled ?? true,
        ...(opts.storedToken !== undefined
          ? { [`synctoken_${calendarHref}`]: opts.storedToken }
          : {}),
        ...(opts.storedCtag !== undefined
          ? { [`ctag_${calendarHref}`]: opts.storedCtag }
          : {}),
      })
    );

    const getCalendarCtag = vi.fn(opts.getCalendarCtag ?? (async () => null));
    const startIncrementalSyncCalls: string[] = [];
    const startIncrementalSync = vi.fn(async (href: string) => {
      startIncrementalSyncCalls.push(href);
      if (opts.startIncrementalSyncImpl) await opts.startIncrementalSyncImpl(href);
    });
    const scheduleRecurringCalls: Array<{ key: string }> = [];
    const scheduleRecurring = vi.fn(async (key: string) => {
      scheduleRecurringCalls.push({ key });
    });
    const callback = vi.fn(async (fn: unknown, ...args: unknown[]) => ({ fn, args }));

    const self = {
      getCalDAV: () => ({ getCalendarCtag }),
      calDavHref: privateMethod("calDavHref"),
      startIncrementalSync,
      schedulePoll: privateMethod("schedulePoll"),
      callback,
      scheduleRecurring,
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
    } as unknown as Apple;

    return {
      self,
      store,
      getCalendarCtag,
      startIncrementalSync,
      startIncrementalSyncCalls,
      scheduleRecurringCalls,
    };
  }

  it("FIX 2: with a stored sync token, goes straight to startIncrementalSync — never PROPFINDs the ctag", async () => {
    const { self, getCalendarCtag, startIncrementalSyncCalls } = makeSelf({
      storedToken: "tok-1",
    });

    await Apple.prototype.pollForChanges.call(self, calendarHref);

    expect(getCalendarCtag).not.toHaveBeenCalled();
    expect(startIncrementalSyncCalls).toEqual([calendarHref]);
  });

  it("with no stored token and an unchanged ctag, does NOT run incremental sync (fallback gate preserved)", async () => {
    const { self, startIncrementalSync, scheduleRecurringCalls } = makeSelf({
      storedCtag: "ctag-A",
      getCalendarCtag: async () => "ctag-A",
    });

    await Apple.prototype.pollForChanges.call(self, calendarHref);

    expect(startIncrementalSync).not.toHaveBeenCalled();
    expect(scheduleRecurringCalls).toEqual([{ key: `poll:${calendarHref}` }]);
  });

  it("with no stored token and a changed ctag, runs incremental sync", async () => {
    const { self, startIncrementalSyncCalls } = makeSelf({
      storedCtag: "ctag-A",
      getCalendarCtag: async () => "ctag-B",
    });

    await Apple.prototype.pollForChanges.call(self, calendarHref);

    expect(startIncrementalSyncCalls).toEqual([calendarHref]);
  });

  it("bails without any work when the channel is disabled", async () => {
    const { self, getCalendarCtag, startIncrementalSync } = makeSelf({
      syncEnabled: false,
      storedToken: "tok-1",
    });

    await Apple.prototype.pollForChanges.call(self, calendarHref);

    expect(getCalendarCtag).not.toHaveBeenCalled();
    expect(startIncrementalSync).not.toHaveBeenCalled();
  });

  it("FIX 5: swallows an AuthenticationError instead of re-throwing, and still reschedules the poll", async () => {
    const { self, scheduleRecurringCalls } = makeSelf({
      storedToken: "tok-1",
      startIncrementalSyncImpl: async () => {
        throw new AuthenticationError();
      },
    });

    await expect(
      Apple.prototype.pollForChanges.call(self, calendarHref)
    ).resolves.toBeUndefined();

    expect(scheduleRecurringCalls).toEqual([{ key: `poll:${calendarHref}` }]);
  });

  it("still re-throws a genuinely unexpected (non-auth) error", async () => {
    const { self } = makeSelf({
      storedToken: "tok-1",
      startIncrementalSyncImpl: async () => {
        throw new Error("network blip");
      },
    });

    await expect(
      Apple.prototype.pollForChanges.call(self, calendarHref)
    ).rejects.toThrow("network blip");
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

describe("Apple mail teardown — onMailChannelDisabled + upgrade", () => {
  const INBOX = "mail:INBOX";
  const ARCHIVE = "mail:Archive";

  function priv<T>(name: string): T {
    return (Apple.prototype as unknown as Record<string, T>)[name];
  }

  const onMailChannelDisabled = priv<
    (channel: { id: string }) => Promise<void>
  >("onMailChannelDisabled");

  /**
   * Fake self for `onMailChannelDisabled` / `upgrade`. Copies the real
   * (private) `enabledMailChannels`, `teardownMailConnection` and
   * `scheduleMailPoll` onto a plain object (the same technique the
   * connection-level scheduling block above uses) and lets them run against a
   * real in-memory store, so a test observes the ACTUAL downstream effects —
   * which mailbox cursor got pruned, whether `mail:state` survived, whether a
   * connection-level drain was cancelled — rather than asserting against
   * stubbed spies. `channels` seeds the `mail:enabled_<id>` markers the
   * teardown enumerates to decide "is this the last enabled folder".
   */
  function makeSelf(opts: {
    channels?: string[];
    initialStore?: Record<string, unknown>;
  }) {
    const enabled = opts.channels ?? [INBOX];
    const store = new Map<string, unknown>(
      Object.entries({
        ...Object.fromEntries(enabled.map((id) => [`mail:enabled_${id}`, true])),
        ...opts.initialStore,
      })
    );
    const cancelScheduledTaskCalls: string[] = [];
    const cancelDrainCalls: string[] = [];
    const releaseLockCalls: string[] = [];
    const unwatchCalls: string[] = [];
    const deleteCallbackCalls: unknown[] = [];
    const archiveLinksCalls: unknown[] = [];
    const scheduleRecurringCalls: Array<{
      key: string;
      cb: unknown;
      options: unknown;
    }> = [];
    const callbackCalls: unknown[][] = [];

    const list = vi.fn(async (prefix: string) =>
      [...store.keys()].filter((k) => k.startsWith(prefix))
    );

    const self = {
      enabledMailChannels: priv<() => Promise<unknown>>("enabledMailChannels"),
      teardownMailConnection: priv<() => Promise<void>>(
        "teardownMailConnection"
      ),
      scheduleMailPoll: priv<() => Promise<void>>("scheduleMailPoll"),
      mailPoll: Apple.prototype.mailPoll,
      cancelScheduledTask: vi.fn(async (k: string) => {
        cancelScheduledTaskCalls.push(k);
      }),
      cancelDrain: vi.fn(async (k: string) => {
        cancelDrainCalls.push(k);
      }),
      deleteCallback: vi.fn(async (cb: unknown) => {
        deleteCallbackCalls.push(cb);
      }),
      callback: vi.fn(async (...args: unknown[]) => {
        callbackCalls.push(args);
        return { __callbackToken: true };
      }),
      scheduleRecurring: vi.fn(
        async (key: string, cb: unknown, options: unknown) => {
          scheduleRecurringCalls.push({ key, cb, options });
        }
      ),
      get: async (key: string) => store.get(key),
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      setMany: async (entries: [string, unknown][]) => {
        for (const [k, v] of entries) store.set(k, v);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
      tools: {
        imap: {
          unwatch: vi.fn(async (id: string) => {
            unwatchCalls.push(id);
          }),
        },
        integrations: {
          archiveLinks: vi.fn(async (arg: unknown) => {
            archiveLinksCalls.push(arg);
          }),
        },
        store: {
          list,
          releaseLock: vi.fn(async (k: string) => {
            releaseLockCalls.push(k);
          }),
        },
      },
    } as unknown as Apple;

    return {
      self,
      store,
      cancelScheduledTaskCalls,
      cancelDrainCalls,
      releaseLockCalls,
      unwatchCalls,
      deleteCallbackCalls,
      archiveLinksCalls,
      scheduleRecurringCalls,
      callbackCalls,
    };
  }

  describe("onMailChannelDisabled — one of several folders", () => {
    it("unwatches only the disabled channel, prunes only its cursor + homes, and leaves every connection-level primitive alone", async () => {
      const {
        self,
        store,
        cancelScheduledTaskCalls,
        cancelDrainCalls,
        releaseLockCalls,
        unwatchCalls,
        archiveLinksCalls,
      } = makeSelf({
        channels: [INBOX, ARCHIVE],
        initialStore: {
          "mail:state": {
            version: 2,
            boxes: {
              INBOX: { uidValidity: 1, lastUid: 10 },
              Archive: { uidValidity: 1, lastUid: 5 },
              "Sent Messages": { uidValidity: 1, lastUid: 0 },
            },
            syncHistoryMin: "2026-01-01T00:00:00.000Z",
          },
          // Homed to Archive (the disabled folder) -> re-home, keep bundle.
          "mail:thread:root-a@x.com": {
            channelId: ARCHIVE,
            bundle: { classified: null },
          },
          // Homed to INBOX (still enabled) -> untouched.
          "mail:thread:root-b@x.com": { channelId: INBOX },
          "mail:push_cb_mail:Archive": { __cb: true },
          // Connection-scoped sweep targets that MUST survive a non-last disable.
          "mail:compose:h1": {},
          "mail:writeback:read:root-b@x.com": { flag: "\\Seen", operation: "add" },
          "mail:flagged:root-b@x.com": true,
          "mail:cancel-email:evt-1": { at: "2026-01-01T00:00:00.000Z" },
        },
      });

      await onMailChannelDisabled.call(self, { id: ARCHIVE });

      // Only the disabled channel's watch is torn down.
      expect(unwatchCalls).toEqual([ARCHIVE]);
      expect(store.has("mail:push_cb_mail:Archive")).toBe(false);
      expect(store.has(`mail:enabled_${ARCHIVE}`)).toBe(false);
      expect(store.has(`mail:enabled_${INBOX}`)).toBe(true);

      // Only the disabled mailbox's cursor is pruned; the rest of the shared
      // document (INBOX + Sent cursors) is preserved and a full rescan armed.
      const state = store.get("mail:state") as {
        boxes: Record<string, unknown>;
        pendingFullRescan?: boolean;
      };
      expect(Object.keys(state.boxes).sort()).toEqual(["INBOX", "Sent Messages"]);
      expect(state.pendingFullRescan).toBe(true);

      // The thread homed to the disabled folder loses only its channelId,
      // keeping its bundle decision AND its presence (so the next pass re-homes
      // it without treating it as brand-new and clobbering read/archive state).
      expect(store.get("mail:thread:root-a@x.com")).toEqual({
        bundle: { classified: null },
      });
      // A thread homed to a still-enabled folder is untouched.
      expect(store.get("mail:thread:root-b@x.com")).toEqual({ channelId: INBOX });

      // NONE of the connection-level machinery is torn down.
      expect(cancelScheduledTaskCalls).not.toContain("mailpoll");
      expect(cancelDrainCalls).not.toContain("mail-push");
      expect(cancelDrainCalls).not.toContain("mail-sync");
      expect(cancelDrainCalls).not.toContain("mail-writeback");
      expect(releaseLockCalls).not.toContain("mail_sync");

      // NONE of the connection-scoped sweeps run.
      expect(store.has("mail:compose:h1")).toBe(true);
      expect(store.has("mail:writeback:read:root-b@x.com")).toBe(true);
      expect(store.has("mail:flagged:root-b@x.com")).toBe(true);
      expect(store.has("mail:cancel-email:evt-1")).toBe(true);

      // Archiving is precisely scoped to the disabled folder.
      expect(archiveLinksCalls).toEqual([
        {
          channelId: ARCHIVE,
          meta: { syncProvider: "apple-mail", syncableId: ARCHIVE },
        },
      ]);
    });

    it("does NOT resurrect a cleared to-do: a queued \\Flagged write-back + flagged marker on an INBOX thread survive disabling Archive", async () => {
      // The reported data-loss bug: the old teardown cancelled the shared
      // mail-writeback drain and wiped mail:flagged:* on ANY folder's disable.
      // With INBOX still enabled, a pending write-back and its echo-break
      // marker for an INBOX thread must be untouched — otherwise the next pass
      // reads wasFlagged=undefined, sees IMAP \Flagged still set, and re-marks
      // the thread a to-do (resurrecting a to-do the user just cleared).
      const { self, store, cancelDrainCalls } = makeSelf({
        channels: [INBOX, ARCHIVE],
        initialStore: {
          "mail:flagged:inbox-root@x.com": true,
          "mail:writeback:todo:inbox-root@x.com": {
            flag: "\\Flagged",
            operation: "remove",
          },
        },
      });

      await onMailChannelDisabled.call(self, { id: ARCHIVE });

      expect(store.get("mail:flagged:inbox-root@x.com")).toBe(true);
      expect(store.get("mail:writeback:todo:inbox-root@x.com")).toEqual({
        flag: "\\Flagged",
        operation: "remove",
      });
      expect(cancelDrainCalls).not.toContain("mail-writeback");
    });
  });

  describe("onMailChannelDisabled — the last folder", () => {
    it("tears down every connection-level primitive, deletes mail:state, and sweeps per-connection markers — but keeps auth_actor_id and the granted history floor", async () => {
      const {
        self,
        store,
        cancelScheduledTaskCalls,
        cancelDrainCalls,
        releaseLockCalls,
        unwatchCalls,
        archiveLinksCalls,
      } = makeSelf({
        channels: [INBOX],
        initialStore: {
          "mail:state": {
            version: 2,
            boxes: { INBOX: { uidValidity: 1, lastUid: 10 } },
          },
          "mail:push_cb_mail:INBOX": { __cb: true },
          "mail:compose:h1": {},
          "mail:forward:h2": {},
          "mail:writeback:read:r": { flag: "\\Seen", operation: "add" },
          "mail:flagged:r": true,
          "mail:cancel-email:evt-1": { at: "2026-01-01T00:00:00.000Z" },
          "mail:thread:r": { channelId: INBOX },
          // Connection-scoped facts that MUST survive a full disable so a later
          // reconnect/re-enable finds them again.
          "mail:auth_actor_id": "actor-123",
          "mail:granted_history_min": "2025-07-01T00:00:00.000Z",
        },
      });

      await onMailChannelDisabled.call(self, { id: INBOX });

      expect(unwatchCalls).toEqual([INBOX]);
      expect(cancelScheduledTaskCalls).toContain("mailpoll");
      expect(cancelDrainCalls).toEqual(
        expect.arrayContaining(["mail-push", "mail-sync", "mail-writeback"])
      );
      expect(releaseLockCalls).toContain("mail_sync");

      // The whole cursor document is reclaimed (it's the only place Sent's
      // channel-less cursor could be freed).
      expect(store.has("mail:state")).toBe(false);

      // Every per-connection marker is swept.
      for (const key of [
        "mail:compose:h1",
        "mail:forward:h2",
        "mail:writeback:read:r",
        "mail:flagged:r",
        "mail:cancel-email:evt-1",
        "mail:thread:r",
      ]) {
        expect(store.has(key)).toBe(false);
      }

      // Connection-scoped facts survive.
      expect(store.get("mail:auth_actor_id")).toBe("actor-123");
      expect(store.get("mail:granted_history_min")).toBe(
        "2025-07-01T00:00:00.000Z"
      );

      expect(archiveLinksCalls).toEqual([
        {
          channelId: INBOX,
          meta: { syncProvider: "apple-mail", syncableId: INBOX },
        },
      ]);
    });
  });

  describe("upgrade — migrate off the legacy per-channel state shape", () => {
    it("clears legacy state, cancels legacy per-channel scheduling, migrates the widest floor, seeds thread homes from flagged roots, and arms the connection poll", async () => {
      const { self, store, cancelScheduledTaskCalls, cancelDrainCalls, releaseLockCalls, scheduleRecurringCalls } =
        makeSelf({
          channels: [INBOX, ARCHIVE],
          initialStore: {
            "mail:state_mail:INBOX": { uidValidity: 1, lastUid: 10 },
            "mail:sync_history_min_mail:INBOX": "2025-01-01T00:00:00.000Z",
            "mail:sync_history_min_mail:Archive": "2024-06-01T00:00:00.000Z",
            "mail:bundle:root-x@x.com": { classified: null },
            "mail:flagged:root-x@x.com": true,
            "mail:flagged:root-y@x.com": false,
          },
        });

      await Apple.prototype.upgrade.call(self);

      // Legacy per-channel cursor + history + bundle keys are gone.
      expect(store.has("mail:state_mail:INBOX")).toBe(false);
      expect(store.has("mail:sync_history_min_mail:INBOX")).toBe(false);
      expect(store.has("mail:sync_history_min_mail:Archive")).toBe(false);
      expect(store.has("mail:bundle:root-x@x.com")).toBe(false);

      // The widest (earliest) legacy floor is carried into mail:state.
      const state = store.get("mail:state") as { syncHistoryMin?: string };
      expect(state.syncHistoryMin).toBe("2024-06-01T00:00:00.000Z");

      // Every previously-synced root (enumerated by mail:flagged:) is seeded as
      // "known" so the first merged pass doesn't treat it as an initial ingest
      // and mass mark-read / un-archive it.
      expect(store.has("mail:thread:root-x@x.com")).toBe(true);
      expect(store.has("mail:thread:root-y@x.com")).toBe(true);

      // Legacy per-channel scheduling is cancelled for every enabled channel.
      expect(cancelScheduledTaskCalls).toEqual(
        expect.arrayContaining(["mailpoll:mail:INBOX", "mailpoll:mail:Archive"])
      );
      expect(cancelDrainCalls).toEqual(
        expect.arrayContaining(["mail-push:mail:INBOX", "mail-push:mail:Archive"])
      );
      expect(releaseLockCalls).toEqual(
        expect.arrayContaining(["mail_sync_mail:INBOX", "mail_sync_mail:Archive"])
      );

      // The connection-level poll is armed exactly once.
      expect(
        scheduleRecurringCalls.filter((c) => c.key === "mailpoll")
      ).toHaveLength(1);
    });
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
