import { describe, expect, it } from "vitest";

import { exceptionFingerprint } from "./exception-fingerprint";

// Real `$exception_values` samples that all collapsed into one PostHog issue
// (019ed581) because they share the generic queue → handleTwistOperation →
// callCallback stack. A type+message fingerprint must pull them apart while
// still grouping repeats of the *same* logical error (volatile ids normalized).
describe("exceptionFingerprint", () => {
  it("gives distinct fingerprints to distinct error families", () => {
    const pubsub = exceptionFingerprint(
      "Error",
      "Failed to create Gmail webhook: Failed to create Pub/Sub topic: error code: 500\n"
    );
    const memory = exceptionFingerprint("Error", "Worker exceeded memory limit.");
    const stmtTimeout = exceptionFingerprint(
      "Error",
      "error: canceling statement due to statement timeout"
    );
    const poolTimeout = exceptionFingerprint(
      "Error",
      "error: Timed out while waiting for an open slot in the pool."
    );

    const all = [pubsub, memory, stmtTimeout, poolTimeout];
    expect(new Set(all).size).toBe(all.length); // all different
  });

  it("groups the same error regardless of a volatile UUID", () => {
    const a = exceptionFingerprint(
      "Error",
      "Sync state not found for project 1c043f04-7c09-4eb9-8d9f-b0ef8b23b52a"
    );
    const b = exceptionFingerprint(
      "Error",
      "Sync state not found for project 9f8e7d6c-5b4a-3210-fedc-ba9876543210"
    );
    expect(a).toBe(b);
  });

  it("groups the same error regardless of a volatile channel id", () => {
    const a = exceptionFingerprint(
      "Error",
      "linkedin channel 1UCBa5dUTXmZFjJebjDtKA has no stored credentials — reconnect"
    );
    const b = exceptionFingerprint(
      "Error",
      "linkedin channel vn_1VVHyQxSr70AX8REoxw has no stored credentials — reconnect"
    );
    expect(a).toBe(b);
  });

  it("ignores the leading 'Error: ' prefix some captures carry", () => {
    const bare = exceptionFingerprint("Error", "Worker exceeded memory limit.");
    const prefixed = exceptionFingerprint(
      "Error",
      "Error: Worker exceeded memory limit."
    );
    expect(prefixed).toBe(bare);
  });

  it("unwraps nested __TWIST_ERROR__ envelopes to the leaf message", () => {
    // Two deploys produce the same logical error at different line numbers; the
    // fingerprint must group them and must not contain the giant JSON blob.
    const v1 =
      'TwistError: __TWIST_ERROR__{"message":"__TWIST_ERROR__{\\"message\\":\\"No Google authentication token available\\",\\"twistStack\\":\\"Error: No Google authentication token available\\\\n    at _Gmail.getApi (twist.js:2241:13)\\",\\"operation\\":\\"dispatch sourceMethod: onThreadToDo\\",\\"originalError\\":\\"Error\\"}","operation":"dispatchToTool(1 path)","originalError":"TwistError"}';
    const v2 = v1.replace("twist.js:2241:13", "twist.js:2359:17");

    const fp1 = exceptionFingerprint("TwistError", v1);
    const fp2 = exceptionFingerprint("TwistError", v2);

    expect(fp1).toBe(fp2);
    expect(fp1).toContain("No Google authentication token available");
    expect(fp1).not.toContain("__TWIST_ERROR__");
  });

  it("bounds fingerprint length", () => {
    const fp = exceptionFingerprint("Error", "x".repeat(5000));
    expect(fp.length).toBeLessThanOrEqual(200);
  });
});
