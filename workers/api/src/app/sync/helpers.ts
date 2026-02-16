import type { Context } from "hono";

import type { Bindings } from "../../env";

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 1000;

const ALLOWED_SORT_COLUMNS = new Set(["created_at", "updated_at"]);

export interface ReadParams {
  updatedSince: string | null;
  cursorId: string | null;
  archived: boolean | undefined;
  limit: number;
  priorityPath: string | null;
  activityId: string | null;
  rangeStart: string | null;
  rangeEnd: string | null;
  initial: boolean;
  id: string | null;
  sortBy: string;
  sortDir: "asc" | "desc";
}

export function parseReadParams(c: Context<{ Bindings: Bindings }>): ReadParams {
  const limitRaw = c.req.query("limit");
  const limit = limitRaw
    ? Math.min(Math.max(1, parseInt(limitRaw, 10) || DEFAULT_LIMIT), MAX_LIMIT)
    : DEFAULT_LIMIT;

  const archivedRaw = c.req.query("archived");
  const archived =
    archivedRaw === "true" ? true : archivedRaw === "false" ? false : undefined;

  const sortByRaw = c.req.query("sort_by");
  const sortBy = sortByRaw && ALLOWED_SORT_COLUMNS.has(sortByRaw) ? sortByRaw : "updated_at";
  const sortDirRaw = c.req.query("sort_dir");
  const sortDir = sortDirRaw === "desc" ? "desc" : "asc";

  return {
    updatedSince: c.req.query("updated_since") || null,
    cursorId: c.req.query("cursor_id") || null,
    archived,
    limit,
    priorityPath: c.req.query("priority_path") || null,
    activityId: c.req.query("activity_id") || null,
    rangeStart: c.req.query("range_start") || null,
    rangeEnd: c.req.query("range_end") || null,
    initial: c.req.query("initial") === "true",
    id: c.req.query("id") || null,
    sortBy,
    sortDir,
  };
}
