import { describe, expect, it, vi } from "vitest";

import { REMINDERS_LINK_TYPES, getReminderChannels } from "./channels";
import type { CalDAVClient } from "../calendar/caldav";

function fakeClient(overrides: Partial<CalDAVClient> = {}): CalDAVClient {
  return {
    listCalendarsByComponent: vi.fn().mockResolvedValue([
      { href: "/289842362/tasks/home/", displayName: "Reminders", ctag: null },
      { href: "/289842362/tasks/work/", displayName: "Work", ctag: null },
    ]),
    discoverDefaultTasksListHref: vi.fn().mockResolvedValue(null),
    ...overrides,
  } as unknown as CalDAVClient;
}

describe("REMINDERS_LINK_TYPES", () => {
  const reminder = REMINDERS_LINK_TYPES.find((t) => t.type === "reminder");

  it("has no sharing roster (personal to-dos, like Google Tasks)", () => {
    expect(reminder?.sharingModel).toBe("none");
  });

  it("declares open/done statuses with done marked as completion", () => {
    const byStatus = Object.fromEntries((reminder?.statuses ?? []).map((s) => [s.status, s]));
    expect(byStatus["open"]).toBeTruthy();
    expect(byStatus["done"].done).toBe(true);
  });

  it("is composable, defaulting new reminders to open", () => {
    expect(reminder?.compose?.status).toBe("open");
  });
});

describe("getReminderChannels", () => {
  it("lists VTODO collections as channels, un-namespaced", async () => {
    const client = fakeClient();
    const channels = await getReminderChannels(client, "/289842362/", "/289842362/");

    expect(channels).toEqual([
      { id: "/289842362/tasks/home/", title: "Reminders" },
      { id: "/289842362/tasks/work/", title: "Work" },
    ]);
    expect(client.listCalendarsByComponent).toHaveBeenCalledWith("/289842362/", "VTODO");
  });

  it("marks the discovered default list enabledByDefault", async () => {
    const client = fakeClient({
      discoverDefaultTasksListHref: vi.fn().mockResolvedValue("/289842362/tasks/home/"),
    });
    const channels = await getReminderChannels(client, "/289842362/", "/289842362/");

    expect(channels.find((c) => c.id === "/289842362/tasks/home/")?.enabledByDefault).toBe(true);
    expect(channels.find((c) => c.id === "/289842362/tasks/work/")?.enabledByDefault).toBeUndefined();
  });

  it("degrades to opt-in-only (no enabledByDefault) when default discovery fails", async () => {
    const client = fakeClient({
      discoverDefaultTasksListHref: vi.fn().mockRejectedValue(new Error("403")),
    });
    const channels = await getReminderChannels(client, "/289842362/", "/289842362/");

    expect(channels.every((c) => c.enabledByDefault === undefined)).toBe(true);
  });
});
