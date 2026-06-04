import { describe, it, expect } from "vitest";
import { parseInviteAddress } from "./invite-address";

describe("parseInviteAddress", () => {
  it("parses Name <email>", () => {
    expect(parseInviteAddress("Kris Braun <kris@plot.day>")).toEqual({
      email: "kris@plot.day",
      name: "Kris Braun",
    });
  });
  it("parses a bare email", () => {
    expect(parseInviteAddress("kris@plot.day")).toEqual({ email: "kris@plot.day" });
  });
  it("lowercases the email", () => {
    expect(parseInviteAddress("Kris <KRIS@Plot.Day>").email).toBe("kris@plot.day");
  });
  it("unquotes a quoted name", () => {
    expect(parseInviteAddress('"Braun, Kris" <k@x.com>').name).toBe("Braun, Kris");
  });
  it("treats a name-less angle form as just the email", () => {
    expect(parseInviteAddress("<k@x.com>")).toEqual({ email: "k@x.com" });
  });
});
