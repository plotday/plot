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

  // Update person properties in PostHog. Uses the `$set` pattern attached to
  // a `$set` event so we can update properties without emitting an
  // `$identify` (the Flutter app owns identify).
  setPersonProperties(
    distinctId: string,
    properties: Record<string, any>,
  ) {
    this._postHog.capture({
      distinctId,
      event: "$set",
      properties: { $set: properties },
    });
  }

  shutdown(timeoutMs?: number) {
    return this._postHog.shutdown(timeoutMs);
  }
}
