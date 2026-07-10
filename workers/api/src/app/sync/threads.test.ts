import { describe, it, expect, vi } from "vitest";

import {
  isDispatchableCreateLink,
  computeThreadEmbedding,
  classifyIconFilter,
  PLOT_ICON_URL,
} from "./threads";

describe("classifyIconFilter", () => {
  it("classifies the Plot bucket without sweeping it into the link bucket", () => {
    // The reported bug: browsing thread type = "Plot". The Plot icon URL is
    // itself an http URL, so a naive link classifier would swallow it.
    const r = classifyIconFilter(["plot"]);
    expect(r.includesPlot).toBe(true);
    expect(r.includesLink).toBe(false);
    expect(r.others).toEqual([]);
  });

  it("treats the raw Plot icon URL (legacy state) as the Plot bucket, not a link", () => {
    const r = classifyIconFilter([PLOT_ICON_URL]);
    expect(r.includesPlot).toBe(true);
    expect(r.includesLink).toBe(false);
    expect(r.others).toEqual([]);
  });

  it("classifies the generic link bucket (literal 'link' and favicon URLs)", () => {
    const r = classifyIconFilter(["link", "https://github.com/favicon.ico"]);
    expect(r.includesLink).toBe(true);
    expect(r.includesPlot).toBe(false);
    expect(r.others).toEqual([]);
  });

  it("keeps the Plot URL out of the link bucket even when both are present", () => {
    const r = classifyIconFilter([
      PLOT_ICON_URL,
      "https://example.com/favicon.png",
    ]);
    expect(r.includesPlot).toBe(true);
    expect(r.includesLink).toBe(true);
    expect(r.others).toEqual([]);
  });

  it("routes built-in subtypes, connector and twist icons to the exact-match bucket", () => {
    const r = classifyIconFilter([
      "action",
      "connector:123:issue",
      "twist:456",
    ]);
    expect(r.includesPlot).toBe(false);
    expect(r.includesLink).toBe(false);
    expect(r.others).toEqual(["action", "connector:123:issue", "twist:456"]);
  });

  it("handles a mixed chip set across all three buckets", () => {
    const r = classifyIconFilter(["plot", "link", "action"]);
    expect(r.includesPlot).toBe(true);
    expect(r.includesLink).toBe(true);
    expect(r.others).toEqual(["action"]);
  });
});

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
    // Gmail's `email` link type declares `compose: { targets: "addresses" }`
    // with NO status (it's a message, not a task), so the Flutter client sends
    // channel_id: null AND status: null. A status-less link type must still
    // dispatch — onCreateLink handles a null status. Requiring a truthy status
    // here is the bug that made Gmail compose silently never send (the thread
    // stayed a plain Plot thread with no email).
    expect(
      isDispatchableCreateLink({
        twist_instance_id: "ti",
        channel_id: null,
        type: "email",
        status: null,
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

  it("dispatches a status-less spec (status omitted) — only twist + type are required", () => {
    // Status is an attribute, not an identifier. Status-less link types
    // (Gmail email, status-less messaging connectors) omit it; dispatch must
    // still fire so the connector's onCreateLink runs.
    expect(
      isDispatchableCreateLink({ twist_instance_id: "ti", type: "email" }),
    ).toBe(true);
  });

  it("does not dispatch when spec is undefined", () => {
    expect(isDispatchableCreateLink(undefined)).toBe(false);
  });
});

describe("computeThreadEmbedding", () => {
  // The embedding model call runs BEFORE the write transaction in
  // POST /sync/threads, so it must never throw (a failure can't be allowed to
  // roll back the upsert) and must always resolve to either a halfvec literal
  // or null. A null leaves the thread NULL-embedded for the reconcile sweep.
  const fakeAi = (run: (model: string, input: { text: string }) => Promise<unknown>) =>
    ({ run: vi.fn(run) }) as unknown as Ai;

  it("returns the first row of the model output as a halfvec JSON literal", async () => {
    const ai = fakeAi(async () => ({ data: [[0.1, 0.2, 0.3]] }));
    const result = await computeThreadEmbedding(ai, "hello world");
    expect(result).toBe("[0.1,0.2,0.3]");
  });

  it("returns null (never throws) when the model call rejects", async () => {
    const ai = fakeAi(async () => {
      throw new Error("AI binding unavailable");
    });
    await expect(computeThreadEmbedding(ai, "hello")).resolves.toBeNull();
  });

  it("returns null when the model returns no embedding row", async () => {
    const ai = fakeAi(async () => ({ data: [] }));
    expect(await computeThreadEmbedding(ai, "hello")).toBeNull();
  });
});
