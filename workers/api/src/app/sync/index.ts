import { Hono } from "hono";

import { mapPgError } from "../../db";
import type { Bindings } from "../../env";
import activities from "./activities";
import activityExceptions from "./activity-exceptions";
import activityRead from "./activity-read";
import activityTags from "./activity-tags";
import actors from "./actors";
import noteTags from "./note-tags";
import notes from "./notes";
import priorities from "./priorities";
import priorityActors from "./priority-actors";
import priorityMembers from "./priority-members";
import priorityTwists from "./priority-twists";
import priorityUsers from "./priority-users";
import sessions from "./sessions";
import userSettings from "./user-settings";

const sync = new Hono<{ Bindings: Bindings }>();

sync.route("/", actors);
sync.route("/", priorities);
sync.route("/", priorityUsers);
sync.route("/", priorityMembers);
sync.route("/", priorityActors);
sync.route("/", priorityTwists);
sync.route("/", activities);
sync.route("/", notes);
sync.route("/", activityTags);
sync.route("/", noteTags);
sync.route("/", activityExceptions);
sync.route("/", sessions);
sync.route("/", userSettings);
sync.route("/", activityRead);

sync.onError((err, c) => {
  // Handle authorization errors from assertPriorityAccess/assertActivityAccess
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
