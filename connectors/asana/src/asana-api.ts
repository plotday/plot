/**
 * Asana REST API client helpers.
 *
 * A thin raw-`fetch` wrapper over the Asana REST API (https://app.asana.com/api/1.0).
 * Replaces the `asana` npm SDK, which depends on `superagent` (Node `http`) and is
 * not reliably Workers-compatible. Mirrors the Todoist connector's `api.ts` style:
 * a single `request<T>` helper (base URL + Bearer auth, throws on non-2xx, parses
 * JSON) plus a multipart `uploadAttachment` that bypasses the helper.
 *
 * Conventions:
 * - Single-object responses: `{ data: {...} }`. List responses:
 *   `{ data: [...], next_page: { offset, path, uri } | null }`.
 * - Write bodies are wrapped `{ data: {...} }`.
 * - `opt_fields` is a comma-separated query param.
 * - List pagination follows `next_page.offset` (`&offset=<offset>&limit=100`).
 */

const BASE_URL = "https://app.asana.com/api/1.0";

/** Page cursor returned on Asana list responses (null at the end). */
export type AsanaNextPage = {
  offset: string;
  path: string;
  uri: string;
} | null;

/** Generic single-object Asana response envelope. */
export type AsanaData<T> = { data: T };

/** Generic list Asana response envelope. */
export type AsanaList<T> = { data: T[]; next_page?: AsanaNextPage };

/** Asana photo sub-object (only the size we read). */
export type AsanaPhoto = {
  image_128x128?: string;
} | null;

/** Asana user as returned via `email,name` (and gid by default) opt_fields. */
export type AsanaUser = {
  gid: string;
  name?: string;
  email?: string;
  photo?: AsanaPhoto;
};

/** A single Asana "like" entry (via `likes.user.gid/name` opt_fields). */
export type AsanaLike = {
  gid?: string;
  user?: { gid?: string; name?: string };
};

/** Asana section (via `name` opt_fields). */
export type AsanaSection = {
  gid: string;
  name?: string;
};

/** Asana project membership as read for section-as-status mapping. */
export type AsanaMembership = {
  project?: { gid?: string } | null;
  section?: { gid?: string; name?: string } | null;
};

/** Asana task — loose shape covering every field this connector reads. */
export type AsanaTask = {
  gid: string;
  name?: string;
  notes?: string;
  completed?: boolean;
  completed_at?: string | null;
  created_at?: string;
  modified_at?: string;
  assignee?: AsanaUser | null;
  created_by?: AsanaUser | null;
  memberships?: AsanaMembership[] | null;
  liked?: boolean;
  num_likes?: number;
  likes?: AsanaLike[];
};

/** Asana story (comment) — loose shape covering the fields this connector reads. */
export type AsanaStory = {
  gid: string;
  text?: string;
  created_at?: string;
  created_by?: AsanaUser | null;
  liked?: boolean;
  num_likes?: number;
  likes?: AsanaLike[];
};

/** Asana attachment (via `name` / `download_url` opt_fields). */
export type AsanaAttachment = {
  gid: string;
  name?: string;
  download_url?: string;
};

/** Asana workspace. */
export type AsanaWorkspace = {
  gid: string;
  name?: string;
};

/** Asana project (loose — `workspace.gid` read for workspace resolution). */
export type AsanaProject = {
  gid: string;
  name?: string;
  workspace?: { gid?: string } | null;
};

/** Asana event entry as returned by the Events API. */
export type AsanaEvent = {
  resource?: {
    gid?: string;
    resource_type?: string;
  } | null;
  parent?: {
    gid?: string;
    resource_type?: string;
  } | null;
  action?: string;
};

/** Result of {@link getEvents}: the events plus the next sync token. */
export type AsanaEventsResult = {
  data: AsanaEvent[];
  sync?: string;
};

/**
 * Error thrown when the Asana Events API returns 412 ("Sync token invalid").
 * Carries the fresh `sync` token Asana includes in the 412 body so the caller
 * (`pollChanges`) can reset the cursor and fall back to a delta sync.
 *
 * `parseEventsError` extracts the `sync` field from a 412 body — exported and
 * unit-testable as a pure helper.
 */
export class AsanaSyncTokenError extends Error {
  readonly status = 412 as const;
  readonly sync: string | undefined;
  constructor(message: string, sync: string | undefined) {
    super(message);
    this.name = "AsanaSyncTokenError";
    this.sync = sync;
  }
}

/**
 * Extract the fresh `sync` token from a 412 Events API error body. Asana returns
 * `{ sync: "<token>", errors: [...] }` (or sometimes nests it). Returns the token
 * string when present, else undefined.
 *
 * Pure function (unit-tested) — keep free of `this`/IO.
 */
export function parseEventsError(body: unknown): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const sync = (body as { sync?: unknown }).sync;
  return typeof sync === "string" ? sync : undefined;
}

/** Append an `opt_fields` query param to a path if provided. */
function withOptFields(path: string, optFields?: string): string {
  if (!optFields) return path;
  const sep = path.includes("?") ? "&" : "?";
  return `${path}${sep}opt_fields=${encodeURIComponent(optFields)}`;
}

/**
 * Core request helper: base URL + Bearer auth, JSON in/out, throws an `Error`
 * carrying the status + text on any non-2xx response.
 */
async function request<T>(
  token: string,
  path: string,
  options?: RequestInit,
): Promise<T> {
  const response = await fetch(`${BASE_URL}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Asana API error ${response.status}: ${text}`);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

/** GET /tasks/{gid} — single task. */
export async function getTask(
  token: string,
  taskGid: string,
  optFields?: string,
): Promise<AsanaTask> {
  const res = await request<AsanaData<AsanaTask>>(
    token,
    withOptFields(`/tasks/${taskGid}`, optFields),
  );
  return res.data;
}

/**
 * GET /tasks?project={gid} — one page of a project's tasks. Follow
 * `next_page.offset` to paginate; or use {@link getAllTasksForProject}.
 */
export async function getTasksForProject(
  token: string,
  projectGid: string,
  opts: {
    optFields?: string;
    modifiedSince?: string;
    limit?: number;
    offset?: string;
  } = {},
): Promise<AsanaList<AsanaTask>> {
  const params = new URLSearchParams();
  params.set("project", projectGid);
  params.set("limit", String(opts.limit ?? 100));
  if (opts.optFields) params.set("opt_fields", opts.optFields);
  if (opts.modifiedSince) params.set("modified_since", opts.modifiedSince);
  if (opts.offset) params.set("offset", opts.offset);
  return request<AsanaList<AsanaTask>>(token, `/tasks?${params.toString()}`);
}

/** POST /tasks — create a task. `data` is wrapped `{ data }`. */
export async function createTask(
  token: string,
  data: Record<string, unknown>,
  optFields?: string,
): Promise<AsanaTask> {
  const res = await request<AsanaData<AsanaTask>>(
    token,
    withOptFields("/tasks", optFields),
    { method: "POST", body: JSON.stringify({ data }) },
  );
  return res.data;
}

/** PUT /tasks/{gid} — update a task. `data` is wrapped `{ data }`. */
export async function updateTask(
  token: string,
  taskGid: string,
  data: Record<string, unknown>,
  optFields?: string,
): Promise<AsanaTask> {
  const res = await request<AsanaData<AsanaTask>>(
    token,
    withOptFields(`/tasks/${taskGid}`, optFields),
    { method: "PUT", body: JSON.stringify({ data }) },
  );
  return res.data;
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

/** GET /projects/{gid}/sections — sections of a project. */
export async function getSectionsForProject(
  token: string,
  projectGid: string,
): Promise<AsanaSection[]> {
  const res = await request<AsanaList<AsanaSection>>(
    token,
    `/projects/${projectGid}/sections?opt_fields=name`,
  );
  return res.data ?? [];
}

/** POST /sections/{gid}/addTask — move a task into a section. */
export async function addTaskToSection(
  token: string,
  sectionGid: string,
  taskGid: string,
): Promise<void> {
  await request<AsanaData<unknown>>(token, `/sections/${sectionGid}/addTask`, {
    method: "POST",
    body: JSON.stringify({ data: { task: taskGid } }),
  });
}

// ---------------------------------------------------------------------------
// Stories (comments)
// ---------------------------------------------------------------------------

/** POST /tasks/{gid}/stories — create a comment. */
export async function createStory(
  token: string,
  taskGid: string,
  text: string,
  optFields?: string,
): Promise<AsanaStory> {
  const res = await request<AsanaData<AsanaStory>>(
    token,
    withOptFields(`/tasks/${taskGid}/stories`, optFields),
    { method: "POST", body: JSON.stringify({ data: { text } }) },
  );
  return res.data;
}

/** GET /tasks/{gid}/stories — comments/stories on a task. */
export async function getStoriesForTask(
  token: string,
  taskGid: string,
  optFields?: string,
): Promise<AsanaStory[]> {
  const res = await request<AsanaList<AsanaStory>>(
    token,
    withOptFields(`/tasks/${taskGid}/stories`, optFields),
  );
  return res.data ?? [];
}

/** PUT /stories/{gid} — update a story (used for `{ liked }`). */
export async function updateStory(
  token: string,
  storyGid: string,
  data: Record<string, unknown>,
): Promise<AsanaStory> {
  const res = await request<AsanaData<AsanaStory>>(token, `/stories/${storyGid}`, {
    method: "PUT",
    body: JSON.stringify({ data }),
  });
  return res.data;
}

// ---------------------------------------------------------------------------
// Users / Workspaces / Projects
// ---------------------------------------------------------------------------

/** GET /workspaces/{gid}/users — users in a workspace (email,name). */
export async function getUsersForWorkspace(
  token: string,
  workspaceGid: string,
): Promise<AsanaUser[]> {
  const res = await request<AsanaList<AsanaUser>>(
    token,
    `/workspaces/${workspaceGid}/users?opt_fields=email,name`,
  );
  return res.data ?? [];
}

/** GET /workspaces — the authenticated user's workspaces. */
export async function getWorkspaces(token: string): Promise<AsanaWorkspace[]> {
  const res = await request<AsanaList<AsanaWorkspace>>(
    token,
    `/workspaces?limit=100`,
  );
  return res.data ?? [];
}

/** GET /workspaces/{gid}/projects — projects in a workspace. */
export async function getProjectsForWorkspace(
  token: string,
  workspaceGid: string,
  optFields?: string,
): Promise<AsanaProject[]> {
  const path = withOptFields(
    `/workspaces/${workspaceGid}/projects?limit=100`,
    optFields,
  );
  const res = await request<AsanaList<AsanaProject>>(token, path);
  return res.data ?? [];
}

/** GET /projects/{gid} — single project. */
export async function getProject(
  token: string,
  projectGid: string,
  optFields?: string,
): Promise<AsanaProject> {
  const res = await request<AsanaData<AsanaProject>>(
    token,
    withOptFields(`/projects/${projectGid}`, optFields),
  );
  return res.data;
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/** GET /attachments?parent={gid} — attachments on a task. */
export async function getAttachmentsForObject(
  token: string,
  taskGid: string,
): Promise<AsanaAttachment[]> {
  const res = await request<AsanaList<AsanaAttachment>>(
    token,
    `/attachments?parent=${taskGid}&opt_fields=name`,
  );
  return res.data ?? [];
}

/** GET /attachments/{gid} — single attachment (download_url). */
export async function getAttachment(
  token: string,
  attachmentGid: string,
): Promise<AsanaAttachment> {
  const res = await request<AsanaData<AsanaAttachment>>(
    token,
    `/attachments/${attachmentGid}?opt_fields=download_url`,
  );
  return res.data;
}

/**
 * POST /attachments — upload a file to a task.
 *
 * Bypasses {@link request} because the endpoint is multipart (`FormData`), not
 * JSON. Cloudflare Workers' `fetch` supports `FormData` with `Blob` parts
 * natively — do NOT set Content-Type; `fetch` writes the multipart boundary.
 */
export async function uploadAttachment(
  token: string,
  taskGid: string,
  blob: Blob,
  fileName: string,
): Promise<void> {
  const form = new FormData();
  form.append("parent", taskGid);
  form.append("file", blob, fileName);
  const response = await fetch(`${BASE_URL}/attachments`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Asana API error ${response.status}: ${text}`);
  }
}

// ---------------------------------------------------------------------------
// Events (polling)
// ---------------------------------------------------------------------------

/**
 * GET /events?resource={gid}&sync={token} — poll for changes.
 *
 * On 412 (sync token invalid/expired) Asana returns a fresh `sync` token in the
 * body; this throws an {@link AsanaSyncTokenError} carrying `status: 412` and
 * that fresh token so `pollChanges` can reset its cursor. Other non-2xx
 * responses throw a plain `Error`.
 *
 * When called with no `syncToken`, Asana also responds 412 with the initial
 * token — the same path establishes the cursor for subsequent incremental polls.
 */
export async function getEvents(
  token: string,
  resourceGid: string,
  syncToken?: string,
): Promise<AsanaEventsResult> {
  const params = new URLSearchParams();
  params.set("resource", resourceGid);
  if (syncToken) params.set("sync", syncToken);

  const response = await fetch(`${BASE_URL}/events?${params.toString()}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
  });

  const text = await response.text();
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = {};
  }

  if (response.status === 412) {
    throw new AsanaSyncTokenError(
      `Asana API error 412: ${text}`,
      parseEventsError(body),
    );
  }
  if (!response.ok) {
    throw new Error(`Asana API error ${response.status}: ${text}`);
  }

  const result = body as AsanaEventsResult;
  return { data: result.data ?? [], sync: result.sync };
}
