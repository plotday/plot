import { ITool } from "..";

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
 * 1. Declares which URLs an agent or tool is allowed to access via HTTP/HTTPS
 * 2. Provides webhook creation and management for receiving HTTP callbacks
 *
 * **IMPORTANT**: Must be requested in the Agent or Tool Init method to declare
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
 * - Automatic callback routing to parent tool/agent
 * - Support for all HTTP methods
 * - Context preservation for callback execution
 *
 * @example
 * ```typescript
 * class MyAgent extends Agent<MyAgent> {
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
   * For provider-specific webhooks (e.g., Slack), use the provider and authorization
   * parameters to enable automatic routing based on provider-specific identifiers.
   *
   * @param options - Webhook creation options
   * @param options.callback - Function receiving (request, ...extraArgs)
   * @param options.extraArgs - Additional arguments to pass to the callback (type-checked)
   * @param options.provider - Optional provider for provider-specific webhook routing
   * @param options.authorization - Optional authorization for provider-specific webhooks (required for Slack)
   * @returns Promise resolving to the webhook URL
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createWebhook<
    TCallback extends (request: WebhookRequest, ...args: any[]) => any
  >(options: {
    callback: TCallback;
    extraArgs?: TCallback extends (req: any, ...rest: infer R) => any ? R : [];
    provider?: any; // AuthProvider from integrations, but we can't import it here
    authorization?: any; // Authorization from integrations
  }): Promise<string>;

  /**
   * Deletes an existing webhook endpoint.
   *
   * Removes the webhook endpoint and stops processing requests to that URL.
   * Any subsequent requests to the deleted webhook will return 404.
   *
   * @param url - The webhook URL to delete
   * @returns Promise that resolves when the webhook is deleted
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract deleteWebhook(url: string): Promise<void>;
}
