import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { UnipileClient, UnipileApiError } from "./client";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_DSN: "api7.unipile.com:13441",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
};

describe("UnipileClient", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    fetchSpy.mockRestore();
  });

  it("sends the API key header and uses the configured DSN", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ object: "ChatList", items: [], cursor: null }), {
        status: 200,
        headers: { "content-type": "application/json" },
      })
    );

    const client = new UnipileClient(env);
    await client.listChats({ accountId: "acct-1" });

    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api7.unipile.com:13441/api/v1/chats?account_id=acct-1"
    );
    // (DSN is used verbatim — full host:port — not a region shortcode.)
    expect((init?.headers as Record<string, string>)["X-API-KEY"]).toBe(
      "test-key"
    );
    expect((init?.headers as Record<string, string>).accept).toBe(
      "application/json"
    );
  });

  it("throws UnipileApiError with status on non-2xx", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response('{"status":401,"title":"Unauthorized"}', {
        status: 401,
        headers: { "content-type": "application/json" },
      })
    );
    const client = new UnipileClient(env);
    const err = await client
      .listChats({ accountId: "acct-1" })
      .then(() => null)
      .catch((e: unknown) => e);
    expect(err).toBeInstanceOf(UnipileApiError);
    expect((err as UnipileApiError).status).toBe(401);
  });

  it("listRelations sends account_id and parses the relations list", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          object: "UserRelationsList",
          items: [
            {
              object: "UserRelation",
              member_id: "ACoAA123",
              member_urn: "urn:li:member:123",
              connection_urn: "urn:li:fs_miniProfile:123",
              first_name: "Ada",
              last_name: "Lovelace",
              headline: "Computing pioneer",
              public_identifier: "adalovelace",
              public_profile_url: "https://www.linkedin.com/in/adalovelace",
              profile_picture_url: "https://media.licdn.com/ada.jpg",
              created_at: 1700000000,
            },
          ],
          cursor: "next-page-token",
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      )
    );

    const client = new UnipileClient(env);
    const result = await client.listRelations({
      accountId: "acct-1",
      cursor: "prev-cursor",
      limit: 50,
    });

    const [url] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api7.unipile.com:13441/api/v1/users/relations?account_id=acct-1&cursor=prev-cursor&limit=50"
    );
    expect(result.object).toBe("UserRelationsList");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]!.member_id).toBe("ACoAA123");
    expect(result.cursor).toBe("next-page-token");
  });
});
