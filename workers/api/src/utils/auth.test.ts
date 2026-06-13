import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { verifyToken } from "@clerk/backend";

import { getUser } from "./auth";

// verifyToken does real crypto against a PEM key; mock it so we can drive the
// "JWT verifies" vs. "JWT rejected" branches independently of the DB outcome.
// vi.mock is hoisted above these imports, so the mock is in place before use.
vi.mock("@clerk/backend", () => ({
  verifyToken: vi.fn(),
}));

// getUser does atob(jwtKey); any valid base64 works since verifyToken is mocked.
const JWT_KEY = btoa("dummy-pem-key");

/** Minimal Kysely chain mock: selectFrom().select().where().executeTakeFirst(). */
function mockDb(executeTakeFirst: () => Promise<unknown>) {
  const query: any = {};
  query.select = vi.fn(() => query);
  query.where = vi.fn(() => query);
  query.executeTakeFirst = vi.fn(executeTakeFirst);
  return { selectFrom: vi.fn(() => query) };
}

describe("getUser", () => {
  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("flags dbUnavailable (not an auth failure) when the user lookup throws", async () => {
    // JWT is perfectly valid...
    (verifyToken as any).mockResolvedValue({
      sub: "user_clerk123",
      external_id: "00000000-0000-0000-0000-000000000001",
      email: "a@b.com",
    });
    // ...but Postgres is in recovery, so the lookup throws.
    const db = mockDb(async () => {
      throw new Error("the database system is in recovery mode");
    });

    const res = await getUser(db as any, "tok", JWT_KEY);

    expect(res.user).toBeNull();
    expect(res.dbUnavailable).toBe(true);
    // Claims survive: the credentials were valid, the DB was just down. This is
    // what lets the middleware return 503 instead of a session-killing 401.
    expect(res.claims?.clerkId).toBe("user_clerk123");
    expect(res.error).toBeInstanceOf(Error);
  });

  it("does NOT flag dbUnavailable when the JWT itself is rejected", async () => {
    (verifyToken as any).mockRejectedValue(new Error("token expired"));
    const db = mockDb(async () => null);

    const res = await getUser(db as any, "tok", JWT_KEY);

    expect(res.user).toBeNull();
    expect(res.claims).toBeNull();
    expect(res.dbUnavailable).toBeFalsy();
  });

  it("returns the user on the happy path without dbUnavailable", async () => {
    (verifyToken as any).mockResolvedValue({
      sub: "user_clerk123",
      external_id: "00000000-0000-0000-0000-000000000001",
      email: "a@b.com",
    });
    const db = mockDb(async () => ({
      email: "a@b.com",
      name: "Ada",
      clerk_id: "user_clerk123",
    }));

    const res = await getUser(db as any, "tok", JWT_KEY);

    expect(res.user?.id).toBe("00000000-0000-0000-0000-000000000001");
    expect(res.user?.email).toBe("a@b.com");
    expect(res.dbUnavailable).toBeFalsy();
    expect(res.error).toBeNull();
  });

  it("returns claims with no user (new user) when the lookup finds no row", async () => {
    (verifyToken as any).mockResolvedValue({
      sub: "user_clerk_new",
      email: "new@b.com",
    });
    // No external_id → falls through to clerk_id lookup, which returns nothing.
    const db = mockDb(async () => undefined);

    const res = await getUser(db as any, "tok", JWT_KEY);

    expect(res.user).toBeNull();
    expect(res.claims?.clerkId).toBe("user_clerk_new");
    expect(res.dbUnavailable).toBeFalsy();
    expect(res.error).toBeNull();
  });
});
