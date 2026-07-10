import { describe, it, expect, test, vi } from "vitest";
import { UnipileClient, UnipileApiError } from "./client";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
};

const BASE = "https://api.unipile.com";

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

describe("UnipileClient (v2)", () => {
  it("sends the API key header and uses the v2 host + account-in-path", async () => {
    const { client, calls } = recordingClient(
      () =>
        new Response(JSON.stringify({ object: "ChatList", data: [], has_more: false }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
    );

    await client.listChats({ accountId: "acct-1" });

    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(`${BASE}/v2/acct-1/chats`);
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

  test("sendMessage posts to the v2 send path", async () => {
    const { client, calls } = recordingClient(
      () => new Response(JSON.stringify({ object: "Message", id: "m" }), { status: 200 })
    );
    await client.sendMessage({ accountId: "acc1", chatId: "c1", text: "hi" });
    expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/chats/c1/messages/send`);
    expect(calls[0]!.init.method).toBe("POST");
    expect(JSON.parse(String(calls[0]!.init.body))).toEqual({ text: "hi" });
  });

  test("startChat posts /v2/:account/chats/send with users_ids and name", async () => {
    const { client, calls } = recordingClient(
      () => new Response(JSON.stringify({ object: "Message", id: "msg1", chat_id: "chat1" }), { status: 200 })
    );
    await client.startChat({
      accountId: "acc1",
      attendeeProviderIds: ["a", "b"],
      text: "hi",
      title: "Crew",
    });
    expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/chats/send`);
    expect(calls[0]!.init.method).toBe("POST");
    const body = JSON.parse(String(calls[0]!.init.body));
    expect(body.users_ids).toEqual(["a", "b"]);
    expect(body.text).toBe("hi");
    expect(body.name).toBe("Crew");
  });

  test("getOwnProfile targets /v2/:account/users/me", async () => {
    const { client, calls } = recordingClient(
      () => new Response(JSON.stringify({ object: "UserProfile", id: "me" }), { status: 200 })
    );
    await client.getOwnProfile({ accountId: "acc1" });
    expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/users/me`);
  });

  test("createHostedAuthLink posts the v2 body (lowercase providers, redirect_uri) and reads `link`", async () => {
    const { client, calls } = recordingClient(
      () => new Response(JSON.stringify({ object: "HostedAuthLink", link: "https://auth.unipile.com/?token=abc" }), { status: 200 })
    );
    const res = await client.createHostedAuthLink({
      providers: ["LINKEDIN"],
      name: "state1",
      successRedirectUrl: "https://api.example/auth/hosted/success?state=state1",
      failureRedirectUrl: "https://api.example/auth/hosted/failure?state=state1",
      notifyUrl: "https://api.example/hook/messaging",
      expiresAt: new Date("2026-01-01T00:00:00.000Z"),
    });
    expect(calls[0]!.url).toBe(`${BASE}/v2/auth/link`);
    expect(calls[0]!.init.method).toBe("POST");
    const body = JSON.parse(String(calls[0]!.init.body));
    expect(body.providers).toEqual(["linkedin"]);
    expect(body.redirect_uri).toBe("https://api.example/auth/hosted/success?state=state1");
    expect(body.expires_on).toBe("2026-01-01T00:00:00.000Z");
    expect(body.notify_url).toBe("https://api.example/hook/messaging");
    expect(body.name).toBe("state1");
    // Response carries the wizard URL under `link`, not `url`.
    expect(res.url).toBe("https://auth.unipile.com/?token=abc");
  });

  describe("removeMessageReaction", () => {
    it("posts empty reaction first and returns on success", async () => {
      const { client, calls } = recordingClient(
        () => new Response(JSON.stringify({}), { status: 200 })
      );
      await client.removeMessageReaction({ accountId: "acc1", chatId: "c1", messageId: "msg1" });
      expect(calls).toHaveLength(1);
      expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/chats/c1/messages/msg1/reactions`);
      expect(calls[0]!.init.method).toBe("POST");
      expect(JSON.parse(String(calls[0]!.init.body))).toEqual({ reaction: "" });
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
      await client.removeMessageReaction({ accountId: "acc1", chatId: "c1", messageId: "msg2" });
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
      await expect(
        client.removeMessageReaction({ accountId: "acc1", chatId: "c1", messageId: "msg3" })
      ).resolves.toBeUndefined();
    });
  });

  it("listAccounts walks offset pages until has_more is false", async () => {
    const pages = [
      JSON.stringify({
        object: "Accounts",
        data: [{ object: "Account", id: "acc-1", user_id: "u1", provider: "LINKEDIN", status: "running", created_at: "2026-01-01T00:00:00Z" }],
        has_more: true,
      }),
      JSON.stringify({
        object: "Accounts",
        data: [{ object: "Account", id: "acc-2", user_id: "u2", provider: "LINKEDIN", status: "running", created_at: "2026-01-02T00:00:00Z" }],
        has_more: false,
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
    expect(calls[0]!.url).toBe(`${BASE}/v2/accounts?limit=100`);
    expect(calls[1]!.url).toBe(`${BASE}/v2/accounts?limit=100&offset=1`);
    expect(accounts.map((a) => a.id)).toEqual(["acc-1", "acc-2"]);
  });

  it("listRelations targets the me-scoped route and returns {data, next_cursor}", async () => {
    const { client, calls } = recordingClient(
      () =>
        new Response(
          JSON.stringify({
            data: [
              {
                object: "UserRelation",
                id: "rel-1",
                user: { object: "User", id: "ACoAA123", display_name: "Ada Lovelace", public_identifier: "adalovelace" },
                created_at: "2026-01-01T00:00:00.000Z",
              },
            ],
            next_cursor: null,
          }),
          { status: 200, headers: { "content-type": "application/json" } }
        )
    );

    const result = await client.listRelations({ accountId: "acct-1", limit: 50 });

    expect(calls[0]!.url).toBe(`${BASE}/v2/acct-1/users/me/relations?limit=50`);
    expect(result.data).toHaveLength(1);
    expect(result.data[0]!.user.id).toBe("ACoAA123");
    expect(result.next_cursor).toBeNull();
  });

  test("acceptInvitation posts the v2 accept route (no shared_secret)", async () => {
    const { client, calls } = recordingClient(() => new Response(null, { status: 204 }));
    await client.acceptInvitation({ accountId: "acc1", invitationId: "rr_1" });
    expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/users/me/relation-requests/rr_1/accept`);
    expect(calls[0]!.init.method).toBe("POST");
  });

  test("ignoreInvitation posts the v2 cancel route", async () => {
    const { client, calls } = recordingClient(() => new Response(null, { status: 204 }));
    await client.ignoreInvitation({ accountId: "acc1", invitationId: "rr_2" });
    expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/users/me/relation-requests/rr_2/cancel`);
    expect(calls[0]!.init.method).toBe("POST");
  });

  test("retries on 429 (rate limit) then succeeds", async () => {
    vi.useFakeTimers();
    try {
      let n = 0;
      const { client, calls } = recordingClient(() => {
        n++;
        if (n < 3) {
          return new Response(JSON.stringify({ status: 429 }), { status: 429 });
        }
        return new Response(JSON.stringify({ object: "ChatList", data: [], has_more: false }), { status: 200 });
      });
      const p = client.listChats({ accountId: "acct-1" });
      await vi.runAllTimersAsync();
      const result = await p;
      expect(calls).toHaveLength(3); // two 429s + one success
      expect(result.data).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  test("gives up after the retry cap and throws the 429", async () => {
    vi.useFakeTimers();
    try {
      const { client } = recordingClient(() => new Response(JSON.stringify({ status: 429 }), { status: 429 }));
      const p = client.listChats({ accountId: "acct-1" }).catch((e: unknown) => e);
      await vi.runAllTimersAsync();
      const err = await p;
      expect(err).toBeInstanceOf(UnipileApiError);
      expect((err as UnipileApiError).status).toBe(429);
    } finally {
      vi.useRealTimers();
    }
  });

  describe("setChatRead", () => {
    // Unipile's PATCH .../chats/:id endpoint has a single action,
    // "setReadStatus", toggled by a boolean "value" — there is no separate
    // "setUnreadStatus" action (per developer.unipile.com/reference/chatscontroller_patchchat).
    it("sends action=setReadStatus with value=true when marking read", async () => {
      const { client, calls } = recordingClient(() => new Response(null, { status: 204 }));
      await client.setChatRead({ accountId: "acc1", chatId: "c1", read: true });
      expect(calls).toHaveLength(1);
      expect(calls[0]!.url).toBe(`${BASE}/v2/acc1/chats/c1`);
      expect(calls[0]!.init.method).toBe("PATCH");
      expect(JSON.parse(calls[0]!.init.body as string)).toEqual({
        action: "setReadStatus",
        value: true,
      });
    });

    it("sends action=setReadStatus with value=false when marking unread", async () => {
      const { client, calls } = recordingClient(() => new Response(null, { status: 204 }));
      await client.setChatRead({ accountId: "acc1", chatId: "c1", read: false });
      expect(JSON.parse(calls[0]!.init.body as string)).toEqual({
        action: "setReadStatus",
        value: false,
      });
    });
  });
});
