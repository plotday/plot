import { describe, expect, it } from "vitest";

import { Imap } from "../imap";

describe("Imap", () => {
  describe("Permissions", () => {
    it("should return permissions for declared hosts", () => {
      const permissions = Imap.Permissions({
        hosts: ["imap.mail.me.com"],
      });

      expect(permissions).toEqual([
        {
          domain: "imap",
          entity: "imap.mail.me.com",
          flags: ["use"],
        },
      ]);
    });

    it("should return permissions for multiple hosts", () => {
      const permissions = Imap.Permissions({
        hosts: ["imap.mail.me.com", "imap.gmail.com"],
      });

      expect(permissions).toHaveLength(2);
      expect(permissions[0]).toEqual({
        domain: "imap",
        entity: "imap.mail.me.com",
        flags: ["use"],
      });
      expect(permissions[1]).toEqual({
        domain: "imap",
        entity: "imap.gmail.com",
        flags: ["use"],
      });
    });

    it("should return empty array when no hosts provided", () => {
      const permissions = Imap.Permissions({});
      expect(permissions).toEqual([]);
    });

    it("should return empty array when options not provided", () => {
      const permissions = Imap.Permissions();
      expect(permissions).toEqual([]);
    });
  });

  describe("constructor", () => {
    it("should create instance without options", () => {
      const imap = new Imap();
      expect(imap).toBeDefined();
    });

    it("should create instance with host options", () => {
      const imap = new Imap({ hosts: ["imap.mail.me.com"] });
      expect(imap).toBeDefined();
    });
  });

  describe("connect", () => {
    it("should reject undeclared hosts", async () => {
      const imap = new Imap({ hosts: ["imap.mail.me.com"] });

      await expect(
        imap.connect({
          host: "imap.evil.com",
          port: 993,
          tls: true,
          username: "user",
          password: "pass",
        })
      ).rejects.toThrow(
        'IMAP host "imap.evil.com" is not in the declared hosts list'
      );
    });
  });
});
