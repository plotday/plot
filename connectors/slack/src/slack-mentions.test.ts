import { describe, expect, it } from "vitest";

import { mentionsUser, type MentionContext } from "./slack-mentions";

const ctx: MentionContext = {
  userId: "U111",
  userGroupIds: new Set(["S222"]),
};

describe("mentionsUser", () => {
  it("matches a direct mention", () => {
    expect(mentionsUser("hey <@U111> can you look", ctx)).toBe(true);
  });

  it("matches a direct mention carrying a label", () => {
    expect(mentionsUser("<@U111|negin> ping", ctx)).toBe(true);
  });

  it("ignores a mention of someone else", () => {
    expect(mentionsUser("hey <@U999> can you look", ctx)).toBe(false);
  });

  it("ignores a user id that merely prefixes ours", () => {
    expect(mentionsUser("hey <@U1112> hello", ctx)).toBe(false);
  });

  it("matches a user group the user belongs to", () => {
    expect(mentionsUser("<!subteam^S222|@eng> standup", ctx)).toBe(true);
  });

  it("matches a bare user-group mention", () => {
    expect(mentionsUser("<!subteam^S222> standup", ctx)).toBe(true);
  });

  it("ignores a user group the user does not belong to", () => {
    expect(mentionsUser("<!subteam^S333|@design> standup", ctx)).toBe(false);
  });

  it.each(["<!here>", "<!channel>", "<!everyone>", "<!here|@here>"])(
    "matches the broadcast mention %s",
    (token) => {
      expect(mentionsUser(`${token} deploy in 5`, ctx)).toBe(true);
    }
  );

  it("ignores plain text that looks like a mention", () => {
    expect(mentionsUser("email me @U111 later", ctx)).toBe(false);
  });

  it("handles missing text", () => {
    expect(mentionsUser(undefined, ctx)).toBe(false);
  });
});
