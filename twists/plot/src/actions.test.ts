import { describe, expect, it } from "vitest";
import { ActionType } from "@plotday/twister";

import { buildActions } from "./actions";

describe("buildActions", () => {
  it("caps thread actions at 3 and skips the current thread", () => {
    const ids = new Set(["cur", "a", "b", "c", "d"]);
    const actions = buildActions(ids, "cur");
    expect(actions).toHaveLength(3);
    expect(actions.every((a) => a.type === ActionType.thread)).toBe(true);
  });

  it("adds up to 5 url sources as external actions", () => {
    const sources = Array.from({ length: 7 }, (_, i) => ({
      type: "source" as const,
      sourceType: "url" as const,
      id: `s${i}`,
      url: `https://x.test/${i}`,
      title: `S${i}`,
    }));
    const actions = buildActions(new Set(), "cur", sources as any);
    expect(actions).toHaveLength(5);
    expect(actions[0]).toMatchObject({ type: ActionType.external, url: "https://x.test/0" });
  });
});
