/**
 * Who counts as "you" for mention detection: the connected Slack user and the
 * user groups they belong to.
 */
export type MentionContext = {
  /** The connected account's Slack user id, e.g. "U111". */
  userId: string;
  /** Slack user-group ids the connected user belongs to, e.g. "S222". */
  userGroupIds: ReadonlySet<string>;
};

/** `<!subteam^S222>` or `<!subteam^S222|@eng>`. */
const USER_GROUP = /<!subteam\^([A-Z0-9]+)(?:\|[^>]*)?>/g;

/** `<!here>`, `<!channel>`, `<!everyone>`, each optionally labelled. */
const BROADCAST = /<!(?:here|channel|everyone)(?:\|[^>]*)?>/;

/** Escape a Slack id for literal use inside a RegExp. */
function escape(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Whether `rawText` mentions the user described by `ctx`.
 *
 * MUST be given the RAW Slack message text. `formatSlackText` rewrites
 * `<@U111>` to `@U111`, which no longer matches — and a bare `@U111` typed by
 * a human is not a mention at all.
 */
export function mentionsUser(
  rawText: string | undefined,
  ctx: MentionContext
): boolean {
  if (!rawText) return false;

  // Direct: the closing delimiter is either `>` or the `|label>` separator, so
  // a longer id sharing our prefix (U1112 vs U111) cannot match.
  if (new RegExp(`<@${escape(ctx.userId)}(?:\\||>)`).test(rawText)) return true;

  if (BROADCAST.test(rawText)) return true;

  if (ctx.userGroupIds.size > 0) {
    // No `lastIndex` reset needed: `matchAll` iterates a CLONE of the regex
    // and never advances this one, and nothing else here calls a
    // `lastIndex`-advancing method (`test`/`exec`) on it. Adding such a call
    // later would need the clone's seeded `lastIndex` reset here.
    for (const match of rawText.matchAll(USER_GROUP)) {
      const groupId = match[1];
      if (groupId && ctx.userGroupIds.has(groupId)) return true;
    }
  }

  return false;
}
