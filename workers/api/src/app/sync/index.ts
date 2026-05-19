import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import threads from "./threads";
import links from "./links";
import capture from "./capture";
import schedules from "./schedules";
import threadRead from "./thread-read";
import threadTags from "./thread-tags";
import actors from "./actors";
import noteTags from "./note-tags";
import notes from "./notes";
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
import threadUnread from "./thread-unread";
import groups from "./groups";
import topics from "./topics";
import priorityMoves from "./priority-moves";
import priorityArchiveLeave from "./priority-archive-leave";
import teamUsers from "./team-users";

const sync = new Hono<{ Bindings: Bindings }>();

sync.route("/", actors);
sync.route("/", priorities);
sync.route("/", priorityBlocks);
sync.route("/", prioritySuggestions);
sync.route("/", twistInstances);
sync.route("/", twistConnections);
sync.route("/", channels);
sync.route("/", threads);
sync.route("/", links);
sync.route("/", capture);
sync.route("/", notes);
sync.route("/", threadTags);
sync.route("/", noteTags);
sync.route("/", schedules);
sync.route("/", sessions);
sync.route("/", userSettings);
sync.route("/", threadRead);
sync.route("/", threadUnread);
sync.route("/", priorityAttention);
sync.route("/", threadAssociations);
sync.route("/", groups);
sync.route("/", topics);
sync.route("/", priorityMoves);
sync.route("/", priorityArchiveLeave);
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
