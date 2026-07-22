import { describe, expect, it } from "vitest";
import type { ResolvedRecipient } from "../plot";
import { resolveOutboundReplyRecipients } from "./reply-recipients";

const rcpt = (
  email: string,
  role: string | null = null
): ResolvedRecipient => ({
  id: email as unknown as ResolvedRecipient["id"],
  name: null,
  externalAccountId: email,
  role,
});

const mailbox = "me@personal.com"; // connected account
const workEmail = "me@work.com"; // same user, different identity
const tobin = "tobin@example.com";
const beth = "beth@example.com";
const anthropic = "receipts@anthropic.com";

describe("resolveOutboundReplyRecipients", () => {
  describe("case 1: platform-resolved recipients (authoritative)", () => {
    it("addresses curated recipients who were never on the message", () => {
      // The reported bug: reply to Anthropic, add two people not on the email.
      const r = resolveOutboundReplyRecipients({
        recipients: [rcpt(tobin), rcpt(beth)],
        accessContactEmails: null,
        headerTo: [anthropic, mailbox],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([tobin, beth]);
      expect(r.cc).toEqual([]);
      expect(r.bcc).toEqual([]);
      expect(r.curated).toBe(true);
    });

    it("ignores the message headers entirely — a dropped participant is not re-added", () => {
      // Anthropic was on the message but the user curated it out.
      const r = resolveOutboundReplyRecipients({
        recipients: [rcpt(tobin)],
        accessContactEmails: null,
        headerTo: [anthropic],
        headerCc: [anthropic],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([tobin]);
      expect(r.cc).toEqual([]);
    });

    it("honors to/cc/bcc roles", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: [rcpt(tobin, "to"), rcpt(beth, "cc"), rcpt("x@y.com", "bcc")],
        accessContactEmails: null,
        headerTo: [],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([tobin]);
      expect(r.cc).toEqual([beth]);
      expect(r.bcc).toEqual(["x@y.com"]);
    });

    it("defaults null role to To (or the provided default)", () => {
      expect(
        resolveOutboundReplyRecipients({
          recipients: [rcpt(tobin, null)],
          accessContactEmails: null,
          headerTo: [],
          headerCc: [],
          selfEmails: new Set(),
        }).to
      ).toEqual([tobin]);
    });

    it("a bcc address never also appears in To/Cc (no leak)", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: [rcpt(tobin, "to"), rcpt(tobin, "bcc")],
        accessContactEmails: null,
        headerTo: [],
        headerCc: [],
        selfEmails: new Set(),
      });
      expect(r.bcc).toEqual([tobin]);
      expect(r.to).toEqual([]);
    });

    it("empty curated list stays curated (connector surfaces a delivery error)", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: [],
        accessContactEmails: null,
        headerTo: [anthropic],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([]);
      expect(r.curated).toBe(true);
    });
  });

  describe("case 2: access-contact fallback (recipients null)", () => {
    it("adds curated addresses not on the message and excludes all self identities", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([workEmail, tobin, beth]),
        headerTo: [anthropic, mailbox],
        headerCc: [],
        selfEmails: new Set([mailbox, workEmail]),
      });
      expect(r.to).toEqual([tobin, beth]);
      expect(r.curated).toBe(true);
    });

    it("narrows header participants to the access set", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([tobin]),
        headerTo: [tobin, anthropic],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([tobin]);
    });

    it("private note (self only) yields no recipients but stays curated", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([workEmail]),
        headerTo: [anthropic, mailbox],
        headerCc: [],
        selfEmails: new Set([mailbox, workEmail]),
      });
      expect(r.to).toEqual([]);
      expect(r.cc).toEqual([]);
      expect(r.curated).toBe(true);
    });
  });

  describe("case 3: reply-all (no constraint)", () => {
    it("replies to every participant except self", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: null,
        headerTo: [anthropic, mailbox],
        headerCc: [beth],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([anthropic]);
      expect(r.cc).toEqual([beth]);
      expect(r.curated).toBe(false);
    });

    it("de-dupes an address that appears in both To and Cc (kept in Cc precedence... actually To wins order)", () => {
      // Same address on To and Cc → appears once; precedence keeps it out of To if in Cc.
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: null,
        headerTo: [tobin],
        headerCc: [tobin],
        selfEmails: new Set(),
      });
      expect(r.cc).toEqual([tobin]);
      expect(r.to).toEqual([]);
    });
  });

  describe("self-reply fallback (headerFrom all self)", () => {
    it("self→self single address addresses the original sender", () => {
      // Note-to-self: connector strips the self From/To, leaving empty headers;
      // headerFrom carries the raw original sender (still self).
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: null,
        headerFrom: [mailbox],
        headerTo: [],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([mailbox]);
      expect(r.cc).toEqual([]);
      expect(r.bcc).toEqual([]);
    });

    it("A→B both linked (curated) addresses the original sender", () => {
      // Cross-connector self-email: both identities are self, so the curated
      // resolution empties out; fall back to the original sender.
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([mailbox, workEmail]),
        headerFrom: [workEmail],
        headerTo: [],
        headerCc: [],
        selfEmails: new Set([mailbox, workEmail]),
      });
      expect(r.to).toEqual([workEmail]);
      expect(r.curated).toBe(true);
    });

    it("does NOT fall back when the original sender is external (private note)", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([workEmail]),
        headerFrom: [anthropic],
        headerTo: [],
        headerCc: [],
        selfEmails: new Set([mailbox, workEmail]),
      });
      expect(r.to).toEqual([]);
      expect(r.curated).toBe(true);
    });

    it("does NOT fall back when a non-self participant was narrowed out", () => {
      // You emailed yourself AND an external contact, then restricted the note
      // to just yourself: stays private, must not email your own address.
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([mailbox]),
        headerFrom: [mailbox],
        headerTo: [anthropic],
        headerCc: [],
        selfEmails: new Set([mailbox]),
      });
      expect(r.to).toEqual([]);
    });

    it("without headerFrom, an all-self result stays empty (unchanged)", () => {
      const r = resolveOutboundReplyRecipients({
        recipients: null,
        accessContactEmails: new Set([workEmail]),
        headerTo: [anthropic, mailbox],
        headerCc: [],
        selfEmails: new Set([mailbox, workEmail]),
      });
      expect(r.to).toEqual([]);
    });
  });
});
