import { describe, expect, it } from "vitest";

import { formatImportanceFeatureBlock, isAutomatedSenderEmail } from "./features";

describe("isAutomatedSenderEmail", () => {
  it("flags no-reply / notifications / mailer addresses", () => {
    for (const e of [
      "no-reply@acme.com",
      "noreply@acme.com",
      "do-not-reply@acme.com",
      "notifications@acme.com",
      "notification@x.io",
      "mailer-daemon@x.io",
      "bounce+abc@x.io",
      "postmaster@x.io",
    ]) {
      expect(isAutomatedSenderEmail(e)).toBe(true);
    }
  });
  it("does not flag ordinary personal addresses or null", () => {
    expect(isAutomatedSenderEmail("kris@plot.day")).toBe(false);
    expect(isAutomatedSenderEmail("jane.doe@gmail.com")).toBe(false);
    expect(isAutomatedSenderEmail(null)).toBe(false);
    expect(isAutomatedSenderEmail("")).toBe(false);
  });
});

describe("formatImportanceFeatureBlock", () => {
  it("renders facets, sender flags, and per-member engagement", () => {
    const block = formatImportanceFeatureBlock({
      facets: { format: "promotion", automation: "automated", reach: "list" },
      senderEmailAutomated: true,
      senderIsLinkedUser: false,
      members: [
        {
          memberNum: 1,
          engagement: {
            priorThreads: 9,
            readRate: 0.11,
            archivedUnreadRate: 0.78,
            replyRate: 0,
          },
        },
      ],
    });
    expect(block).toContain("promotion");
    expect(block).toContain("automated");
    expect(block).toContain("list");
    expect(block).toMatch(/no-?reply|automated sender/i);
    expect(block).toContain("#1");
    // read rate surfaced as a percentage the model can act on
    expect(block).toMatch(/11%/);
  });

  it("states when a sender is new / has no history", () => {
    const block = formatImportanceFeatureBlock({
      facets: null,
      senderEmailAutomated: false,
      senderIsLinkedUser: true,
      members: [
        {
          memberNum: 2,
          engagement: {
            priorThreads: 0,
            readRate: null,
            archivedUnreadRate: null,
            replyRate: null,
          },
        },
      ],
    });
    expect(block).toMatch(/no (prior |)history|new sender|first/i);
    expect(block).toContain("#2");
  });

  it("notes when there are too few prior threads to judge", () => {
    const block = formatImportanceFeatureBlock({
      facets: null,
      senderEmailAutomated: false,
      senderIsLinkedUser: false,
      members: [
        {
          memberNum: 3,
          engagement: {
            priorThreads: 2,
            readRate: null,
            archivedUnreadRate: null,
            replyRate: null,
          },
        },
      ],
    });
    expect(block).toContain("#3");
    expect(block).toMatch(/too few|judge/i);
  });
});
