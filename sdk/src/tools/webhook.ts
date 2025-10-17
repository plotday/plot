import { ITool, type Tools } from "..";

/**
 * Built-in tool for creating and managing webhook endpoints.
 *
 * The Webhook tool enables agents and tools to create HTTP endpoints that
 * external services can call to trigger callbacks. This is essential for
 * real-time integrations with services like Google Calendar, GitHub, Slack, etc.
 *
 * **Webhook Characteristics:**
 * - Persistent across worker restarts
 * - Automatic callback routing to parent tool/agent
 * - Support for all HTTP methods
 * - Context preservation for callback execution
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool {
 *   private webhook: Webhook;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.webhook = tools.get(Webhook);
 *   }
 *
 *   async setupCalendarWebhook(calendarId: string) {
 *     // Create webhook URL that will call onCalendarEvent
 *     const webhookUrl = await this.webhook.create("onCalendarEvent", {
 *       calendarId,
 *       provider: "google"
 *     });
 *
 *     // Register webhook with Google Calendar API
 *     await this.registerWithGoogleCalendar(calendarId, webhookUrl);
 *
 *     return webhookUrl;
 *   }
 *
 *   async onCalendarEvent(request: WebhookRequest, context: any) {
 *     console.log("Calendar event received:", {
 *       method: request.method,
 *       calendarId: context.calendarId,
 *       body: request.body
 *     });
 *
 *     // Process the calendar event change
 *     await this.processCalendarChange(request.body);
 *   }
 *
 *   async cleanup(webhookUrl: string) {
 *     await this.webhook.delete(webhookUrl);
 *   }
 * }
 * ```
 */
export class Webhook extends ITool {
  constructor(_tools: Tools) {
    super();
  }

  /**
   * Creates a new webhook endpoint.
   *
   * Generates a unique HTTP endpoint that will invoke the specified callback
   * function on the parent tool/agent when requests are received. The context
   * data will be passed to the callback along with the request information.
   *
   * @param callbackName - Name of the function to call on the parent when webhook is triggered
   * @param context - Optional context data to pass to the callback function
   * @returns Promise resolving to the webhook URL
   */
  create(_callbackName: string, _context?: any): Promise<string> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Deletes an existing webhook endpoint.
   *
   * Removes the webhook endpoint and stops processing requests to that URL.
   * Any subsequent requests to the deleted webhook will return 404.
   *
   * @param url - The webhook URL to delete
   * @returns Promise that resolves when the webhook is deleted
   */
  delete(_url: string): Promise<void> {
    throw new Error("Method implemented remotely.");
  }
}

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
