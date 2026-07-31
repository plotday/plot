import type { SlackMessage } from "./slack-api";

/**
 * Whether Slack considers a Plot link read.
 *
 * `"unknown"` is distinct from `"unread"` on purpose: it means Slack did not
 * give us a usable cursor, so the connector must leave Plot's state alone
 * rather than assert anything. Guessing in either direction is worse than
 * abstaining — a wrong `"read"` hides a message the user never saw.
 */
export type SlackReadVerdict = "read" | "unread" | "unknown";

/**
 * Compare two Slack timestamps (`"1700000000.000001"`).
 *
 * Done on the two halves as integers rather than via `parseFloat`: a Slack ts
 * carries 16 significant digits, which is at the edge of float64 precision,
 * so `parseFloat` can round two genuinely different timestamps to the same
 * value. Returns <0, 0, or >0 like a comparator.
 */
export function compareSlackTs(a: string, b: string): number {
  const [aSec = "0", aMicro = "0"] = a.split(".");
  const [bSec = "0", bMicro = "0"] = b.split(".");
  const secDiff = Number(aSec) - Number(bSec);
  if (secDiff !== 0) return secDiff < 0 ? -1 : 1;
  const microDiff =
    Number(aMicro.padEnd(6, "0")) - Number(bMicro.padEnd(6, "0"));
  return microDiff === 0 ? 0 : microDiff < 0 ? -1 : 1;
}

/**
 * Project a CHANNEL-level cursor (`conversations.info.last_read`) onto a link.
 *
 * Correct only for links whose every message sits in the channel timeline —
 * a direct conversation, or a channel message with no thread replies. Reading
 * a channel does not advance a thread's own cursor, so a threaded link must
 * use {@link threadReadVerdict} instead.
 */
export function channelReadVerdict(
  lastRead: string | null | undefined,
  newestTs: string
): SlackReadVerdict {
  if (!lastRead) return "unknown";
  return compareSlackTs(lastRead, newestTs) >= 0 ? "read" : "unread";
}

/**
 * Project a THREAD's own cursor onto a link, from the thread parent returned
 * by `conversations.replies`.
 *
 * `unread_count` is the direct answer and is preferred. The
 * `last_read`/`latest_reply` pair is the fallback for responses that carry
 * the cursor but not the count. A parent with neither means the caller is not
 * subscribed to the thread (or Slack simply omitted the state), so abstain.
 */
export function threadReadVerdict(
  parent: SlackMessage | undefined
): SlackReadVerdict {
  if (!parent) return "unknown";
  if (typeof parent.unread_count === "number") {
    return parent.unread_count === 0 ? "read" : "unread";
  }
  if (parent.last_read && parent.latest_reply) {
    return compareSlackTs(parent.last_read, parent.latest_reply) >= 0
      ? "read"
      : "unread";
  }
  return "unknown";
}

/**
 * The reconciliation state one saved link needs.
 *
 * `newest` is what a cursor is compared against. `threaded` picks which cursor
 * governs: a channel link holding real thread replies is settled by the thread
 * cursor on the live path, everything else by the channel cursor in the daily
 * sweep. `at` is the write time, for the retention drop.
 */
export type SlackReadAnchor = {
  newest: string;
  threaded: boolean;
  at: number;
};

/**
 * Derive the anchor for a set of messages about to be saved as one link.
 *
 * A direct conversation is never `threaded`: its link flattens Slack's reply
 * threads into one running conversation, so the conversation cursor is the
 * only cursor that describes it.
 */
export function deriveReadAnchor(
  messages: SlackMessage[],
  opts: { direct: boolean; at: number }
): SlackReadAnchor | null {
  let newest: string | null = null;
  let threaded = false;
  for (const message of messages) {
    if (!newest || compareSlackTs(message.ts, newest) > 0) newest = message.ts;
    if (!opts.direct && message.thread_ts && message.thread_ts !== message.ts) {
      threaded = true;
    }
  }
  if (!newest) return null;
  return { newest, threaded, at: opts.at };
}
