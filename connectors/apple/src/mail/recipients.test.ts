import { describe, expect, it } from "vitest";
import type { ActorId, ResolvedRecipient, Uuid } from "@plotday/twister/plot";

import {
  accessContactsToRecipients,
  baseSubject,
  composeRecipients,
  deriveReplyAll,
  isEmpty,
  replySubject,
  splitByRole,
} from "./recipients";

const rcpt = (email: string, role: string | null): ResolvedRecipient => ({
  id: "00000000-0000-0000-0000-000000000000" as Uuid,
  name: null,
  externalAccountId: email,
  role,
});

describe("subject helpers", () => {
  it("strips repeated Re:/Fwd: prefixes", () => {
    expect(baseSubject("Re: Fwd: Lunch?")).toBe("Lunch?");
    expect(baseSubject("Lunch?")).toBe("Lunch?");
    expect(baseSubject("")).toBe("");
  });
  it("builds a reply subject", () => {
    expect(replySubject("Lunch?")).toBe("Re: Lunch?");
    expect(replySubject("Re: Lunch?")).toBe("Re: Lunch?");
    expect(replySubject("")).toBe("Re:");
  });
});

describe("splitByRole", () => {
  it("routes recipients into to/cc/bcc and dedups", () => {
    const out = splitByRole([
      rcpt("a@x.com", "to"),
      rcpt("b@x.com", "cc"),
      rcpt("c@x.com", "bcc"),
      rcpt("d@x.com", null),
      rcpt("a@x.com", "to"),
    ]);
    expect(out.to.map((a) => a.address)).toEqual(["a@x.com", "d@x.com"]);
    expect(out.cc.map((a) => a.address)).toEqual(["b@x.com"]);
    expect(out.bcc.map((a) => a.address)).toEqual(["c@x.com"]);
  });
});

describe("composeRecipients", () => {
  it("appends free-form inviteEmails as To and dedups against recipients", () => {
    const out = composeRecipients([rcpt("a@x.com", "to")], ["b@x.com", "a@x.com"]);
    expect(out.to.map((a) => a.address)).toEqual(["a@x.com", "b@x.com"]);
  });
});

describe("deriveReplyAll", () => {
  it("folds From∪To into To, Cc into Cc, excluding self", () => {
    const out = deriveReplyAll(
      {
        from: [{ address: "jane@x.com" }],
        to: [{ address: "me@icloud.com" }, { address: "bob@x.com" }],
        cc: [{ address: "carol@x.com" }],
      },
      new Set(["me@icloud.com"])
    );
    expect(out.to.map((a) => a.address)).toEqual(["jane@x.com", "bob@x.com"]);
    expect(out.cc.map((a) => a.address)).toEqual(["carol@x.com"]);
  });
});

describe("accessContactsToRecipients", () => {
  it("maps non-self contact emails to To", () => {
    const out = accessContactsToRecipients(
      [
        { id: "1" as ActorId, email: "jane@x.com", name: "Jane" },
        { id: "2" as ActorId, email: "me@icloud.com", name: "Me" },
        { id: "3" as ActorId, email: null, name: "No Email" },
      ],
      new Set(["me@icloud.com"])
    );
    expect(out.to.map((a) => a.address)).toEqual(["jane@x.com"]);
  });
});

describe("isEmpty", () => {
  it("is true only when every bucket is empty", () => {
    expect(isEmpty({ to: [], cc: [], bcc: [] })).toBe(true);
    expect(isEmpty({ to: [{ address: "a@x.com" }], cc: [], bcc: [] })).toBe(false);
  });
});
