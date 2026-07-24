import { describe, expect, it, vi } from "vitest";

import { PreconditionFailedError } from "../calendar/caldav";
import { onCreateLinkFn, onLinkUpdatedFn } from "./write";
import type { RemindersHost } from "./sync";
import type { CreateLinkDraft } from "@plotday/twister/connector";
import type { Link } from "@plotday/twister";

function makeHost(caldavOverrides: Record<string, unknown> = {}): RemindersHost {
  return {
    id: "conn-1",
    caldav: {
      updateEventICS: vi.fn().mockResolvedValue(true),
      fetchEventICS: vi.fn(),
      ...caldavOverrides,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any,
    set: vi.fn(),
    get: vi.fn(),
    clear: vi.fn(),
    setMany: vi.fn(),
    tools: {
      integrations: {
        saveLink: vi.fn(),
        channelSyncCompleted: vi.fn(),
        archiveLinks: vi.fn(),
      },
    },
    scheduler: { schedulePoll: vi.fn(), cancelPoll: vi.fn(), queueFullSync: vi.fn() },
  };
}

const DRAFT: CreateLinkDraft = {
  channelId: "reminders:/289842362/tasks/home/",
  type: "reminder",
  status: "open",
  title: "Buy milk",
  noteContent: "2%",
  contacts: [],
};

describe("onCreateLinkFn", () => {
  it("returns null for a non-reminder draft", async () => {
    const host = makeHost();
    expect(await onCreateLinkFn(host, { ...DRAFT, type: "email" })).toBeNull();
  });

  it("PUTs a new VTODO to the de-namespaced list href and returns an open reminder link", async () => {
    const host = makeHost();
    const link = await onCreateLinkFn(host, DRAFT);

    expect(link).toMatchObject({
      type: "reminder",
      title: "Buy milk",
      status: "open",
      todo: true,
      channelId: "reminders:/289842362/tasks/home/",
    });
    expect(link?.source).toMatch(/^icloud-reminders:reminder:/);

    const [href, icsData] = (host.caldav.updateEventICS as ReturnType<typeof vi.fn>).mock
      .calls[0];
    expect(href).toMatch(/^\/289842362\/tasks\/home\/[^/]+\.ics$/);
    expect(icsData).toContain("SUMMARY:Buy milk");
    expect(icsData).toContain("DESCRIPTION:2%");
    expect(icsData).toContain("STATUS:NEEDS-ACTION");
  });

  it("sets STATUS:COMPLETED and omits todo when composed already-done", async () => {
    const host = makeHost();
    const link = await onCreateLinkFn(host, { ...DRAFT, status: "done" });

    expect(link).not.toHaveProperty("todo");
    const [, icsData] = (host.caldav.updateEventICS as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(icsData).toContain("STATUS:COMPLETED");
  });

  it("returns null when the PUT fails", async () => {
    const host = makeHost({ updateEventICS: vi.fn().mockResolvedValue(false) });
    expect(await onCreateLinkFn(host, DRAFT)).toBeNull();
  });
});

const BASE_LINK = {
  id: "link-1",
  meta: { todoUid: "abc-123", listId: "reminders:/289842362/tasks/home/" },
  status: "done",
} as unknown as Link;

describe("onLinkUpdatedFn", () => {
  it("no-ops when the link carries no todoUid/listId meta", async () => {
    const host = makeHost();
    await onLinkUpdatedFn(host, { ...BASE_LINK, meta: {} } as unknown as Link);
    expect(host.caldav.fetchEventICS).not.toHaveBeenCalled();
  });

  it("no-ops when the reminder was deleted upstream (fetchEventICS returns null)", async () => {
    const host = makeHost({ fetchEventICS: vi.fn().mockResolvedValue(null) });
    await onLinkUpdatedFn(host, BASE_LINK);
    expect(host.caldav.updateEventICS).not.toHaveBeenCalled();
  });

  it("marks the VTODO COMPLETED with a timestamp when the link's status is done", async () => {
    const host = makeHost({
      fetchEventICS: vi.fn().mockResolvedValue({
        icsData: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:abc-123\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR",
        etag: "etag-1",
      }),
    });

    await onLinkUpdatedFn(host, BASE_LINK);

    const [href, icsData, etag] = (host.caldav.updateEventICS as ReturnType<typeof vi.fn>).mock
      .calls[0];
    expect(href).toBe("/289842362/tasks/home/abc-123.ics");
    expect(icsData).toContain("STATUS:COMPLETED");
    expect(icsData).toMatch(/COMPLETED:\d{8}T\d{6}Z/);
    expect(etag).toBe("etag-1");
  });

  it("reopens: sets NEEDS-ACTION and drops any prior COMPLETED line", async () => {
    const host = makeHost({
      fetchEventICS: vi.fn().mockResolvedValue({
        icsData: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:abc-123\r\nSTATUS:COMPLETED\r\nCOMPLETED:20260810T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR",
        etag: "etag-1",
      }),
    });

    await onLinkUpdatedFn(host, { ...BASE_LINK, status: "open" } as unknown as Link);

    const [, icsData] = (host.caldav.updateEventICS as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(icsData).toContain("STATUS:NEEDS-ACTION");
    expect(icsData).not.toContain("COMPLETED:");
  });

  it("on a concurrent-edit conflict, re-fetches and retries once with the fresh etag", async () => {
    const fetchEventICS = vi
      .fn()
      .mockResolvedValueOnce({
        icsData: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:abc-123\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR",
        etag: "stale-etag",
      })
      .mockResolvedValueOnce({
        icsData: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:abc-123\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR",
        etag: "fresh-etag",
      });
    const updateEventICS = vi
      .fn()
      .mockRejectedValueOnce(new PreconditionFailedError())
      .mockResolvedValueOnce(true);
    const host = makeHost({ fetchEventICS, updateEventICS });

    await onLinkUpdatedFn(host, BASE_LINK);

    expect(fetchEventICS).toHaveBeenCalledTimes(2);
    expect(updateEventICS).toHaveBeenCalledTimes(2);
    const [, , secondEtag] = updateEventICS.mock.calls[1];
    expect(secondEtag).toBe("fresh-etag");
  });
});
