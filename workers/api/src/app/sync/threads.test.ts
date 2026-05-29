import { describe, it, expect } from "vitest";

import { isDispatchableCreateLink } from "./threads";

describe("isDispatchableCreateLink", () => {
  it("dispatches channel-mode compose (all fields present)", () => {
    expect(
      isDispatchableCreateLink({
        twist_instance_id: "ti",
        channel_id: "INBOX",
        type: "issue",
        status: "unstarted",
      }),
    ).toBe(true);
  });

  it("dispatches address-mode compose when channel_id is null (Gmail)", () => {
    // Gmail's `email` link type declares compose.targets: "addresses", so the
    // Flutter client sends channel_id: null — the connector picks its own
    // channel in onCreateLink. This must still dispatch.
    expect(
      isDispatchableCreateLink({
        twist_instance_id: "ti",
        channel_id: null,
        type: "email",
        status: "sent",
      }),
    ).toBe(true);
  });

  it("dispatches contacts-mode compose when channel_id is undefined (Slack DM)", () => {
    expect(
      isDispatchableCreateLink({
        twist_instance_id: "ti",
        type: "dm",
        status: "sent",
      }),
    ).toBe(true);
  });

  it("does not dispatch without twist_instance_id", () => {
    expect(
      isDispatchableCreateLink({ type: "email", status: "sent" }),
    ).toBe(false);
  });

  it("does not dispatch without type", () => {
    expect(
      isDispatchableCreateLink({ twist_instance_id: "ti", status: "sent" }),
    ).toBe(false);
  });

  it("does not dispatch without status", () => {
    expect(
      isDispatchableCreateLink({ twist_instance_id: "ti", type: "email" }),
    ).toBe(false);
  });

  it("does not dispatch when spec is undefined", () => {
    expect(isDispatchableCreateLink(undefined)).toBe(false);
  });
});
