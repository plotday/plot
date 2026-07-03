import { describe, expect, it, vi } from "vitest";

import type { PostHog } from "posthog-node";

import { captureTwistBatchError } from "./updates";

function makePostHog() {
  const captureException = vi.fn();
  return {
    postHog: { captureException } as unknown as PostHog,
    captureException,
  };
}

describe("captureTwistBatchError suppresses expected infra/provider blips", () => {
  it("skips a Durable Object storage-startup reset wrapped as a TwistError", () => {
    // The updates-queue path wraps connector-callback throws in a
    // `__TWIST_ERROR__` envelope as they cross the twist RPC boundary, so the
    // Cloudflare marker is embedded as a substring. isTransientDoResetError
    // still matches it. Without this the fault was captured once per affected
    // item (PostHog issue 019f277a: 30 captures from Google.onThreadRead).
    const { postHog, captureException } = makePostHog();
    captureTwistBatchError(
      postHog,
      new Error(
        'TwistError: __TWIST_ERROR__{"message":"Internal error while starting ' +
          'up Durable Object storage caused object to be reset; reference = ' +
          'imgca96kon4vhhsprpjhpbdo","operation":"dispatch: onThreadRead"}'
      ),
      "user-1",
      { queue: "twist-batch" }
    );
    expect(captureException).not.toHaveBeenCalled();
  });

  it("skips downstream rate-limit and terminal auth errors", () => {
    const { postHog, captureException } = makePostHog();
    captureTwistBatchError(
      postHog,
      new Error("Gmail API error: 403 - rateLimitExceeded"),
      "user-1",
      {}
    );
    captureTwistBatchError(
      postHog,
      new Error("401 Unauthorized - Invalid Credentials"),
      "user-1",
      {}
    );
    expect(captureException).not.toHaveBeenCalled();
  });

  it("captures a genuine connector bug", () => {
    const { postHog, captureException } = makePostHog();
    const bug = new Error("Cannot read properties of undefined (reading 'id')");
    captureTwistBatchError(postHog, bug, "user-1", { queue: "twist-batch" });
    expect(captureException).toHaveBeenCalledTimes(1);
    expect(captureException).toHaveBeenCalledWith(bug, "user-1", {
      queue: "twist-batch",
    });
  });
});
