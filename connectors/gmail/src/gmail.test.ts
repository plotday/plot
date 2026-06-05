import { describe, expect, it } from "vitest";
import { recipientsFor } from "./gmail";
import {
  type GmailMessage,
  type GmailThread,
  transformGmailThread,
} from "./gmail-api";

type TestContact = { email?: string; name?: string };

/** Build a minimal single-message Gmail thread for transform tests. */
function threadWith(headers: Record<string, string>): GmailThread {
  const message: GmailMessage = {
    id: "msg-1",
    threadId: "thread-1",
    labelIds: ["INBOX"],
    snippet: "body snippet",
    historyId: "1",
    internalDate: "1700000000000",
    sizeEstimate: 100,
    payload: {
      mimeType: "text/plain",
      headers: Object.entries(headers).map(([name, value]) => ({
        name,
        value,
      })),
      body: { size: 12, data: btoa("body snippet") },
    },
  };
  return { id: "thread-1", historyId: "1", messages: [message] };
}

function noteAuthor(thread: GmailThread): { email?: string; name?: string } {
  const plot = transformGmailThread(thread);
  return (plot.notes![0] as { author: { email?: string; name?: string } })
    .author;
}

function accessContactFor(
  thread: GmailThread,
  email: string
): TestContact | undefined {
  const plot = transformGmailThread(thread);
  return (plot.accessContacts as TestContact[]).find(
    (c) => c.email?.toLowerCase() === email.toLowerCase()
  );
}

describe("recipientsFor", () => {
  const self = "me@example.com";
  const alice = "alice@example.com";
  const bob = "bob@example.com";

  it("includes all candidates when accessContactEmails is null (no constraint)", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("always excludes self regardless of constraint", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("filters to only accessContactEmails when constraint is set", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([alice.toLowerCase()]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("private note (empty accessContactEmails) → empty recipient list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([]);
  });

  it("excludes self even when self is in accessContactEmails", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([self.toLowerCase(), alice.toLowerCase()]),
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("preserves candidate order from input list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([
          bob.toLowerCase(),
          alice.toLowerCase(),
        ]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("is case-insensitive when matching self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: ["ME@EXAMPLE.COM", alice],
        self,
      })
    ).toEqual([alice]);
  });

  it("is case-insensitive when matching candidate emails against set entries", () => {
    // The set holds lowercase emails (caller normalises on insert);
    // candidates may be mixed-case and are lowercased before lookup.
    expect(
      recipientsFor({
        accessContactEmails: new Set(["alice@example.com"]),
        candidates: ["ALICE@EXAMPLE.COM", bob],
        self,
      })
    ).toEqual(["ALICE@EXAMPLE.COM"]);
  });

  it("returns empty list when all candidates are self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, "ME@EXAMPLE.COM"],
        self,
      })
    ).toEqual([]);
  });

  it("handles empty candidates list gracefully", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [],
        self,
      })
    ).toEqual([]);
  });
});

describe("transformGmailThread — mailing-list From rewrite", () => {
  it("suppresses the From name when a Google Group rewrote the From address (DMARC)", () => {
    // Google Groups rewrites the From for DMARC: the original sender
    // "Cloudflare <noreply@cloudflare.com>" distributed through the
    // team@plot.day group arrives as "Cloudflare via Plot Team <team@plot.day>"
    // with X-Original-Sender preserving the real sender. The display name
    // belongs to a different identity than the From address (the group), so we
    // must NOT name the group contact "Cloudflare".
    const thread = threadWith({
      From: "Cloudflare via Plot Team <team@plot.day>",
      To: "member@plot.day",
      "X-Original-Sender": "noreply@cloudflare.com",
      Subject: "Cloudflare Workers usage reached your threshold",
    });

    expect(noteAuthor(thread)).toMatchObject({ email: "team@plot.day" });
    expect(noteAuthor(thread).name).toBeUndefined();
    expect(accessContactFor(thread, "team@plot.day")?.name).toBeUndefined();
  });

  it("suppresses the From name from the 'via' marker when no original-sender header is present", () => {
    const thread = threadWith({
      From: "noreply-spamdigest via Plot Team <team@plot.day>",
      To: "member@plot.day",
      Subject: "Moderator's spam report for team@plot.day",
    });

    expect(noteAuthor(thread).name).toBeUndefined();
    expect(accessContactFor(thread, "team@plot.day")?.name).toBeUndefined();
  });

  it("keeps the From name for ordinary direct mail", () => {
    const thread = threadWith({
      From: "Jane Doe <jane@example.com>",
      To: "member@plot.day",
      Subject: "Hello",
    });

    expect(noteAuthor(thread)).toMatchObject({
      email: "jane@example.com",
      name: "Jane Doe",
    });
    expect(accessContactFor(thread, "jane@example.com")?.name).toBe("Jane Doe");
  });

  it("keeps the From name when the list did NOT rewrite the address (X-Original-Sender matches From)", () => {
    // Legit list post that passed DMARC: From keeps the real sender's address,
    // so the display name still belongs to that address — keep it.
    const thread = threadWith({
      From: "Jane Doe <jane@example.com>",
      To: "team@plot.day",
      "X-Original-Sender": "jane@example.com",
      Subject: "Re: roadmap",
    });

    expect(accessContactFor(thread, "jane@example.com")?.name).toBe("Jane Doe");
  });
});
