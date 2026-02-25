import { Twist } from "./twist";

/**
 * Base class for sources - twists that sync data from external services.
 *
 * Sources are a specialization of Twist that save threads directly via
 * `integrations.saveThread()` instead of using the Plot tool. They cannot
 * access the Plot tool directly.
 *
 * Sources replace the old Tool + Twist pass-through pattern where Tools
 * built data and passed it via callbacks to Twists which simply called
 * `plot.createThread()`.
 *
 * @example
 * ```typescript
 * class GoogleCalendarSource extends Source<GoogleCalendarSource> {
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations, {
 *         providers: [{
 *           provider: AuthProvider.Google,
 *           scopes: GoogleCalendarSource.SCOPES,
 *           getChannels: this.getChannels,
 *           onChannelEnabled: this.onChannelEnabled,
 *           onChannelDisabled: this.onChannelDisabled,
 *         }]
 *       }),
 *     };
 *   }
 *
 *   async onChannelEnabled(channel: Channel) {
 *     // Fetch and save events directly
 *     const events = await this.fetchEvents(channel.id);
 *     for (const event of events) {
 *       await this.tools.integrations.saveThread(event);
 *     }
 *   }
 * }
 * ```
 */
export abstract class Source<TSelf> extends Twist<TSelf> {
  /**
   * Static marker to identify Source subclasses without instanceof checks
   * across worker boundaries.
   */
  static readonly isSource = true;
}
