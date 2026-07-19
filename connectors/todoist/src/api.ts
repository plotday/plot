/**
 * Todoist API v1 client helpers.
 *
 * Uses Todoist's unified REST API directly.
 * https://developer.todoist.com/api/v1/
 *
 * Todoist retired the old REST v2 (`/rest/v2`) and Sync v9 (`/sync/v9`)
 * surfaces — both now return `410 Gone`. Everything lives under `/api/v1/`
 * now, with a few breaking changes from v2 baked in:
 * - List endpoints return `{ results, next_cursor }` instead of a bare array
 *   — callers here paginate internally so every exported `list*` function
 *   still returns a plain array of all items.
 * - Several task fields were renamed: `is_completed` → `checked`,
 *   `creator_id` → `added_by_uid`, `assignee_id` → `responsible_uid`,
 *   `created_at` → `added_at`.
 * - Comments: `task_id` → `item_id`, `attachment` → `file_attachment`.
 * - Sections: `order` → `section_order`.
 * - Responses no longer include a `url` field — it's computed client-side
 *   from the resource id (see {@link taskUrl}).
 * - Moving a task between sections/projects is a dedicated
 *   `POST /tasks/{id}/move` endpoint; the general task-update endpoint no
 *   longer accepts `section_id`/`project_id`.
 */

const BASE_URL = "https://api.todoist.com/api/v1";
const WEB_BASE_URL = "https://app.todoist.com/app";

/** Build the web app URL for a task. Todoist accepts a bare id (no slug). */
function taskUrl(id: string): string {
  return `${WEB_BASE_URL}/task/${id}`;
}

export type TodoistProject = {
  id: string;
  name: string;
  color: string;
  is_shared: boolean;
  is_favorite: boolean;
};

export type TodoistTask = {
  id: string;
  content: string;
  description: string;
  checked: boolean;
  project_id: string;
  /** Section the task belongs to, or null if it is not in a section. */
  section_id: string | null;
  parent_id: string | null;
  priority: number; // 1 (normal) to 4 (urgent)
  due: {
    date: string;
    string: string;
    datetime: string | null;
    timezone: string | null;
    is_recurring: boolean;
  } | null;
  url: string;
  /** Collaborator id of whoever is responsible for (assigned to) the task. */
  responsible_uid: string | null;
  /** Collaborator id of whoever created the task. */
  added_by_uid: string | null;
  added_at: string | null;
  labels: string[];
};

/**
 * A file attachment on a Todoist comment.
 *
 * The API returns this as the `file_attachment` object on a comment; the
 * write path (`createComment`) accepts the same shape with
 * `resource_type: "file"`.
 */
export type TodoistCommentAttachment = {
  file_name: string;
  file_type: string;
  file_url: string;
  resource_type?: string;
};

export type TodoistComment = {
  id: string;
  item_id: string;
  content: string;
  posted_at: string;
  /**
   * Collaborator id of the user who posted the comment. Used to attribute the
   * synced note to its real author rather than to the connector. May be absent
   * on older payloads.
   */
  posted_uid?: string | null;
  file_attachment?: TodoistCommentAttachment | null;
};

export type TodoistSection = {
  id: string;
  project_id: string;
  section_order: number;
  name: string;
};

/** Fields accepted when creating a task via POST /tasks. */
export type TodoistTaskCreate = {
  content: string;
  description?: string;
  project_id?: string;
  section_id?: string;
  due_string?: string;
  priority?: number;
  labels?: string[];
  assignee_id?: string;
};

/**
 * Fields accepted when updating a task via POST /tasks/{id}. All optional.
 * `section_id`/`project_id` are NOT accepted here in the v1 API — moving a
 * task between sections/projects is a dedicated endpoint, see {@link moveTask}.
 * `assignee_id` may be `null` to clear it.
 */
export type TodoistTaskUpdate = {
  content?: string;
  description?: string;
  assignee_id?: string | null;
  due_string?: string;
  priority?: number;
  labels?: string[];
};

/** Target to move a task to. Exactly one of these must be set. */
export type TodoistTaskMoveTarget =
  | { project_id: string; section_id?: undefined; parent_id?: undefined }
  | { section_id: string; project_id?: undefined; parent_id?: undefined }
  | { parent_id: string; project_id?: undefined; section_id?: undefined };

export type TodoistCollaborator = {
  id: string;
  name: string;
  email: string;
};

type PagedResponse<T> = { results: T[]; next_cursor: string | null };

async function request<T>(
  token: string,
  path: string,
  options?: RequestInit
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
    throw new Error(`Todoist API error ${response.status}: ${text}`);
  }
  // Some endpoints return 204 No Content
  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

/**
 * Fetch every page of a `{ results, next_cursor }` list endpoint and return
 * the concatenated results. All of this connector's list endpoints
 * (projects, tasks, sections, comments, collaborators) return small enough
 * sets per project that looping to exhaustion in one execution is safe.
 */
async function listAll<T>(
  token: string,
  path: string,
  params: Record<string, string> = {}
): Promise<T[]> {
  const results: T[] = [];
  let cursor: string | null = null;
  do {
    const qs = new URLSearchParams(params);
    if (cursor) qs.set("cursor", cursor);
    const query = qs.toString();
    const page = await request<PagedResponse<T>>(
      token,
      `${path}${query ? `?${query}` : ""}`
    );
    results.push(...page.results);
    cursor = page.next_cursor;
  } while (cursor);
  return results;
}

function withUrl(task: Omit<TodoistTask, "url">): TodoistTask {
  return { ...task, url: taskUrl(task.id) };
}

/**
 * List all projects for the authenticated user.
 */
export async function listProjects(
  token: string
): Promise<TodoistProject[]> {
  return listAll<TodoistProject>(token, "/projects");
}

/**
 * List active tasks, optionally filtered by project.
 */
export async function listTasks(
  token: string,
  projectId?: string
): Promise<TodoistTask[]> {
  const tasks = await listAll<Omit<TodoistTask, "url">>(
    token,
    "/tasks",
    projectId ? { project_id: projectId } : {}
  );
  return tasks.map(withUrl);
}

/**
 * Get a single task by ID.
 */
export async function getTask(
  token: string,
  taskId: string
): Promise<TodoistTask> {
  const task = await request<Omit<TodoistTask, "url">>(token, `/tasks/${taskId}`);
  return withUrl(task);
}

/**
 * Create a new task. `content` (title) is required; all other fields are
 * conditionally included so an undefined value never reaches the API.
 */
export async function createTask(
  token: string,
  content: string,
  fields: Omit<TodoistTaskCreate, "content"> = {}
): Promise<TodoistTask> {
  const body: TodoistTaskCreate = { content };
  if (fields.description !== undefined) body.description = fields.description;
  if (fields.project_id !== undefined) body.project_id = fields.project_id;
  if (fields.section_id !== undefined) body.section_id = fields.section_id;
  if (fields.due_string !== undefined) body.due_string = fields.due_string;
  if (fields.priority !== undefined) body.priority = fields.priority;
  if (fields.labels !== undefined) body.labels = fields.labels;
  if (fields.assignee_id !== undefined) body.assignee_id = fields.assignee_id;

  const task = await request<Omit<TodoistTask, "url">>(token, "/tasks", {
    method: "POST",
    body: JSON.stringify(body),
  });
  return withUrl(task);
}

/**
 * Update an existing task's content/description/assignee/etc. Does NOT move
 * the task between sections/projects — use {@link moveTask} for that (the v1
 * API rejects `section_id`/`project_id` on this endpoint).
 */
export async function updateTask(
  token: string,
  taskId: string,
  fields: TodoistTaskUpdate
): Promise<TodoistTask> {
  const body: Record<string, unknown> = {};
  if (fields.content !== undefined) body.content = fields.content;
  if (fields.description !== undefined) body.description = fields.description;
  if (fields.assignee_id !== undefined) body.assignee_id = fields.assignee_id;
  if (fields.due_string !== undefined) body.due_string = fields.due_string;
  if (fields.priority !== undefined) body.priority = fields.priority;
  if (fields.labels !== undefined) body.labels = fields.labels;

  const task = await request<Omit<TodoistTask, "url">>(token, `/tasks/${taskId}`, {
    method: "POST",
    body: JSON.stringify(body),
  });
  return withUrl(task);
}

/**
 * Move a task to a different project, section, or parent task. Exactly one
 * of `project_id`/`section_id`/`parent_id` must be set — moving to a project
 * clears any section (the v1 equivalent of v2's `section_id: null`).
 */
export async function moveTask(
  token: string,
  taskId: string,
  target: TodoistTaskMoveTarget
): Promise<TodoistTask> {
  const task = await request<Omit<TodoistTask, "url">>(
    token,
    `/tasks/${taskId}/move`,
    { method: "POST", body: JSON.stringify(target) }
  );
  return withUrl(task);
}

/**
 * List sections for a project.
 */
export async function listSections(
  token: string,
  projectId: string
): Promise<TodoistSection[]> {
  return listAll<TodoistSection>(token, "/sections", { project_id: projectId });
}

/**
 * List comments for a task.
 */
export async function listComments(
  token: string,
  taskId: string
): Promise<TodoistComment[]> {
  return listAll<TodoistComment>(token, "/comments", { task_id: taskId });
}

/**
 * Close (complete) a task.
 */
export async function closeTask(
  token: string,
  taskId: string
): Promise<void> {
  await request<void>(token, `/tasks/${taskId}/close`, {
    method: "POST",
  });
}

/**
 * Reopen a task.
 */
export async function reopenTask(
  token: string,
  taskId: string
): Promise<void> {
  await request<void>(token, `/tasks/${taskId}/reopen`, {
    method: "POST",
  });
}

/**
 * Create a comment on a task, optionally with a file attachment.
 *
 * The `attachment` shape is what Todoist returns from {@link uploadFile}
 * (`file_url` + `file_type`) plus a display `file_name`. Passing
 * `resource_type: "file"` tells Todoist to render it as a downloadable file.
 */
export async function createComment(
  token: string,
  taskId: string,
  content: string,
  attachment?: TodoistCommentAttachment
): Promise<TodoistComment> {
  const body: Record<string, unknown> = { task_id: taskId, content };
  if (attachment) {
    body.attachment = {
      file_name: attachment.file_name,
      file_type: attachment.file_type,
      file_url: attachment.file_url,
      resource_type: attachment.resource_type ?? "file",
    };
  }
  return request<TodoistComment>(token, "/comments", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

/**
 * Upload a file to Todoist's media store. Returns the stored `file_url` /
 * `file_type`, which can then be attached to a comment via
 * {@link createComment}'s `attachment` argument.
 *
 * This bypasses {@link request} because the endpoint is multipart
 * (`FormData`), not JSON. Cloudflare Workers' `fetch` supports `FormData`
 * with `Blob` parts natively, so no polyfill is required.
 */
export async function uploadFile(
  token: string,
  data: Uint8Array,
  fileName: string,
  mimeType?: string
): Promise<TodoistCommentAttachment> {
  const form = new FormData();
  form.append(
    "file",
    new Blob([data as BlobPart], mimeType ? { type: mimeType } : undefined),
    fileName
  );
  form.append("file_name", fileName);

  const response = await fetch(`${BASE_URL}/uploads`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      // Do NOT set Content-Type — fetch sets the multipart boundary itself.
    },
    body: form,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Todoist API error ${response.status}: ${text}`);
  }
  return response.json() as Promise<TodoistCommentAttachment>;
}

/**
 * Update an existing comment's content.
 */
export async function updateComment(
  token: string,
  commentId: string,
  content: string
): Promise<TodoistComment> {
  return request<TodoistComment>(token, `/comments/${commentId}`, {
    method: "POST",
    body: JSON.stringify({ content }),
  });
}

/**
 * List collaborators for a project.
 */
export async function listCollaborators(
  token: string,
  projectId: string
): Promise<TodoistCollaborator[]> {
  return listAll<TodoistCollaborator>(token, `/projects/${projectId}/collaborators`);
}
