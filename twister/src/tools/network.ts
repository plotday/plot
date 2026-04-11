import { ITool } from "..";
import { type JSONValue, Serializable } from "../utils/types";
import { type AuthProvider, type Authorization } from "./integrations";

/**
 * Represents an incoming webhook request.
 *
 * This object is passed to webhook callback functions and contains all
 * the information about the HTTP request that triggered the webhook.
 *
 * @example
 * ```typescript
 * async onWebhookReceived(request: WebhookRequest, context: any) {
 *   console.log(`${request.method} request received`);
 *   console.log("Headers:", request.headers);
 *   console.log("Query params:", request.params);
 *   console.log("Body:", request.body);
 *   console.log("Context:", context);
 * }
 * ```
 */
export type WebhookRequest = {
  /** HTTP method of the request (GET, POST, etc.) */
  method: string;
  /** HTTP headers from the request */
  headers: Record<string, string>;
  /** Query string parameters from the request URL */
  params: Record<string, string>;
  /** Request body (parsed as JSON if applicable) */
  body: JSONValue;
  /** Raw request body (for signature verification) */
  rawBody?: string;
};

/**
 * Built-in tool for requesting HTTP access permissions and managing webhooks.
 *
 * The Network tool serves two purposes:
 * 1. Declares which URLs a twist or tool is allowed to access via HTTP/HTTPS
 * 2. Provides webhook creation and management for receiving HTTP callbacks
 *
 * **IMPORTANT**: Must be requested in the Twist or Tool Init method to declare
 * HTTP access permissions. Without requesting this tool with the appropriate URLs,
 * all outbound HTTP requests (fetch, etc.) will be blocked.
 *
 * **Permission Patterns:**
 * - `*` - Allow access to all URLs
 * - `https://*.example.com` - Allow access to all subdomains
 * - `https://api.example.com/*` - Allow access to all paths on the domain
 * - `https://api.example.com/v1/*` - Allow access to specific path prefix
 *
 * **Webhook Characteristics:**
 * - Persistent across worker restarts
 * - Automatic callback routing to parent tool/twist
 * - Support for all HTTP methods
 * - Context preservation for callback execution
 *
 * @example
 * ```typescript
 * class MyTwist extends Twist<MyTwist> {
 *   build(build: ToolBuilder) {
 *     return {
 *       // Request HTTP access to specific APIs
 *       network: build(Network, {
 *         urls: [
 *           'https://api.github.com/*',
 *           'https://api.openai.com/*'
 *         ]
 *       })
 *     };
 *   }
 * }
 * ```
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool<CalendarTool> {
 *   build(build: ToolBuilder) {
 *     return {
 *       network: build(Network, {
 *         urls: ['https://www.googleapis.com/calendar/*']
 *       })
 *     };
 *   }
 *
 *   async setupCalendarWebhook(calendarId: string) {
 *     // Create webhook URL that will call onCalendarEvent
 *     const webhookUrl = await this.tools.network.createWebhook(
 *       {},
 *       this.onCalendarEvent,
 *       calendarId,
 *       "google"
 *     );
 *
 *     // Register webhook with Google Calendar API
 *     await this.registerWithGoogleCalendar(calendarId, webhookUrl);
 *
 *     return webhookUrl;
 *   }
 *
 *   async onCalendarEvent(request: WebhookRequest, calendarId: string, provider: string) {
 *     console.log("Calendar event received:", {
 *       method: request.method,
 *       calendarId,
 *       provider,
 *       body: request.body
 *     });
 *
 *     // Process the calendar event change
 *     await this.processCalendarChange(request.body);
 *   }
 *
 *   async cleanup(webhookUrl: string) {
 *     await this.tools.network.deleteWebhook(webhookUrl);
 *   }
 * }
 * ```
 */
export abstract class Network extends ITool {
  static readonly Options: {
    /**
     * All network access is blocked except the specified URLs.
     * Wildcards (*) are supported for domains and paths.
     */
    urls: string[];
  };

  /**
   * Creates a new webhook endpoint.
   *
   * Generates a unique HTTP endpoint that will invoke the callback function
   * when requests are received. The callback receives the WebhookRequest plus any extraArgs.
   *
   * **Provider-Specific Behavior:**
   * - **Slack**: Uses provider-specific routing via team_id. Requires `authorization` parameter.
   * - **Gmail** (Google with Gmail scopes): Returns a Google Pub/Sub topic name instead of a webhook URL.
   *   The topic name (e.g., "projects/plot-prod/topics/gmail-webhook-abc123") should be passed
   *   to the Gmail API's `users.watch` endpoint. Requires `authorization` parameter with Gmail scopes.
   * - **Pub/Sub** (`pubsub: true`): Returns a Google Pub/Sub topic name instead of a webhook URL.
   *   Use this for services that deliver events via Pub/Sub (e.g., Google Workspace Events API).
   *   A Pub/Sub topic and push subscription are created automatically; the returned topic name
   *   can be passed to any Google API that accepts a Pub/Sub notification endpoint.
   * - **Default**: Returns a standard webhook URL for all other cases.
   *
   * @param options - Webhook creation options
   * @param options.provider - Optional provider for provider-specific webhook routing
   * @param options.authorization - Optional authorization for provider-specific webhooks (required for Slack and Gmail)
   * @param callback - Function receiving (request, ...extraArgs)
   * @param extraArgs - Additional arguments to pass to the callback (type-checked, no functions allowed)
   * @returns Promise resolving to the webhook URL, or for Gmail/Pub/Sub, a Pub/Sub topic name
   *
   * @example
   * ```typescript
   * // Pub/Sub webhook for Workspace Events API
   * const topicName = await this.tools.network.createWebhook(
   *   { pubsub: true },
   *   this.onEventReceived,
   *   channelId
   * );
   * // topicName: "projects/plot-prod/topics/ps-abc123"
   *
   * // Pass topic name to Workspace Events API
   * await api.createSubscription(targetResource, topicName, eventTypes);
   * ```
   *
   * @example
   * ```typescript
   * // Gmail webhook - auto-detected from scopes, returns Pub/Sub topic name
   * const topicName = await this.tools.network.createWebhook(
   *   {},
   *   this.onGmailNotification,
   *   "inbox"
   * );
   * ```
   */
  abstract createWebhook<
    TArgs extends Serializable[],
    TCallback extends (request: WebhookRequest, ...args: TArgs) => any
  >(
    options: {
      provider?: AuthProvider;
      authorization?: Authorization;
      /** When true, creates a Google Pub/Sub topic instead of a webhook URL. */
      pubsub?: boolean;
      /**
       * Controls whether the returned webhook URL runs callbacks synchronously
       * or asynchronously.
       *
       * **Async (default, `async: true`)** — Plot enqueues each incoming
       * request and immediately returns `200 { queued: true }`. A background
       * queue consumer runs the callback with bounded concurrency. The
       * sender never sees the callback's return value or any error thrown
       * by it, and delivery is at-least-once (the callback must be
       * idempotent). This is the right default for the vast majority of
       * webhooks — service event notifications, bulk-import fan-out, etc. —
       * because it removes ingress-path database pressure and prevents
       * sender-side retry storms when callbacks are slow.
       *
       * **Sync (`async: false`)** — Plot runs the callback inline and
       * responds with the callback's return value. Required when:
       * - The sender reads the response body (e.g. Microsoft Graph
       *   subscription validation, which POSTs with a `validationToken` and
       *   expects the token echoed as `text/plain`).
       * - The sender uses the HTTP status code to decide whether to retry
       *   (e.g. to surface 4xx for permanent failures).
       * - The handler must observe throws before the sender times out.
       *
       * When `async: false`, a callback returning a `string` is sent back
       * with `Content-Type: text/plain`; any other value is serialized as
       * JSON. `undefined` / `void` yields a plain `200 OK` body.
       *
       * Defaults to `true`.
       */
      async?: boolean;
    },
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<string>;

  /**
   * Deletes an existing webhook endpoint.
   *
   * Removes the webhook endpoint and stops processing requests.
   * Works with all webhook types (standard, Slack, and Gmail).
   *
   * **For Gmail webhooks:** Also deletes the associated Google Pub/Sub topic and subscription.
   *
   * **For Slack webhooks:** Removes the callback registration for the specific team.
   *
   * **For standard webhooks:** Removes the webhook endpoint. Any subsequent requests
   * to the deleted webhook will return 404.
   *
   * @param url - The webhook identifier returned from `createWebhook()`.
   *              This can be a URL (standard webhooks), a Pub/Sub topic name (Gmail),
   *              or an opaque identifier (Slack). Always pass the exact value returned
   *              from `createWebhook()`.
   * @returns Promise that resolves when the webhook is deleted
   */
  abstract deleteWebhook(url: string): Promise<void>;
}
