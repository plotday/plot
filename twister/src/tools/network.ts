import { ITool } from "..";
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
  body: any;
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
 *     const webhookUrl = await this.tools.network.createWebhook({
 *       callback: this.onCalendarEvent,
 *       extraArgs: [calendarId, "google"]
 *     });
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
   * - **Default**: Returns a standard webhook URL for all other cases.
   *
   * @param options - Webhook creation options
   * @param options.callback - Function receiving (request, ...extraArgs)
   * @param options.extraArgs - Additional arguments to pass to the callback (type-checked)
   * @param options.provider - Optional provider for provider-specific webhook routing
   * @param options.authorization - Optional authorization for provider-specific webhooks (required for Slack and Gmail)
   * @returns Promise resolving to the webhook URL, or for Gmail, a Pub/Sub topic name
   *
   * @example
   * ```typescript
   * // Gmail webhook - returns Pub/Sub topic name
   * const topicName = await this.tools.network.createWebhook({
   *   callback: this.onGmailNotification,
   *   provider: AuthProvider.Google,
   *   authorization: gmailAuth,
   *   extraArgs: ["inbox"]
   * });
   * // topicName: "projects/plot-prod/topics/gmail-webhook-abc123"
   *
   * // Pass topic name to Gmail API
   * await gmailApi.users.watch({
   *   userId: 'me',
   *   requestBody: {
   *     topicName: topicName,  // Use the returned topic name
   *     labelIds: ['INBOX']
   *   }
   * });
   * ```
   */
  abstract createWebhook<
    TCallback extends (request: WebhookRequest, ...args: any[]) => any
  >(options: {
    callback: TCallback;
    extraArgs?: TCallback extends (req: any, ...rest: infer R) => any ? R : [];
    provider?: AuthProvider;
    authorization?: Authorization;
  }): Promise<string>;

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
