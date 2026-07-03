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
    bodyText: null,
    fromName: null,
    links: [],
    authResults: null,
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
  it("flags mailing-list mail automated", () => {
    expect(classifyEmail(signals({ listId: "<news.acme.com>" })).automation).toBe("automated");
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
  it("keeps a short automated DIRECT reply a message, not a notification", () => {
    // A support desk / ticketing system stamps automated headers, but a reply
    // addressed directly to the user is a two-way conversation. Without the
    // direct-reply guard this short automated body falls through to the
    // notification branch and gets swept into the muted FYI focus.
    expect(
      classifyEmail(
        signals({ isReply: true, autoSubmitted: "auto-generated", bodyLength: 200, subject: "Re: RESP Withdrawals" })
      ).format
    ).toBe("message");
  });
  it("still classifies a short automated DIRECT non-reply as a notification", () => {
    expect(
      classifyEmail(
        signals({ isReply: false, fromAddress: "no-reply@x.com", bodyLength: 200 })
      ).format
    ).toBe("notification");
  });
  it("does not treat a reply on a LIST email as a message", () => {
    // The guard is scoped to direct reach — bulk/list replies stay as they were.
    expect(
      classifyEmail(
        signals({ isReply: true, listId: "<news>", listUnsubscribe: "<x>", bodyLength: 200 })
      ).format
    ).toBe("notification");
  });
  it("leaves format null when no heuristic is confident", () => {
    // automated (auto_reply) but long body, direct, no categories, neutral subject →
    // none of the format branches fire → null.
    expect(
      classifyEmail(signals({ precedence: "auto_reply", bodyLength: 900, subject: "Re: status" })).format
    ).toBeNull();
  });
});

describe("classifyEmail — calendar invitation responses", () => {
  // Google/Outlook send automated "Accepted:/Declined:/Tentative:" emails when
  // an invitee responds to a meeting invite. An acceptance is a passive
  // confirmation — route it to a notification so it lands in the muted FYI focus
  // ("skip active"). A decline or tentative may need follow-up (reschedule, find
  // a new time), so it must stay active.
  const RESPONSE_SUBJECT_TAIL = "Beth <> Kris Collab @ Wed Jun 10, 2026 10:30am (EDT)";

  it("classifies an acceptance as a notification regardless of body length", () => {
    expect(
      classifyEmail(
        signals({
          subject: `Accepted: ${RESPONSE_SUBJECT_TAIL}`,
          fromAddress: "beth@example.com",
          autoSubmitted: "auto-generated",
          bodyLength: 1200,
        })
      ).format
    ).toBe("notification");
  });

  it("keeps a decline active even when short and automated", () => {
    // Without the calendar-response guard, a short automated email would fall
    // through to the generic short-automated → notification branch and get
    // swept into FYI. Declines must stay active.
    expect(
      classifyEmail(
        signals({
          subject: `Declined: ${RESPONSE_SUBJECT_TAIL}`,
          fromAddress: "beth@example.com",
          autoSubmitted: "auto-generated",
          bodyLength: 200,
        })
      ).format
    ).toBeNull();
  });

  it("keeps a tentative response active", () => {
    expect(
      classifyEmail(
        signals({
          subject: `Tentative: ${RESPONSE_SUBJECT_TAIL}`,
          fromAddress: "beth@example.com",
          autoSubmitted: "auto-generated",
          bodyLength: 200,
        })
      ).format
    ).toBeNull();
  });

  it("does not treat a human 'Accepted:' email as a calendar notification", () => {
    // A real person writing "Accepted: ..." is not a calendar response; only
    // automated invitation replies skip active.
    expect(
      classifyEmail(
        signals({
          subject: "Accepted: your proposal",
          fromAddress: "jane@example.com",
          bodyLength: 800,
        })
      ).format
    ).toBe("message");
  });
});
