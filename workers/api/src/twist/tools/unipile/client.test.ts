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
});
