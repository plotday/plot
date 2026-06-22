import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createPushSubscription, createTopic } from "./pubsub";

// getGcpAccessToken does real JWT crypto + a token fetch; mock it so the only
// `fetch` calls left in these tests are the Pub/Sub API requests under test.
// vi.mock is hoisted above the import, so the mock is in place before use.
vi.mock("./gcp-auth", () => ({
  getGcpAccessToken: vi.fn(async () => "fake-access-token"),
}));

const CONFIG = {
  projectId: "plot-prod",
  serviceAccountEmail: "svc@plot-prod.iam.gserviceaccount.com",
  serviceAccountKey: "fake-key",
};

/** A minimal Response-like object for the fetch mock. */
function res(status: number, body = ""): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => body,
    json: async () => (body ? JSON.parse(body) : {}),
  } as unknown as Response;
}

describe("pubsub transient-error retry", () => {
  beforeEach(() => {
    // Drive backoff deterministically without real wall-clock waits.
    vi.useFakeTimers();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("createTopic retries a transient 500 and succeeds on a later attempt", async () => {
    // This is the exact PostHog failure: pubsub.googleapis.com returned a
    // transient `error code: 500` body on topic creation. A single blip must
    // not surface as a captured exception — the retry should recover.
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(res(500, "error code: 500\n"))
      .mockResolvedValueOnce(res(200, "{}"));
    vi.stubGlobal("fetch", fetchMock);

    const promise = createTopic(CONFIG, "gmail-webhook-abc123");
    await vi.runAllTimersAsync();
    const topicName = await promise;

    expect(topicName).toBe("projects/plot-prod/topics/gmail-webhook-abc123");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("createTopic throws after exhausting retries on a persistent 500", async () => {
    const fetchMock = vi.fn().mockResolvedValue(res(500, "error code: 500\n"));
    vi.stubGlobal("fetch", fetchMock);

    const promise = createTopic(CONFIG, "gmail-webhook-abc123");
    // Attach a rejection handler before advancing timers so an unhandled
    // rejection isn't reported during the fake-timer run.
    const settled = expect(promise).rejects.toThrow(
      /Failed to create Pub\/Sub topic/
    );
    await vi.runAllTimersAsync();
    await settled;

    // 1 initial attempt + 2 retries.
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  it("createTopic does NOT retry a non-transient 4xx", async () => {
    // 409 = topic already exists; retrying is pointless and would just delay
    // the (permanent) failure.
    const fetchMock = vi.fn().mockResolvedValue(res(409, "ALREADY_EXISTS"));
    vi.stubGlobal("fetch", fetchMock);

    const promise = createTopic(CONFIG, "gmail-webhook-abc123");
    const settled = expect(promise).rejects.toThrow(
      /Failed to create Pub\/Sub topic/
    );
    await vi.runAllTimersAsync();
    await settled;

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("createPushSubscription also retries a transient 503", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(res(503, "Service Unavailable"))
      .mockResolvedValueOnce(res(200, "{}"));
    vi.stubGlobal("fetch", fetchMock);

    const promise = createPushSubscription(CONFIG, {
      topicName: "projects/plot-prod/topics/gmail-webhook-abc123",
      subscriptionName: "gmail-webhook-abc123",
      pushEndpoint: "https://api.plot.day/hook/gmail/gmail-webhook-abc123",
    });
    await vi.runAllTimersAsync();
    await expect(promise).resolves.toBeUndefined();

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
