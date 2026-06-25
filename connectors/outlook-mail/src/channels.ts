import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { EXCLUDED_WELL_KNOWN, GraphMailApi } from "./graph-mail-api";

// ---------------------------------------------------------------------------
// Scope constants
// ---------------------------------------------------------------------------

export const OUTLOOK_MAIL_SCOPES: string[] = [
  "https://graph.microsoft.com/mail.readwrite",
  "https://graph.microsoft.com/mail.send",
];

// ---------------------------------------------------------------------------
// Link types
// ---------------------------------------------------------------------------

export const OUTLOOK_MAIL_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "email",
    label: "Thread",
    // Per-product brand for the aggregate Outlook connector (display name
    // "Outlook"); standalone Outlook Mail falls back to its own display name.
    sourceName: "Outlook Mail",
    noteLabel: "Reply",
    sharingModel: "message" as const,
    composePlaceholder: "Send an Outlook email",
    composeVerb: "Send",
    replyPlaceholder: "Reply",
    replyVerb: "Send",
    supportsFileAttachments: true,
    logo: "https://api.iconify.design/logos/microsoft-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
    logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg",
    contactRoles: [
      { id: "to", label: "To", default: true },
      { id: "cc", label: "CC" },
      { id: "bcc", label: "BCC", hidden: true },
    ],
    supportsContactChanges: true,
    // Outlook composes target any address — a Plot contact (with or
    // without a connection-scoped row) or a free-form typed email
    // delivered via `inviteEmails`.
    compose: {
      targets: "addresses" as const,
    },
  },
];

// ---------------------------------------------------------------------------
// Channel listing
// ---------------------------------------------------------------------------

/**
 * Returns available Outlook mail folders as channel resources for a given token.
 *
 * Excludes well-known system folders (Drafts, Junk, Deleted Items, etc.) and
 * hidden folders. Defaults to enabling Inbox and Sent Items only.
 */
export async function getOutlookMailChannels(
  token: AuthToken
): Promise<Channel[]> {
  const api = new GraphMailApi(token.token);
  const folders = await api.getMailFolders();
  const wellKnown = await api.getWellKnownFolderIds();

  const excluded = new Set(
    EXCLUDED_WELL_KNOWN.map((n) => wellKnown[n]).filter(Boolean) as string[]
  );
  return folders
    .filter((f) => !excluded.has(f.id) && !f.isHidden)
    .map((f) => ({
      id: f.id,
      title: f.displayName,
      // Default to the user's actual conversations: incoming + outgoing.
      enabledByDefault:
        f.id === wellKnown.inbox || f.id === wellKnown.sentitems,
    }));
}
