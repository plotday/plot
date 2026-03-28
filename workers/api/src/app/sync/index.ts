import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import threads from "./threads";
import links from "./links";
import schedules from "./schedules";
import threadRead from "./thread-read";
import threadTags from "./thread-tags";
import actors from "./actors";
import noteTags from "./note-tags";
import notes from "./notes";
import priorities from "./priorities";
import priorityActors from "./priority-actors";
import priorityMembers from "./priority-members";
import priorityTwists from "./priority-twists";
import priorityUsers from "./priority-users";
import sessions from "./sessions";
import sourceChannels from "./source-channels";
import userSettings from "./user-settings";
import priorityAttention from "./priority-attention";
import threadAssociations from "./thread-associations";
import threadUnread from "./thread-unread";

const sync = new Hono<{ Bindings: Bindings }>();

sync.route("/", actors);
sync.route("/", priorities);
sync.route("/", priorityUsers);
sync.route("/", priorityMembers);
sync.route("/", priorityActors);
sync.route("/", priorityTwists);
sync.route("/", sourceChannels);
sync.route("/", threads);
sync.route("/", links);
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
