import { describe, expect, it } from "vitest";
import { classifyEmail, type EmailSignals } from "./classify-email";

function signals(overrides: Partial<EmailSignals> = {}): EmailSignals {
  return {
    listId: null,
    listUnsubscribe: null,
    precedence: null,
    autoSubmitted: null,
    returnPath: null,
    importance: null,
    fromAddress: "jane@example.com",
    recipientCount: 1,
    isReply: false,
    subject: "Hello",
    bodyLength: 300,
    gmailCategories: [],
    ...overrides,
  };
}

describe("classifyEmail — automation", () => {
  it("flags no-reply senders automated", () => {
    expect(classifyEmail(signals({ fromAddress: "no-reply@acme.com" })).automation).toBe("automated");
  });
  it("flags Precedence: bulk automated", () => {
    expect(classifyEmail(signals({ precedence: "bulk" })).automation).toBe("automated");
  });
  it("flags Auto-Submitted automated", () => {
    expect(classifyEmail(signals({ autoSubmitted: "auto-generated" })).automation).toBe("automated");
  });
  it("treats a plain person email as human", () => {
    expect(classifyEmail(signals()).automation).toBe("human");
  });
});

describe("classifyEmail — reach", () => {
  it("flags List-Id as list", () => {
    expect(classifyEmail(signals({ listId: "<news.acme.com>" })).reach).toBe("list");
  });
  it("flags List-Unsubscribe as list", () => {
    expect(classifyEmail(signals({ listUnsubscribe: "<mailto:u@acme.com>" })).reach).toBe("list");
  });
  it("flags high recipient count as list", () => {
    expect(classifyEmail(signals({ recipientCount: 12 })).reach).toBe("list");
  });
  it("treats a 1:1 email as direct", () => {
    expect(classifyEmail(signals()).reach).toBe("direct");
  });
});

describe("classifyEmail — format", () => {
  it("invoice from subject keywords", () => {
    expect(classifyEmail(signals({ subject: "Your invoice is due", fromAddress: "billing@acme.com" })).format).toBe("invoice");
  });
  it("receipt from subject keywords", () => {
    expect(classifyEmail(signals({ subject: "Your order confirmation #1234", fromAddress: "orders@shop.com" })).format).toBe("receipt");
  });
  it("promotion from Gmail category", () => {
    expect(classifyEmail(signals({ gmailCategories: ["CATEGORY_PROMOTIONS"], listUnsubscribe: "<x>" })).format).toBe("promotion");
  });
  it("reading from a long list email", () => {
    expect(
      classifyEmail(signals({ listId: "<news>", listUnsubscribe: "<x>", bodyLength: 4000, subject: "Weekly digest" })).format
    ).toBe("reading");
  });
  it("notification from a short automated update", () => {
    expect(
      classifyEmail(signals({ fromAddress: "notifications@github.com", bodyLength: 200, gmailCategories: ["CATEGORY_UPDATES"] })).format
    ).toBe("notification");
  });
  it("message for a normal human email", () => {
    expect(classifyEmail(signals({ bodyLength: 800 })).format).toBe("message");
  });
  it("classifies a short automated email as a notification", () => {
    expect(classifyEmail(signals({ fromAddress: "no-reply@x.com", bodyLength: 0, subject: null })).format).toBe("notification");
  });
  it("leaves format null when no heuristic is confident", () => {
    // automated (auto_reply) but long body, direct, no categories, neutral subject →
    // none of the format branches fire → null.
    expect(
      classifyEmail(signals({ precedence: "auto_reply", bodyLength: 900, subject: "Re: status" })).format
    ).toBeNull();
  });
});
