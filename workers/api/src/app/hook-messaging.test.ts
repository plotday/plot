import { describe, it, expect } from "vitest";
import { classifyEvent } from "./hook-messaging-classify";

// classifyEvent maps Unipile v2 dot-notation event names (carried in `type`)
// onto Plot's internal dispatch kinds. v1 names + the hosted-auth `status`
// shape are kept as fallbacks during the cutover.
describe("classifyEvent (v2)", () => {
  it("maps message.new to messaging.new_message", () => {
    expect(classifyEvent({ type: "message.new" })).toBe("messaging.new_message");
  });

  it("maps account.add and account.reconnect to account.connected", () => {
    expect(classifyEvent({ type: "account.add" })).toBe("account.connected");
    expect(classifyEvent({ type: "account.reconnect" })).toBe("account.connected");
  });

  it("maps account.status.disconnected/errored to account.needs_reauth", () => {
    expect(classifyEvent({ type: "account.status.disconnected" })).toBe("account.needs_reauth");
    expect(classifyEvent({ type: "account.status.errored" })).toBe("account.needs_reauth");
  });

  it("maps relation.new and relation.request.accept to new_relation", () => {
    expect(classifyEvent({ type: "relation.new" })).toBe("users.new_relation");
    expect(classifyEvent({ type: "relation.request.accept" })).toBe("users.new_relation");
  });

  it("still honors v1 event_type names and the hosted-auth status shape", () => {
    expect(classifyEvent({ event_type: "messaging.new_message" })).toBe("messaging.new_message");
    expect(classifyEvent({ status: "CREATION_SUCCESS" })).toBe("account.connected");
    expect(classifyEvent({ status: "CREDENTIALS" })).toBe("account.needs_reauth");
  });

  it("returns null for unknown events", () => {
    expect(classifyEvent({ type: "something.else" })).toBeNull();
    expect(classifyEvent({})).toBeNull();
  });
});
