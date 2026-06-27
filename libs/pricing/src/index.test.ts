import { describe, expect, it } from "vitest";

import {
  PLAN,
  PLAN_PRICES,
  TEAM_SLOTS_PER_GROUP,
  TWIST_ADDON_BLOCK_SIZE,
  CONNECTION_ADDON_PRICE,
  TWIST_ADDON_PRICE,
} from "./index";

describe("pricing constants", () => {
  it("has the adjusted values", () => {
    expect(PLAN.free.twistCapacity).toBe(1);
    expect(PLAN.pro.twistCapacity).toBe(3);
    expect(PLAN.free.connections).toBe(2);
    expect(PLAN.pro.connections).toBe(Infinity);
    expect(TEAM_SLOTS_PER_GROUP).toBe(50);
    expect(TWIST_ADDON_BLOCK_SIZE).toBe(5);
    expect(CONNECTION_ADDON_PRICE).toBe(5);
    expect(TWIST_ADDON_PRICE).toBe(10);
    expect(PLAN_PRICES.pro).toEqual({ monthly: 25, annual: 20 });
    expect(PLAN_PRICES.team).toEqual({ monthly: 124, annual: 99 });
  });
});
