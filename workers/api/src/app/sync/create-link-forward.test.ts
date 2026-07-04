import { describe, it, expect } from "vitest";
import { decideForward } from "./create-link-dispatch";

describe("decideForward", () => {
  const src = { key: "msg-1", sourceConnectionId: "conn-A", supportsForward: true };

  it("native when same connection + supportsForward", () => {
    expect(decideForward(src, "conn-A")).toEqual({ mode: "native", key: "msg-1" });
  });
  it("fallback when connection differs", () => {
    expect(decideForward(src, "conn-B")).toEqual({ mode: "fallback" });
  });
  it("fallback when link type lacks supportsForward", () => {
    expect(decideForward({ ...src, supportsForward: false }, "conn-A")).toEqual({ mode: "fallback" });
  });
  it("fallback when target is plain Plot (no connection)", () => {
    expect(decideForward(src, null)).toEqual({ mode: "fallback" });
  });
});
