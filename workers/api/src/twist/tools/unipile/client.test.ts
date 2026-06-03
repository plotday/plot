import { describe, it, expect, test } from "vitest";
import { UnipileClient, UnipileApiError } from "./client";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_DSN: "api7.unipile.com:13441",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
};

/**
 * Create a UnipileClient whose fetch is replaced with a recording stub.
 * Returns the client plus the array of {url, init} the client invoked fetch
 * with, so tests can assert on the request without spying on global fetch
 * (which has Cloudflare-typed overloads that don't play well with vi.spyOn).
 */
function recordingClient(response: () => Response): {
  client: UnipileClient;
  calls: { url: string; init: RequestInit }[];
} {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return response();
  }) as unknown as typeof fetch;
  return { client: new UnipileClient(env, fetchImpl), calls };
}

describe("UnipileClient", () => {
  it("sends the API key header and uses the configured DSN", async () => {
    const { client, calls } = recordingClient(
      () =>
        new Response(JSON.stringify({ object: "ChatList", items: [], cursor: null }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
    );

    await client.listChats({ accountId: "acct-1" });

    expect(calls).toHaveLength(1);
    // (DSN is used verbatim — full host:port — not a region shortcode.)
    expect(calls[0]!.url).toBe(
      "https://api7.unipile.com:13441/api/v1/chats?account_id=acct-1"
    );
    const headers = calls[0]!.init.headers as Record<string, string>;
    expect(headers["X-API-KEY"]).toBe("test-key");
    expect(headers.accept).toBe("application/json");
  });

  it("throws UnipileApiError with status on non-2xx", async () => {
    const { client } = recordingClient(
      () =>
        new Response('{"status":401,"title":"Unauthorized"}', {
          status: 401,
          headers: { "content-type": "application/json" },
        })
    );
    const err = await client
      .listChats({ accountId: "acct-1" })
      .then(() => null)
      .catch((e: unknown) => e);
    expect(err).toBeInstanceOf(UnipileApiError);
    expect((err as UnipileApiError).status).toBe(401);
  });

  test("startChat posts /chats with attendees and optional title", async () => {
    const { client, calls } = recordingClient(
      () => new Response(JSON.stringify({ id: "msg1", chat_id: "chat1" }), { status: 200 })
    );
    await client.startChat({
      accountId: "acc1",
      attendeeProviderIds: ["a", "b"],
      text: "hi",
      title: "Crew",
    });
    expect(calls[0]!.url).toMatch(/\/chats$/);
    expect(calls[0]!.init.method).toBe("POST");
    const form = calls[0]!.init.body as FormData;
    expect(form.get("account_id")).toBe("acc1");
    expect(form.getAll("attendees_ids")).toEqual(["a", "b"]);
    expect(form.get("text")).toBe("hi");
    expect(form.get("title")).toBe("Crew");
  });

  describe("removeMessageReaction", () => {
    it("posts empty reaction first and returns on success", async () => {
      const { client, calls } = recordingClient(
        () => new Response(JSON.stringify({}), { status: 200 })
      );
      await client.removeMessageReaction({ messageId: "msg1" });
      expect(calls).toHaveLength(1);
      expect(calls[0]!.url).toMatch(/\/messages\/msg1\/reactions$/);
      expect(calls[0]!.init.method).toBe("POST");
    });

    it("falls back to DELETE when POST returns 400", async () => {
      let callCount = 0;
      const { client, calls } = recordingClient(() => {
        callCount++;
        if (callCount === 1) {
          return new Response(JSON.stringify({ error: "bad" }), { status: 400 });
        }
        return new Response(null, { status: 204 });
      });
      await client.removeMessageReaction({ messageId: "msg2" });
      expect(calls).toHaveLength(2);
      expect(calls[1]!.init.method).toBe("DELETE");
    });

    it("swallows DELETE 404/405 without throwing", async () => {
      let callCount = 0;
      const { client } = recordingClient(() => {
        callCount++;
        const status = callCount === 1 ? 405 : 404;
        return new Response(JSON.stringify({ error: "not found" }), { status });
      });
      await expect(client.removeMessageReaction({ messageId: "msg3" })).resolves.toBeUndefined();
    });
  });

  it("listAccounts walks pages and concatenates items", async () => {
    const pages = [
      JSON.stringify({
        object: "AccountList",
        items: [{ object: "Account", id: "acct-1", type: "LINKEDIN", created_at: "2026-01-01T00:00:00Z", sources: [] }],
        cursor: "page-2",
      }),
      JSON.stringify({
        object: "AccountList",
        items: [{ object: "Account", id: "acct-2", type: "LINKEDIN", created_at: "2026-01-02T00:00:00Z", sources: [] }],
        cursor: null,
      }),
    ];
    let page = 0;
    const { client, calls } = recordingClient(
      () =>
        new Response(pages[page++]!, {
          status: 200,
          headers: { "content-type": "application/json" },
        })
    );

    const accounts = await client.listAccounts();

    expect(calls).toHaveLength(2);
    expect(calls[0]!.url).toBe(
      "https://api7.unipile.com:13441/api/v1/accounts"
    );
    expect(calls[1]!.url).toBe(
      "https://api7.unipile.com:13441/api/v1/accounts?cursor=page-2"
    );
    expect(accounts.map((a) => a.id)).toEqual(["acct-1", "acct-2"]);
  });

  it("listRelations sends account_id and parses the relations list", async () => {
    const { client, calls } = recordingClient(
      () =>
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

    const result = await client.listRelations({
      accountId: "acct-1",
      cursor: "prev-cursor",
      limit: 50,
    });

    expect(calls[0]!.url).toBe(
      "https://api7.unipile.com:13441/api/v1/users/relations?account_id=acct-1&cursor=prev-cursor&limit=50"
    );
    expect(result.object).toBe("UserRelationsList");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]!.member_id).toBe("ACoAA123");
    expect(result.cursor).toBe("next-page-token");
  });
});
