import { type Actor, type Link, type Note, type ThreadMeta } from "./plot";
import {
  type AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  type LinkTypeConfig,
} from "./tools/integrations";
import { Twist } from "./twist";

/**
 * Base class for sources — twists that sync data from external services.
 *
 * Sources declare a single OAuth provider and scopes, and implement channel
 * lifecycle methods for discovering and syncing external resources. They save
 * data directly via `integrations.saveLink()` instead of using the Plot tool.
 *
 * @example
 * ```typescript
 * class LinearSource extends Source<LinearSource> {
 *   readonly provider = AuthProvider.Linear;
 *   readonly scopes = ["read", "write"];
 *   readonly linkTypes = [{
 *     type: "issue",
 *     label: "Issue",
 *     statuses: [
 *       { status: "open", label: "Open" },
 *       { status: "done", label: "Done" },
 *     ],
 *   }];
 *
 *   build(build: ToolBuilder) {
 *     return {
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async getChannels(auth: Authorization, token: AuthToken): Promise<Channel[]> {
 *     const teams = await this.listTeams(token);
 *     return teams.map(t => ({ id: t.id, title: t.name }));
 *   }
 *
 *   async onChannelEnabled(channel: Channel) {
 *     const issues = await this.fetchIssues(channel.id);
 *     for (const issue of issues) {
 *       await this.tools.integrations.saveLink(issue);
 *     }
 *   }
 *
 *   async onChannelDisabled(channel: Channel) {
 *     // Clean up webhooks, sync state, etc.
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

  // ---- Identity (abstract — every source must declare) ----

  /** The OAuth provider this source authenticates with. */
  abstract readonly provider: AuthProvider;

  /** OAuth scopes to request for this source. */
  abstract readonly scopes: string[];

  // ---- Optional metadata ----

  /**
   * Registry of link types this source creates (e.g., issue, event, message).
   * Used for display in the UI (icons, labels, statuses).
   */
  readonly linkTypes?: LinkTypeConfig[];

  // ---- Channel lifecycle (abstract — every source must implement) ----

  /**
   * Returns available channels for the authorized actor.
   * Called after OAuth is complete, during the setup/edit modal.
   *
   * @param auth - The completed authorization with provider and actor info
   * @param token - The access token for making API calls
   * @returns Promise resolving to available channels for the user to select
   */
  abstract getChannels(
    auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]>;

  /**
   * Called when a channel resource is enabled for syncing.
   * Should set up webhooks and start initial sync.
   *
   * @param channel - The channel that was enabled
   */
  abstract onChannelEnabled(channel: Channel): Promise<void>;

  /**
   * Called when a channel resource is disabled.
   * Should stop sync, clean up webhooks, and remove state.
   *
   * @param channel - The channel that was disabled
   */
  abstract onChannelDisabled(channel: Channel): Promise<void>;

  // ---- Write-back hooks (optional, default no-ops) ----

  /**
   * Called when a link created by this source is updated by the user.
   * Override to write back changes to the external service
   * (e.g., changing issue status in Linear when marked done in Plot).
   *
   * @param link - The updated link
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onLinkUpdated(link: Link): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a note is created on a thread owned by this source.
   * Override to write back comments to the external service
   * (e.g., adding a comment to a Linear issue).
   *
   * @param note - The created note
   * @param meta - Metadata from the thread's link
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteCreated(note: Note, meta: ThreadMeta): Promise<void> {
    return Promise.resolve();
  }

  // ---- Activation ----

  /**
   * Called when the source is activated after OAuth is complete.
   *
   * Unlike Twist.activate() which receives a priority, Source.activate()
   * receives the authorization and actor since sources are not installed
   * in priorities.
   *
   * Default implementation does nothing. Override for custom setup.
   *
   * @param context - The activation context
   * @param context.auth - The completed OAuth authorization
   * @param context.actor - The actor who activated the source
   */
  // @ts-ignore - Source.activate() intentionally has a different signature than Twist.activate()
  activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    return Promise.resolve();
  }
}
