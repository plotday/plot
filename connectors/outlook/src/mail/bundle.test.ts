import { describe, expect, it, vi } from "vitest";

import type { NewLinkWithNotes } from "@plotday/twister/plot";

import type { GraphAttachmentMeta, GraphHeader, GraphMessage } from "./graph-mail-api";
import { type OutlookMailSyncHost, processConversationsFn } from "./sync";

/**
 * Wiring test for calendar-thread bundling: `processConversationsFn`
 * classifies each conversation via `classifyOutlookCalendar` (pure logic
 * covered exhaustively in graph-mail-api.test.ts) and, on a match, appends
 * `icaluid:<uid>` to the saved link's `sources` — plus records a
 * `cancel-email:<uid>` marker for cancellations. `processConversationsFn`
 * takes already-fetched `ConversationItem`s directly (messages +
 * attachments + parentHeaders), so no Graph API mocking is needed here —
 * only a host stub.
 */

function makeHost(): {
  host: OutlookMailSyncHost;
  map: Map<string, unknown>;
  saved: NewLinkWithNotes[];
} {
  const map = new Map<string, unknown>([
    ["user_email", "me@work.com"],
    ["wellknown_folders", { inbox: "inbox-folder" }],
  ]);
  const saved: NewLinkWithNotes[] = [];
  const host = {
    id: "twist-instance-1",
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      map.set(key, value);
    }),
    setMany: vi.fn(async (entries: [string, unknown][]) => {
      for (const [key, value] of entries) map.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      map.delete(key);
    }),
    tools: {
      integrations: {
        // No token → contact enrichment is skipped (best-effort, non-blocking).
        get: vi.fn(async () => null),
        saveLink: vi.fn(async (link: NewLinkWithNotes) => {
          saved.push(link);
          return "T";
        }),
        setThreadToDo: vi.fn(async () => {}),
      },
    },
  } as unknown as OutlookMailSyncHost;
  return { host, map, saved };
}

/** A single non-draft, non-meeting message with the fields the transform needs. */
function baseMessage(over: Partial<GraphMessage> = {}): GraphMessage {
  return {
    id: "msg-1",
    conversationId: "conv-1",
    internetMessageId: "<msg-1@x>",
    subject: "Weekly sync",
    bodyPreview: "preview",
    body: { contentType: "text", content: "Body" },
    from: { emailAddress: { name: "Ann", address: "ann@x.com" } },
    toRecipients: [{ emailAddress: { name: "Me", address: "me@work.com" } }],
    receivedDateTime: "2026-06-01T10:00:00Z",
    isRead: true,
    isDraft: false,
    parentFolderId: "inbox-folder",
    ...over,
  };
}

const emptyAttachments = new Map<string, GraphAttachmentMeta[]>();

describe("processConversationsFn — calendar-thread bundling", () => {
  it("adds icaluid:<uid> to sources when the conversation is a calendar update", async () => {
    const { host, saved } = makeHost();
    const item = {
      messages: [
        baseMessage({
          meetingMessageType: "meetingRequest",
          meetingRequestType: "fullUpdate",
          event: { iCalUId: "uid-1" },
        }),
      ],
      attachmentsByMessageId: emptyAttachments,
      parentHeaders: null as GraphHeader[] | null,
    };

    await processConversationsFn(host, [item], false, "inbox-folder");

    expect(saved).toHaveLength(1);
    expect(saved[0].sources).toContain("icaluid:uid-1");
  });

  it("records a cancel-email marker for a cancellation email", async () => {
    const { host, map } = makeHost();
    const item = {
      messages: [
        baseMessage({
          id: "msg-2",
          internetMessageId: "<msg-2@x>",
          conversationId: "conv-2",
          meetingMessageType: "meetingCancelled",
          event: { iCalUId: "uid-2" },
        }),
      ],
      attachmentsByMessageId: emptyAttachments,
      parentHeaders: null as GraphHeader[] | null,
    };

    await processConversationsFn(host, [item], false, "inbox-folder");

    expect(map.get("cancel-email:uid-2")).toBeTruthy();
  });

  it("bundles a Plot-sent reply chain via the X-Plot-Event-UID parent header", async () => {
    const { host, saved } = makeHost();
    const item = {
      messages: [
        baseMessage({
          id: "msg-3",
          internetMessageId: "<msg-3@x>",
          conversationId: "conv-3",
        }),
      ],
      attachmentsByMessageId: emptyAttachments,
      parentHeaders: [
        { name: "X-Plot-Event-UID", value: "uid-3" },
      ] as GraphHeader[] | null,
    };

    await processConversationsFn(host, [item], false, "inbox-folder");

    expect(saved).toHaveLength(1);
    expect(saved[0].sources).toContain("icaluid:uid-3");
  });

  it("does not add icaluid sources for a plain conversation with no calendar signal", async () => {
    const { host, saved } = makeHost();
    const item = {
      messages: [
        baseMessage({
          id: "msg-4",
          internetMessageId: "<msg-4@x>",
          conversationId: "conv-4",
        }),
      ],
      attachmentsByMessageId: emptyAttachments,
      parentHeaders: null as GraphHeader[] | null,
    };

    await processConversationsFn(host, [item], false, "inbox-folder");

    expect(saved).toHaveLength(1);
    expect(saved[0].sources ?? []).not.toEqual(
      expect.arrayContaining([expect.stringMatching(/^icaluid:/)])
    );
  });
});
