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

  // Update person properties in PostHog via a `$set` event. Uses `$set`/
  // `$set_once` so we can populate person profiles without emitting an
  // `$identify` — avoids PostHog's anonymous→identified merge semantics,
  // which don't apply when the server already knows the canonical user_id.
  setPersonProperties(
    distinctId: string,
    properties: Record<string, any>,
    setOnce?: Record<string, any>,
  ) {
    const eventProperties: Record<string, any> = { $set: properties };
    if (setOnce && Object.keys(setOnce).length > 0) {
      eventProperties.$set_once = setOnce;
    }
    this._postHog.capture({
      distinctId,
      event: "$set",
      properties: eventProperties,
    });
  }

  shutdown(timeoutMs?: number) {
    return this._postHog.shutdown(timeoutMs);
  }
}
