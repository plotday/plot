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
      // Any-label UUIDs routed through reply.*/noreply.* subdomains.
      expect(classifyInviteable("uuid-token@reply.linkedin.com")).toBe(false);
      expect(classifyInviteable("state_change@noreply.github.com")).toBe(false);
      expect(classifyInviteable("9639772.x@reply.podio.com")).toBe(false);
    });

    it("for underscore and dot separators in the local part", () => {
      expect(classifyInviteable("no_reply@email.apple.com")).toBe(false);
      expect(classifyInviteable("testflight_no_reply@email.apple.com")).toBe(false);
      expect(classifyInviteable("no-reply.ontario@prod.esii-orion.com")).toBe(false);
      expect(classifyInviteable("no-reply.ecommerce@fedex.com")).toBe(false);
    });

    it("for reply-TOKEN style transactional locals", () => {
      expect(classifyInviteable("reply-feb7137671@emails.gamefly.com")).toBe(false);
      expect(classifyInviteable("reply-ayzvhndv@in2.getdrip.com")).toBe(false);
    });

    it("for noreply+TOKEN and ...-reply+TOKEN locals", () => {
      expect(classifyInviteable("noreply+10cad87@id.atlassian.com")).toBe(false);
      expect(
        classifyInviteable("api-oauth-dev-verification-reply+32kg6y2ce82if1d@google.com"),
      ).toBe(false);
    });

    it("for bare reply word-suffix locals", () => {
      expect(classifyInviteable("comment-reply@wordpress.com")).toBe(false);
      expect(classifyInviteable("hit-reply@linkedin.com")).toBe(false);
    });

    it("for malformed email values without @", () => {
      expect(classifyInviteable("undisclosed-recipients:;")).toBe(false);
      expect(classifyInviteable('"bayne')).toBe(false);
      expect(classifyInviteable("foo")).toBe(false);
      expect(classifyInviteable("foo@")).toBe(false);
      expect(classifyInviteable("@bar.com")).toBe(false);
    });

    it("for newsletter and unsubscribe locals", () => {
      expect(classifyInviteable("newsletter@floatfinancial.com")).toBe(false);
      expect(classifyInviteable("newsletters@example.com")).toBe(false);
      expect(classifyInviteable("newsletter-weekly@example.com")).toBe(false);
      expect(classifyInviteable("weekly-newsletter@example.com")).toBe(false);
      expect(classifyInviteable("unsubscribe@example.com")).toBe(false);
      expect(classifyInviteable("unsubscribe-mc.us2_4812d3b@example.com")).toBe(false);
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
