import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import threads from "./threads";
import links from "./links";
import capture from "./capture";
import schedules from "./schedules";
import threadRead from "./thread-read";
import threadTags from "./thread-tags";
import threadReactions from "./thread-reactions";
import actors from "./actors";
import noteTags from "./note-tags";
import noteReactions from "./note-reactions";
import customEmoji from "./custom-emoji";
import notes from "./notes";
import noteRetrySend from "./note-retry-send";
import threadDetail from "./thread-detail";
import priorities from "./priorities";
import priorityBlocks from "./priority-blocks";
import prioritySuggestions from "./priority-suggestions";
import twistInstances from "./twist-instances";
import twistConnections from "./twist-connections";
import sessions from "./sessions";
import channels from "./channels";
import userSettings from "./user-settings";
import priorityAttention from "./priority-attention";
import threadAssociations from "./thread-associations";
import threadState from "./thread-state";
import threadUnread from "./thread-unread";
import groups from "./groups";
import topics from "./topics";
import priorityMoves from "./priority-moves";
import priorityMatch from "./priority-match";
import teamUsers from "./team-users";
import roles from "./roles";

const sync = new Hono<{ Bindings: Bindings }>();

sync.route("/", actors);
sync.route("/", priorities);
sync.route("/", roles);
sync.route("/", priorityBlocks);
sync.route("/", prioritySuggestions);
sync.route("/", twistInstances);
sync.route("/", twistConnections);
sync.route("/", channels);
sync.route("/", threads);
sync.route("/", links);
sync.route("/", capture);
sync.route("/", notes);
sync.route("/", noteRetrySend);
sync.route("/", threadDetail);
sync.route("/", threadTags);
sync.route("/", threadReactions);
sync.route("/", noteTags);
sync.route("/", noteReactions);
sync.route("/", customEmoji);
sync.route("/", schedules);
sync.route("/", sessions);
sync.route("/", userSettings);
sync.route("/", threadRead);
sync.route("/", threadState);
// Backwards-compat shim for clients predating the thread_unread → thread_state
// rename. Must stay registered while old clients exist. See ./thread-unread.ts.
sync.route("/", threadUnread);
sync.route("/", priorityAttention);
sync.route("/", threadAssociations);
sync.route("/", groups);
sync.route("/", topics);
sync.route("/", priorityMoves);
sync.route("/", priorityMatch);
sync.route("/", teamUsers);

sync.onError((err, c) => {
  // Handle authorization errors from assertPriorityAccess/assertThreadAccess
  if ("status" in err && typeof (err as any).status === "number") {
    return c.json({ error: err.message }, (err as any).status as any);
  }
  const mapped = mapPgError(err);
  if (mapped) {
    return c.json({ error: mapped.message, pg_code: mapped.pgCode }, mapped.status as any);
  }
  throw err;
});

export default sync;
