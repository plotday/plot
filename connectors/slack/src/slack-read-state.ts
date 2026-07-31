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
 * value. Returns <0, 0, or >0 like a comparator — or `NaN` when either
 * timestamp is malformed enough that neither half parses as a number, so a
 * meaningful comparison isn't possible.
 *
 * Callers MUST check `Number.isNaN` on the result and treat it as "unknown",
 * never fall through to a directional default: every JS comparison against
 * `NaN` (`< 0`, `>= 0`, `=== 0`) evaluates to `false`, so an unguarded
 * `compareSlackTs(...) >= 0 ? "read" : "unread"` silently resolves to
 * "unread" — and the equally unguarded `< 0 ? -1 : 1` shape used to resolve
 * to `1`, i.e. "read", the UNSAFE direction for a cursor comparison.
 */
export function compareSlackTs(a: string, b: string): number {
  const [aSec = "0", aMicro = "0"] = a.split(".");
  const [bSec = "0", bMicro = "0"] = b.split(".");
  const secDiff = Number(aSec) - Number(bSec);
  if (Number.isNaN(secDiff)) return NaN;
  if (secDiff !== 0) return secDiff < 0 ? -1 : 1;
  const microDiff =
    Number(aMicro.padEnd(6, "0")) - Number(bMicro.padEnd(6, "0"));
  if (Number.isNaN(microDiff)) return NaN;
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
  const cmp = compareSlackTs(lastRead, newestTs);
  if (Number.isNaN(cmp)) return "unknown";
  return cmp >= 0 ? "read" : "unread";
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
    const cmp = compareSlackTs(parent.last_read, parent.latest_reply);
    if (Number.isNaN(cmp)) return "unknown";
    return cmp >= 0 ? "read" : "unread";
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
 *
 * `title` rides along so `reconcileReadState`'s upsert can re-send it —
 * `upsert_thread` takes an "archived" code path whenever the user's
 * `thread_priority` row points at an archived priority (or is missing), and
 * on that path the platform's title default is the literal string
 * "Untitled", never null, so an upsert that omitted `title` there would
 * destroy the thread's real one. `undefined`/`null` when the link that wrote
 * this anchor had no title to carry (see `applyReadAnchor` in slack.ts,
 * which falls back to a previously-stored anchor's title rather than losing
 * it in that case).
 */
export type SlackReadAnchor = {
  newest: string;
  threaded: boolean;
  at: number;
  title?: string | null;
};

/**
 * Derive the anchor for a set of messages about to be saved as one link.
 *
 * A direct conversation is never `threaded`: its link flattens Slack's reply
 * threads into one running conversation, so the conversation cursor is the
 * only cursor that describes it.
 *
 * `title` is accepted rather than inferred from `messages`: only the caller
 * has the link (and, for the carry-forward case, the previously-stored
 * anchor) to source it from.
 */
export function deriveReadAnchor(
  messages: SlackMessage[],
  opts: { direct: boolean; at: number; title?: string | null }
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
  return { newest, threaded, at: opts.at, title: opts.title };
}
