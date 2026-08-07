import type { NewLinkWithNotes } from "@plotday/twister/plot";

import { namespace, parse } from "./product-channel";

type ArchiveFilter = {
  channelId?: string;
  type?: string;
  status?: string;
  meta?: Record<string, unknown>;
};

/**
 * The slice of the integrations tool the product hosts consume (see the
 * `tools.integrations` blocks of `CalendarSyncHost` and `TasksSyncHost`).
 */
export type ChannelLinkIntegrations = {
  get(channelId: string): Promise<{ token: string; scopes: string[] } | null>;
  saveLink(link: NewLinkWithNotes): Promise<string | null>;
  saveLinks(links: NewLinkWithNotes[]): Promise<void>;
  channelSyncCompleted(channelId: string): Promise<void>;
  archiveLinks(filter: ArchiveFilter): Promise<void>;
};

/**
 * Wraps the integrations tool handed to a product host so persisted links
 * carry product-namespaced channel ids ("calendar:<id>", "tasks:<id>") —
 * matching how this connector registers its channels — while the product
 * keeps using raw provider ids internally. Only calendar and tasks are ever
 * wrapped: namespacing mail would key thread topics on Gmail labels, and a
 * single user filing would then route all their Gmail by label.
 *
 * `archiveLinks` issues BOTH the namespaced and the raw filter because links
 * saved before this change carry raw channel ids until the server-side
 * backfill lands (transition safety; the double call is idempotent).
 *
 * Token reads (`get`) and sync-completed signals pass through untouched —
 * the platform resolves both leniently for raw ids, and changing them would
 * alter behavior beyond link persistence.
 */
export function withNamespacedChannelIds(
  integrations: ChannelLinkIntegrations,
  product: "calendar" | "tasks"
): ChannelLinkIntegrations {
  const ns = (id: string | null): string | null =>
    id === null || parse(id).product === product ? id : namespace(product, id);

  return {
    get: (channelId) => integrations.get(channelId),
    saveLink: (link) =>
      integrations.saveLink({ ...link, channelId: ns(link.channelId) }),
    saveLinks: (links) =>
      integrations.saveLinks(
        links.map((l) => ({ ...l, channelId: ns(l.channelId) }))
      ),
    channelSyncCompleted: (channelId) =>
      integrations.channelSyncCompleted(channelId),
    archiveLinks: async (filter) => {
      if (!filter.channelId) return integrations.archiveLinks(filter);
      await integrations.archiveLinks({
        ...filter,
        channelId: namespace(product, filter.channelId),
      });
      await integrations.archiveLinks(filter);
    },
  };
}
