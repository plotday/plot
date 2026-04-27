import { type NewLinkWithNotes } from "@plotday/twister";
import { Connector } from "@plotday/twister/connector";
import { Options } from "@plotday/twister/options";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Callbacks } from "@plotday/twister/tools/callbacks";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Store } from "@plotday/twister/tools/store";
import { PostHogAPI } from "./posthog-api";

type SyncState = {
  after: string | null;
  batchNumber: number;
  eventsProcessed: number;
  initialSync: boolean;
};

/**
 * PostHog connector — syncs PostHog events as person threads.
 *
 * This is a no-provider connector that uses API keys via secure options
 * instead of OAuth. Events are grouped by person (distinct_id) and each
 * event becomes a note on the person's thread.
 */
export class PostHog extends Connector<PostHog> {
  // No provider or scopes — uses API key auth via options

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      options: build(Options, {
        apiKey: {
          type: "text" as const,
          secure: true,
          label: "API key",
          default: "",
          placeholder: "phx_...",
        },
        projectId: {
          type: "text" as const,
          label: "Project ID",
          default: "",
          placeholder: "12345",
        },
        host: {
          type: "text" as const,
          label: "Host",
          default: "https://us.posthog.com",
        },
      }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      store: build(Store),
      network: build(Network, { urls: ["https://*.posthog.com/*"] }),
    };
  }

  private getAPI(): PostHogAPI {
    const opts = this.tools.options;
    return new PostHogAPI(
      opts.apiKey as string,
      opts.projectId as string,
      (opts.host as string) || "https://us.posthog.com"
    );
  }

  override async getAccountName(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<string | null> {
    try {
      const api = this.getAPI();
      const project = await api.getProject();
      return project?.name ?? null;
    } catch {
      return null;
    }
  }

  /**
   * Returns available event definitions as channels.
   * Auth params are null since this connector uses API key options, not OAuth.
   */
  async getChannels(
    _auth: Authorization | null,
    _token: AuthToken | null
  ): Promise<Channel[]> {
    const api = this.getAPI();
    const events = await api.getEventDefinitions();
    return events.map((e) => ({
      id: e.name,
      title: e.name,
    }));
  }

  /**
   * Start syncing events for an enabled channel (event type).
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);
    await this.startBatchSync(channel.id);
  }

  /**
   * Clean up state when a channel is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);

    // Archive links for this channel
    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
      meta: { syncProvider: "posthog", channelId: channel.id },
    });
  }

  private async startBatchSync(eventName: string): Promise<void> {
    await this.set(`sync_state_${eventName}`, {
      after: null,
      batchNumber: 1,
      eventsProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, eventName, true);
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Fetches a batch of events and saves them as person-grouped threads.
   */
  async syncBatch(
    eventName: string,
    initialSync?: boolean
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${eventName}`);
    if (!state) return;

    const isInitial = initialSync ?? state.initialSync;
    const api = this.getAPI();
    const result = await api.getEvents(eventName, state.after ?? undefined);

    // Group events by person (distinct_id)
    const byPerson = new Map<
      string,
      typeof result.results
    >();
    for (const event of result.results) {
      const key = event.distinct_id;
      if (!byPerson.has(key)) {
        byPerson.set(key, []);
      }
      byPerson.get(key)!.push(event);
    }

    // Save a thread per person
    for (const [distinctId, events] of byPerson) {
      const firstEvent = events[0]!;
      const personProps = firstEvent.person?.properties ?? {};
      const personName =
        (personProps.name as string) ||
        (personProps.email as string) ||
        distinctId;

      const propertiesNotes = events.map((event) => {
        const propsMarkdown = formatProperties(event.properties);
        return {
          key: `event:${event.uuid}`,
          content: `**${event.event}** at ${event.timestamp}\n\n${propsMarkdown}`,
          contentType: "markdown" as const,
          created: new Date(event.timestamp),
        };
      });

      const projectId = this.tools.options.projectId as string;

      const link: NewLinkWithNotes = {
        // PostHog distinct_id is project-scoped (often just an email), so we
        // qualify with projectId to keep source globally unique across users.
        source: `posthog:${projectId}:person:${distinctId}`,
        title: personName,
        type: "person",
        channelId: eventName,
        meta: {
          syncProvider: "posthog",
          channelId: eventName,
          distinctId,
        },
        notes: propertiesNotes,
        ...(isInitial ? { unread: false } : {}),
        ...(isInitial ? { archived: false } : {}),
      };

      await this.tools.integrations.saveLink(link);
    }

    // Continue to next batch or finish
    if (result.next) {
      await this.set(`sync_state_${eventName}`, {
        after: result.next,
        batchNumber: state.batchNumber + 1,
        eventsProcessed: state.eventsProcessed + result.results.length,
        initialSync: isInitial,
      } satisfies SyncState);

      const nextBatch = await this.callback(
        this.syncBatch,
        eventName,
        isInitial
      );
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Sync complete
      await this.clear(`sync_state_${eventName}`);
    }
  }
}

/**
 * Format event properties as a Markdown key-value list.
 */
function formatProperties(props: Record<string, unknown>): string {
  const entries = Object.entries(props).filter(
    ([, v]) => v !== null && v !== undefined && v !== ""
  );
  if (entries.length === 0) return "";
  return entries
    .map(([k, v]) => `- **${k}**: ${String(v)}`)
    .join("\n");
}

export default PostHog;
