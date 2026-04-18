import { describe, expect, it } from "vitest";

import { classifyInviteable } from "./contact-classifier";

describe("classifyInviteable", () => {
  describe("returns true (inviteable)", () => {
    it("for null email", () => {
      expect(classifyInviteable(null)).toBe(true);
    });

    it("for empty email", () => {
      expect(classifyInviteable("")).toBe(true);
    });

    it("for normal personal addresses", () => {
      expect(classifyInviteable("kris@plot.day")).toBe(true);
      expect(classifyInviteable("alice.smith@example.com")).toBe(true);
    });

    it("for generic team addresses", () => {
      expect(classifyInviteable("support@stripe.com")).toBe(true);
      expect(classifyInviteable("hello@linear.app")).toBe(true);
      expect(classifyInviteable("team@notion.so")).toBe(true);
    });

    it("when local part contains 'noreply' as a substring but not a word", () => {
      expect(classifyInviteable("nonoreplyable@example.com")).toBe(true);
    });
  });

  describe("returns false (non-inviteable)", () => {
    it("for exact local-part matches", () => {
      expect(classifyInviteable("no-reply@github.com")).toBe(false);
      expect(classifyInviteable("noreply@linear.app")).toBe(false);
      expect(classifyInviteable("donotreply@example.com")).toBe(false);
      expect(classifyInviteable("do-not-reply@example.com")).toBe(false);
      expect(classifyInviteable("mailer-daemon@example.com")).toBe(false);
      expect(classifyInviteable("postmaster@example.com")).toBe(false);
      expect(classifyInviteable("bounces@example.com")).toBe(false);
      expect(classifyInviteable("bounce@example.com")).toBe(false);
      expect(classifyInviteable("notifications@example.com")).toBe(false);
      expect(classifyInviteable("notification@example.com")).toBe(false);
      expect(classifyInviteable("alerts@example.com")).toBe(false);
      expect(classifyInviteable("alert@example.com")).toBe(false);
      expect(classifyInviteable("auto-confirm@example.com")).toBe(false);
      expect(classifyInviteable("automated@example.com")).toBe(false);
    });

    it("for local-part prefixes", () => {
      expect(classifyInviteable("noreply-billing@stripe.com")).toBe(false);
      expect(classifyInviteable("no-reply-support@example.com")).toBe(false);
      expect(classifyInviteable("donotreply-orders@example.com")).toBe(false);
      expect(classifyInviteable("notification-server@example.com")).toBe(false);
      expect(classifyInviteable("notifications-daily@example.com")).toBe(false);
      expect(classifyInviteable("reply+ABC123@github.com")).toBe(false);
    });

    it("for local-part word-bounded matches", () => {
      expect(classifyInviteable("team-noreply@example.com")).toBe(false);
      expect(classifyInviteable("orders-no-reply@example.com")).toBe(false);
      expect(classifyInviteable("support-donotreply@example.com")).toBe(false);
    });

    it("for domain subdomains", () => {
      expect(classifyInviteable("welcome@em.bounces.mailchimp.com")).toBe(false);
      expect(classifyInviteable("hello@bounce.sendgrid.net")).toBe(false);
      expect(classifyInviteable("daily@mailer.acme.com")).toBe(false);
      expect(classifyInviteable("info@em.mailer.foo.com")).toBe(false);
    });

    it("case-insensitively", () => {
      expect(classifyInviteable("NoReply@GitHub.com")).toBe(false);
      expect(classifyInviteable("MAILER-DAEMON@example.com")).toBe(false);
    });
  });

  it("accepts a name parameter (reserved for future use)", () => {
    expect(classifyInviteable("kris@plot.day", "Kris Braun")).toBe(true);
  });
});
