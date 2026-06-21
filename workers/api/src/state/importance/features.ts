import type { SenderEngagement } from "./engagement";

/**
 * Local-part patterns for machine senders (no-reply, notifications, bounces).
 * Used as one soft signal in the importance prompt — never a hard gate.
 */
const AUTOMATED_LOCALPART =
  /(^|[._+-])(no-?reply|do-?not-?reply|notifications?|mailer-?daemon|mailer|bounce|postmaster)([._+-]|$)/i;

export function isAutomatedSenderEmail(email: string | null): boolean {
  if (!email) return false;
  const at = email.indexOf("@");
  const localPart = at >= 0 ? email.slice(0, at) : email;
  return AUTOMATED_LOCALPART.test(localPart);
}

export type ThreadFacetsLike = {
  format: string | null;
  automation: "human" | "automated" | null;
  reach: "direct" | "list" | null;
} | null;

export type MemberFeature = {
  memberNum: number;
  engagement: SenderEngagement;
};

function pct(rate: number | null): string | null {
  return rate === null ? null : `${Math.round(rate * 100)}%`;
}

/**
 * The deterministic feature block injected into the importance prompt. All
 * signals are advisory context the model weighs against the note content; the
 * model still picks the band (soft bias, no hard cap).
 */
export function formatImportanceFeatureBlock(args: {
  facets: ThreadFacetsLike;
  senderEmailAutomated: boolean;
  senderIsLinkedUser: boolean;
  members: MemberFeature[];
}): string {
  const lines: string[] = ["Signals (advisory — weigh against the content):"];

  if (args.facets) {
    const parts: string[] = [];
    if (args.facets.format) parts.push(`format=${args.facets.format}`);
    if (args.facets.automation) parts.push(`automation=${args.facets.automation}`);
    if (args.facets.reach) parts.push(`reach=${args.facets.reach}`);
    lines.push(`- Message facets: ${parts.length ? parts.join(", ") : "none"}`);
  } else {
    lines.push("- Message facets: none");
  }

  lines.push(
    `- Sender: ${args.senderEmailAutomated ? "automated/no-reply address" : "ordinary address"}; ${
      args.senderIsLinkedUser ? "a known person in the recipient's network" : "not a known person"
    }`,
  );

  for (const m of args.members) {
    const e = m.engagement;
    if (e.priorThreads === 0) {
      lines.push(`- Recipient #${m.memberNum}: new sender, no prior history`);
      continue;
    }
    const read = pct(e.readRate);
    if (read === null) {
      lines.push(
        `- Recipient #${m.memberNum}: only ${e.priorThreads} prior thread(s) from this sender (too few to judge engagement)`,
      );
      continue;
    }
    lines.push(
      `- Recipient #${m.memberNum}: reads ${read} of this sender's mail, replies ${pct(
        e.replyRate,
      )}, archives ${pct(e.archivedUnreadRate)} unread (${e.priorThreads} prior threads)`,
    );
  }

  return lines.join("\n");
}
