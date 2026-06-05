import { describe, it, expect } from "vitest";
import { isActiveConnection } from "./active-connection";

describe("isActiveConnection", () => {
  it("is active: committed, not archived, has an enabled channel", () => {
    expect(
      isActiveConnection({ draft: false, archived: false, enabledChannelCount: 1 }),
    ).toBe(true);
  });

  it("not active: still a draft (OAuth not yet committed)", () => {
    expect(
      isActiveConnection({ draft: true, archived: false, enabledChannelCount: 1 }),
    ).toBe(false);
  });

  it("not active: archived", () => {
    expect(
      isActiveConnection({ draft: false, archived: true, enabledChannelCount: 1 }),
    ).toBe(false);
  });

  it("not active: zero enabled channels (orphaned OAuth with no channels picked)", () => {
    expect(
      isActiveConnection({ draft: false, archived: false, enabledChannelCount: 0 }),
    ).toBe(false);
  });
});
