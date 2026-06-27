import { afterEach, describe, expect, it, vi } from "vitest";
import {
  PROVIDER_CONFIGS,
  parseTrelloTokenResponse,
  extractUserId,
  type TrelloProviderData,
} from "./provider";

afterEach(() => vi.restoreAllMocks());

describe("trello provider config", () => {
  it("is a token-fragment provider with no tokenUrl", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.authMode).toBe("token-fragment");
    expect(cfg.authUrl).toBe("https://trello.com/1/authorize");
    expect(cfg.tokenUrl).toBeUndefined();
    expect(cfg.requiresHttpsRedirect).toBe(true);
  });

  it("extractAccountLabel prefers fullName, falls back to username", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.extractAccountLabel?.({ memberId: "m1", username: "u", fullName: "Full" } as TrelloProviderData)).toBe("Full");
    expect(cfg.extractAccountLabel?.({ memberId: "m1", username: "u", fullName: null } as TrelloProviderData)).toBe("u");
  });

  it("extractMetadata exposes the member id", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.extractMetadata?.({ memberId: "m1", username: "u", fullName: "F" } as TrelloProviderData)).toEqual({ memberId: "m1" });
  });
});

describe("parseTrelloTokenResponse", () => {
  it("fetches /members/me with the key+token and maps the result", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ id: "member-123", username: "kris", fullName: "Kris B" }), { status: 200 }),
    );
    const data = await parseTrelloTokenResponse({ access_token: "tok-abc", key: "key-xyz" });
    expect(data).toEqual({ memberId: "member-123", username: "kris", fullName: "Kris B" });
    const calledUrl = fetchMock.mock.calls[0][0] as string;
    expect(calledUrl).toContain("https://api.trello.com/1/members/me");
    expect(calledUrl).toContain("key=key-xyz");
    expect(calledUrl).toContain("token=tok-abc");
  });

  it("returns undefined when there is no access_token", async () => {
    expect(await parseTrelloTokenResponse({ key: "key-xyz" })).toBeUndefined();
  });

  it("returns undefined on a non-ok response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("nope", { status: 401 }));
    expect(await parseTrelloTokenResponse({ access_token: "t", key: "k" })).toBeUndefined();
  });
});

describe("extractUserId", () => {
  it("returns the trello member id", () => {
    expect(extractUserId("trello" as any, { memberId: "member-123", username: "k", fullName: "K" } as TrelloProviderData)).toBe("member-123");
  });
});
