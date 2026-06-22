import { afterEach, describe, expect, it, vi } from "vitest";

import { GoogleApi } from "./google-api";

/**
 * Stub the global `fetch` with a single canned Response and return the spy so
 * tests can assert on what was sent.
 */
function stubFetch(response: Response) {
  const spy = vi.fn(async () => response);
  vi.stubGlobal("fetch", spy);
  return spy;
}

describe("GoogleApi.call", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("treats 204 No Content as success (channels/stop)", async () => {
    // Google's channels/stop endpoint returns 204 with an empty body on
    // success. The call must NOT throw — a 204 is success, not an error.
    stubFetch(new Response(null, { status: 204 }));

    const api = new GoogleApi("token");
    const result = await api.call(
      "POST",
      "https://www.googleapis.com/drive/v3/channels/stop",
      undefined,
      { id: "watch-id", resourceId: "resource-id" }
    );

    expect(result).toBeNull();
  });

  it("treats 200 with a JSON body as success and returns the parsed body", async () => {
    stubFetch(
      new Response(JSON.stringify({ files: [{ id: "file-1" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    );

    const api = new GoogleApi("token");
    const result = await api.call(
      "GET",
      "https://www.googleapis.com/drive/v3/files"
    );

    expect(result).toEqual({ files: [{ id: "file-1" }] });
  });

  it("returns null for 410 Gone", async () => {
    stubFetch(new Response("gone", { status: 410 }));

    const api = new GoogleApi("token");
    const result = await api.call("GET", "https://example.com");

    expect(result).toBeNull();
  });

  it("throws on a genuine server error", async () => {
    stubFetch(new Response("boom", { status: 500 }));

    const api = new GoogleApi("token");
    await expect(api.call("GET", "https://example.com")).rejects.toThrow(
      /boom/
    );
  });
});
