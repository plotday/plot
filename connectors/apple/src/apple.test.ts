import { describe, expect, it } from "vitest";

import { Apple } from "./apple";
import { composeChannels } from "./compose";
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
