import { afterEach, describe, expect, it, vi } from "vitest";

import type { AuthToken } from "@plotday/twister/tools/integrations";

import { CALENDAR_LIST_SCOPE, getCalendarChannels } from "./channels";

function stubCalendarList(
  items: Array<{
    id: string;
    summary: string;
    primary?: boolean;
    accessRole?: string;
  }>
) {
  const spy = vi.fn(
    async () =>
      new Response(JSON.stringify({ items }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
  );
  vi.stubGlobal("fetch", spy);
  return spy;
}

function token(scopes: string[] = [CALENDAR_LIST_SCOPE]): AuthToken {
  return { token: "test-token", scopes };
}

describe("getCalendarChannels", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("enables only the user's own primary calendar by default", async () => {
    stubCalendarList([
      { id: "erin@artemiscanada.com", summary: "erin@artemiscanada.com", primary: true, accessRole: "owner" },
    ]);

    const channels = await getCalendarChannels(token());

    expect(channels).toEqual([
      { id: "erin@artemiscanada.com", title: "erin@artemiscanada.com", enabledByDefault: true },
    ]);
  });

  it("does NOT enable a colleague's calendar shared at owner-level ACL", async () => {
    // Regression: Workspace domains commonly grant "owner"-tier internal
    // sharing on every user's calendar. accessRole === "owner" alone must
    // not be treated as "this is my calendar" — only `primary` may.
    stubCalendarList([
      { id: "erin@artemiscanada.com", summary: "erin@artemiscanada.com", primary: true, accessRole: "owner" },
      { id: "alex@artemiscanada.com", summary: "alex@artemiscanada.com", primary: false, accessRole: "owner" },
    ]);

    const channels = await getCalendarChannels(token());

    expect(channels).toEqual([
      { id: "erin@artemiscanada.com", title: "erin@artemiscanada.com", enabledByDefault: true },
      { id: "alex@artemiscanada.com", title: "alex@artemiscanada.com", enabledByDefault: false },
    ]);
  });

  it("does not enable a non-owned shared or subscribed calendar", async () => {
    stubCalendarList([
      { id: "erin@artemiscanada.com", summary: "erin@artemiscanada.com", primary: true, accessRole: "owner" },
      { id: "en.canadian#holiday@group.v.calendar.google.com", summary: "Holidays in Canada", primary: false, accessRole: "reader" },
    ]);

    const channels = await getCalendarChannels(token());

    expect(channels.find((c) => c.title === "Holidays in Canada")).toEqual({
      id: "en.canadian#holiday@group.v.calendar.google.com",
      title: "Holidays in Canada",
      enabledByDefault: false,
    });
  });

  it("returns a single enabled 'primary' fallback channel without CALENDAR_LIST_SCOPE", async () => {
    const channels = await getCalendarChannels(token([]));

    expect(channels).toEqual([{ id: "primary", title: "Calendar", enabledByDefault: true }]);
  });
});
