import { Hono } from "hono";
import { sql } from "kysely";
import { z } from "zod";

import { withUserDb } from "../../db";
import type { Bindings } from "../../env";

const priorityArchiveLeave = new Hono<{ Bindings: Bindings }>();

const ArchiveOrLeaveRequestSchema = z.object({
  priority_id: z.uuid(),
});

// POST /sync/priority/archive-or-leave
//
// Archives a priority. If the priority belongs to a team and this is the
// caller's last top-level priority for that team, the caller's team_user row
// is archived instead (leaving the team). Task 6's trigger then cascades the
// archive to all of the user's priorities for that team.
//
// Responses:
//   200 { status: "archived" }             — priority archived, no team action
//   200 { status: "left_team", team_id }   — team membership archived (trigger archives priority)
//   409 { error: "last_admin" }            — refusing: user is the last admin of the team
//   404                                    — priority not found or not owned by caller
priorityArchiveLeave.post("/sync/priority/archive-or-leave", async (c) => {
  const body = ArchiveOrLeaveRequestSchema.parse(await c.req.json());
  const userId = c.var.user.id;

  return await withUserDb(c.var.db, userId, async (trx) => {
    // 1. Look up the priority — must be owned by the caller and not already archived.
    const priority = await trx
      .selectFrom("priority")
      .select(["id", "team_id", "path"])
      .where("id", "=", body.priority_id)
      .where("user_id", "=", userId)
      .where("archived_at", "is", null)
      .executeTakeFirst();

    if (!priority) {
      return c.json({ error: "not_found" }, 404);
    }

    // 2. Personal priority (no team) → archive directly.
    if (priority.team_id == null) {
      await trx
        .updateTable("priority")
        .set({ archived_at: new Date() })
        .where("id", "=", body.priority_id)
        .execute();
      return c.json({ status: "archived" }, 200);
    }

    const teamId = priority.team_id;

    // 3a. Count the caller's other non-archived top-level (nlevel=2) priorities
    //     for this team (excluding the one being archived).
    const othersResult = await trx
      .selectFrom("priority")
      .select(({ fn }) => fn.countAll<number>().as("c"))
      .where("user_id", "=", userId)
      .where("team_id", "=", teamId)
      .where("archived_at", "is", null)
      .where("id", "!=", body.priority_id)
      .where(sql<boolean>`nlevel(path) = 2`)
      .executeTakeFirstOrThrow();

    if (Number(othersResult.c) > 0) {
      // 3b. Not the last top-level team priority → archive only this one.
      await trx
        .updateTable("priority")
        .set({ archived_at: new Date() })
        .where("id", "=", body.priority_id)
        .execute();
      return c.json({ status: "archived" }, 200);
    }

    // 3c. This is the caller's last top-level priority for the team — leaving the team.
    const tu = await trx
      .selectFrom("team_user")
      .select(["id", "role"])
      .where("user_id", "=", userId)
      .where("team_id", "=", teamId)
      .where("archived_at", "is", null)
      .executeTakeFirst();

    if (!tu) {
      // No active membership (shouldn't normally happen) — archive the priority and bail.
      await trx
        .updateTable("priority")
        .set({ archived_at: new Date() })
        .where("id", "=", body.priority_id)
        .execute();
      return c.json({ status: "archived" }, 200);
    }

    // 3c.ii. Last-admin guard: if this user is an admin, ensure at least one
    //        other active admin exists before allowing the leave.
    if (tu.role === "admin") {
      const otherAdminsResult = await trx
        .selectFrom("team_user")
        .select(({ fn }) => fn.countAll<number>().as("c"))
        .where("team_id", "=", teamId)
        .where("role", "=", "admin")
        .where("archived_at", "is", null)
        .where("id", "!=", tu.id)
        .executeTakeFirstOrThrow();

      if (Number(otherAdminsResult.c) === 0) {
        return c.json({ error: "last_admin" }, 409);
      }
    }

    // 3c.iii. Archive the team_user row. Task 6's AFTER UPDATE trigger will
    //         cascade the archive to all of this user's priorities for the team.
    await trx
      .updateTable("team_user")
      .set({ archived_at: new Date() })
      .where("id", "=", tu.id)
      .execute();

    return c.json({ status: "left_team", team_id: String(teamId) }, 200);
  });
});

export default priorityArchiveLeave;
