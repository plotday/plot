import { describe, expect, it } from "vitest";

import type { LinkKind, LinkTypeConfig } from "./integrations";

describe("LinkTypeConfig.kind", () => {
  it("accepts each declared kind", () => {
    const kinds: LinkKind[] = ["calendar", "task", "team-task", "message"];
    const configs: LinkTypeConfig[] = kinds.map((kind) => ({
      type: "example",
      label: "Example",
      kind,
    }));
    expect(configs.map((c) => c.kind)).toEqual(kinds);
  });

  it("leaves kind optional so existing connectors still type-check", () => {
    const config: LinkTypeConfig = { type: "example", label: "Example" };
    expect(config.kind).toBeUndefined();
  });
});
