import { describe, expect, it } from "vitest";

import { classifyUrlAccess } from "./access";

describe("classifyUrlAccess", () => {
  describe("auth-required hosts", () => {
    it("classifies Jira/Confluence cloud URLs", () => {
      expect(
        classifyUrlAccess("https://mycompany.atlassian.net/browse/ENG-123")
      ).toBe("auth_required");
      expect(
        classifyUrlAccess(
          "https://mycompany.atlassian.net/wiki/spaces/ENG/pages/4567/Home"
        )
      ).toBe("auth_required");
    });

    it("classifies Linear issues but not the marketing site", () => {
      expect(
        classifyUrlAccess("https://linear.app/plot/issue/PLT-42/some-title")
      ).toBe("auth_required");
      // Marketing landing pages are public.
      expect(classifyUrlAccess("https://linear.app/")).toBeNull();
      expect(classifyUrlAccess("https://linear.app/features")).toBeNull();
    });

    it("classifies Slack message URLs but not slack.com itself", () => {
      expect(
        classifyUrlAccess(
          "https://plotday.slack.com/archives/C012345/p1700000000000099"
        )
      ).toBe("auth_required");
      // The marketing site is public.
      expect(classifyUrlAccess("https://slack.com/pricing")).toBeNull();
    });

    it("classifies common SaaS workspaces (Asana, HubSpot, Intercom, Salesforce)", () => {
      expect(
        classifyUrlAccess("https://app.asana.com/0/12345/67890/f")
      ).toBe("auth_required");
      expect(classifyUrlAccess("https://app.hubspot.com/contacts/123")).toBe(
        "auth_required"
      );
      expect(classifyUrlAccess("https://app.intercom.com/a/inbox")).toBe(
        "auth_required"
      );
      expect(
        classifyUrlAccess("https://mycorp.lightning.force.com/lightning/r/X")
      ).toBe("auth_required");
    });

    it("classifies Gmail / Outlook / Teams URLs", () => {
      expect(classifyUrlAccess("https://mail.google.com/mail/u/0/#inbox")).toBe(
        "auth_required"
      );
      expect(
        classifyUrlAccess(
          "https://outlook.office.com/mail/inbox/id/AAQkA..."
        )
      ).toBe("auth_required");
      expect(
        classifyUrlAccess(
          "https://teams.microsoft.com/l/message/19:foo/1700000000000"
        )
      ).toBe("auth_required");
    });
  });

  describe("paywalled hosts", () => {
    it("classifies hard paywall outlets", () => {
      expect(classifyUrlAccess("https://www.ft.com/content/abc-123")).toBe(
        "paywalled"
      );
      expect(classifyUrlAccess("https://www.wsj.com/articles/abc")).toBe(
        "paywalled"
      );
      expect(classifyUrlAccess("https://www.bloomberg.com/news/articles/xyz")).toBe(
        "paywalled"
      );
      expect(
        classifyUrlAccess("https://www.economist.com/leaders/2026/05/01/x")
      ).toBe("paywalled");
      expect(
        classifyUrlAccess("https://www.nytimes.com/2026/05/01/business/x.html")
      ).toBe("paywalled");
    });

    it("matches bare hostname as well as common subdomains", () => {
      expect(classifyUrlAccess("https://wsj.com/x")).toBe("paywalled");
      expect(classifyUrlAccess("https://www.wsj.com/x")).toBe("paywalled");
    });
  });

  describe("ambiguous services pass through (null)", () => {
    it("returns null for services with both public and private modes", () => {
      // GitHub: public repos are extractable, private ones aren't — we let
      // the consumer try and fall back to the existing failure paths.
      expect(
        classifyUrlAccess("https://github.com/anthropics/claude-code")
      ).toBeNull();
      // Google Docs can be public or private.
      expect(
        classifyUrlAccess(
          "https://docs.google.com/document/d/abc/edit"
        )
      ).toBeNull();
      // Notion same story.
      expect(
        classifyUrlAccess("https://www.notion.so/some-public-page-abc")
      ).toBeNull();
      // Medium — partial paywall, plenty of free posts.
      expect(
        classifyUrlAccess("https://medium.com/@author/title-abc")
      ).toBeNull();
    });

    it("returns null for non-matching hosts", () => {
      expect(classifyUrlAccess("https://example.com/article")).toBeNull();
      expect(classifyUrlAccess("https://overreacted.io/before-you-memo")).toBeNull();
    });
  });

  describe("input handling", () => {
    it("returns null for invalid URLs rather than throwing", () => {
      expect(classifyUrlAccess("not a url")).toBeNull();
      expect(classifyUrlAccess("")).toBeNull();
    });

    it("treats hostname case-insensitively", () => {
      expect(classifyUrlAccess("https://WWW.WSJ.COM/x")).toBe("paywalled");
    });

    it("does not match lookalike domains (notslack.com vs slack.com)", () => {
      expect(classifyUrlAccess("https://notslack.com/archives/x")).toBeNull();
      expect(classifyUrlAccess("https://nytimes.com.example.org/x")).toBeNull();
    });
  });
});
