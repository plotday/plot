import type { PostHog } from "posthog-node";

export class Tracker {
  constructor(
    private _postHog: PostHog,
    private _distinctId?: string,
  ) {}

  setDistinctId(distinctId: string) {
    this._distinctId = distinctId;
  }

  captureException(
    error: unknown,
    additionalProperties?: Record<string | number, any>,
  ) {
    this._postHog.captureException(error, this._distinctId, additionalProperties);
  }

  capture(event: string, properties?: Record<string | number, any>) {
    this._postHog.capture({
      distinctId: this._distinctId ?? "$anonymous",
      event,
      properties,
    });
  }

  shutdown(timeoutMs?: number) {
    return this._postHog.shutdown(timeoutMs);
  }
}
