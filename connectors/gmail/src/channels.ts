import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { LinkTypeConfig } from "@plotday/twister/tools/integrations";

import { GmailApi } from "./gmail-api";

// ---------------------------------------------------------------------------
// Scope constants
// ---------------------------------------------------------------------------

export const GMAIL_MODIFY_SCOPE = "https://www.googleapis.com/auth/gmail.modify";

// ---------------------------------------------------------------------------
// Link types
// ---------------------------------------------------------------------------

export const GMAIL_LINK_TYPES: LinkTypeConfig[] = [
  {
    type: "email",
    label: "Thread",
    noteLabel: "Reply",
    sharingModel: "message" as const,
    composePlaceholder: "Send a Gmail email",
    composeVerb: "Send",
    replyPlaceholder: "Reply",
    replyVerb: "Send",
    supportsFileAttachments: true,
    logo: "https://api.iconify.design/logos/google-gmail.svg",
    logoMono: "https://api.iconify.design/simple-icons/gmail.svg",
    contactRoles: [
      { id: "to", label: "To", default: true },
      { id: "cc", label: "CC" },
      { id: "bcc", label: "BCC", hidden: true },
    ],
    supportsContactChanges: true,
    // Gmail composes target any address — a Plot contact (with or without
    // a Gmail-connection row) or a free-form typed email delivered via
    // `inviteEmails`. The runtime fills `recipients` from the
    // connection-scoped row when available and falls back to
    // `contact.email` otherwise.
    compose: {
      targets: "addresses" as const,
    },
  },
];

// ---------------------------------------------------------------------------
// Channel listing
// ---------------------------------------------------------------------------

/**
 * Returns available Gmail labels as channel resources for a given token.
 *
 * Filters out system labels except for INBOX, SENT, DRAFT, IMPORTANT, and
 * STARRED. Defaults to enabling INBOX and SENT only.
 */
export async function getGmailChannels(token: AuthToken): Promise<Channel[]> {
  const api = new GmailApi(token.token);
  const labels = await api.getLabels();
  return labels
    .filter(
      (l: any) =>
        l.type !== "system" ||
        ["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(l.id)
    )
    // Default to syncing the user's actual conversations: Inbox (incoming)
    // and Sent (outgoing). Important/Starred are overlapping views of mail
    // that's mostly already in the Inbox, so enabling them by default would
    // largely re-sync the same threads; Draft and user-created labels would
    // crowd the view. They're all still available to enable manually, and
    // Spam/Trash aren't even listed (filtered above).
    .map((l: any) => ({
      id: l.id,
      title: l.name,
      enabledByDefault: l.id === "INBOX" || l.id === "SENT",
    }));
}
