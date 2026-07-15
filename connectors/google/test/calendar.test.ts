import { describe, it, expect, vi, afterEach } from "vitest";
import type { AuthToken } from "@plotday/twister/tools/integrations";
import { CALENDAR_EVENTS_SCOPE } from "../src/calendar/channels";
import { calendarProduct } from "../src/products/calendar";
import { PRODUCTS_BY_KEY } from "../src/products/product";
import { composeChannels } from "../src/compose";

function makeToken(scopes: string[]): AuthToken {
  return {
    accessToken: "fake",
    token: "fake-token",
    scopes,
  } as unknown as AuthToken;
}

describe("calendarProduct", () => {
  it("requiredScopes equals [CALENDAR_EVENTS_SCOPE]", () => {
    expect(calendarProduct.requiredScopes).toEqual([CALENDAR_EVENTS_SCOPE]);
  });

  it("linkTypes contains an event type with includesSchedules === true", () => {
    const eventType = calendarProduct.linkTypes.find((lt) => lt.type === "event");
    expect(eventType).toBeDefined();
    expect(eventType?.includesSchedules).toBe(true);
  });

  describe("getRawChannels — primary fallback (no CALENDAR_LIST_SCOPE)", () => {
    it("returns a single primary channel when only CALENDAR_EVENTS_SCOPE is granted", async () => {
      // No CALENDAR_LIST_SCOPE → no network call, single primary fallback
      const token = makeToken([CALENDAR_EVENTS_SCOPE]);
      const channels = await calendarProduct.getRawChannels(token);
      expect(channels).toHaveLength(1);
      expect(channels[0].id).toBe("primary");
    });
  });

  describe("composeChannels wires calendar product end-to-end", () => {
    afterEach(() => {
      vi.unstubAllGlobals();
    });

    it("yields a channel with id 'calendar:primary' and linkTypes attached", async () => {
      const token = makeToken([CALENDAR_EVENTS_SCOPE]);
      const channels = await composeChannels(Object.values(PRODUCTS_BY_KEY), token);

      const primary = channels.find((c) => c.id === "calendar:primary");
      expect(primary).toBeDefined();
      expect(primary?.linkTypes).toBeDefined();
      expect(primary?.linkTypes?.some((lt) => lt.type === "event")).toBe(true);
    });
  });

  describe("PRODUCTS_BY_KEY", () => {
    it("contains 'calendar' key pointing to calendarProduct", () => {
      expect(PRODUCTS_BY_KEY.calendar).toBe(calendarProduct);
    });
  });
});
