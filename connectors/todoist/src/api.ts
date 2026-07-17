/**
 * Todoist REST API v2 client helpers.
 *
 * Uses the REST API directly.
 * https://developer.todoist.com/rest/v2/
 */

const BASE_URL = "https://api.todoist.com/rest/v2";
const SYNC_URL = "https://api.todoist.com/sync/v9";

export type TodoistProject = {
  id: string;
  name: string;
  color: string;
  is_shared: boolean;
  order: number;
  is_favorite: boolean;
  url: string;
};

export type TodoistTask = {
  id: string;
  content: string;
  description: string;
  is_completed: boolean;
  project_id: string;
  /** Section the task belongs to, or null if it is not in a section. */
  section_id: string | null;
  parent_id: string | null;
  order: number;
  priority: number; // 1 (normal) to 4 (urgent)
  due: {
    date: string;
    string: string;
    datetime: string | null;
    timezone: string | null;
    is_recurring: boolean;
  } | null;
  url: string;
  assignee_id: string | null;
  creator_id: string;
  created_at: string;
  labels: string[];
};

/**
 * A file attachment on a Todoist comment.
 *
 * REST v2 returns this as the `attachment` object on a comment; the write
 * path (`createComment`) accepts the same shape with `resource_type: "file"`.
 */
export type TodoistCommentAttachment = {
  file_name: string;
  file_type: string;
  file_url: string;
  resource_type?: string;
};

export type TodoistComment = {
  id: string;
  task_id: string;
  content: string;
  posted_at: string;
  /**
   * Collaborator id of the user who posted the comment. Used to attribute the
   * synced note to its real author rather than to the connector. May be absent
   * on older payloads.
   */
  posted_uid?: string | null;
  attachment?: TodoistCommentAttachment | null;
};

export type TodoistSection = {
  id: string;
  project_id: string;
  order: number;
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
 * Fields accepted when updating a task via POST /tasks/{id}. All optional;
 * `assignee_id`/`section_id` may be null to clear. REST v2 supports
 * `section_id` directly — no Sync `item_move` needed.
 */
export type TodoistTaskUpdate = {
  content?: string;
  description?: string;
  section_id?: string | null;
  assignee_id?: string | null;
  due_string?: string;
  priority?: number;
  labels?: string[];
};

export type TodoistCollaborator = {
  id: string;
  name: string;
  email: string;
};

async function request<T>(
  token: string,
  path: string,
  options?: RequestInit
): Promise<T> {
  const url = path.startsWith("/sync/")
    ? `${SYNC_URL}${path.replace("/sync/", "/")}`
    : `${BASE_URL}${path}`;

  const response = await fetch(url, {
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
 * List all projects for the authenticated user.
 */
export async function listProjects(
  token: string
): Promise<TodoistProject[]> {
  return request<TodoistProject[]>(token, "/projects");
}

/**
 * List active tasks, optionally filtered by project.
 */
export async function listTasks(
  token: string,
  projectId?: string
): Promise<TodoistTask[]> {
  const params = new URLSearchParams();
  if (projectId) {
    params.set("project_id", projectId);
  }
  const query = params.toString();
  return request<TodoistTask[]>(
    token,
    `/tasks${query ? `?${query}` : ""}`
  );
}

/**
 * Get a single task by ID.
 */
export async function getTask(
  token: string,
  taskId: string
): Promise<TodoistTask> {
  return request<TodoistTask>(token, `/tasks/${taskId}`);
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

  return request<TodoistTask>(token, "/tasks", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

/**
 * Update an existing task. Only the provided fields are sent. `section_id`
 * and `assignee_id` may be `null` to clear them (REST v2 accepts null).
 */
export async function updateTask(
  token: string,
  taskId: string,
  fields: TodoistTaskUpdate
): Promise<TodoistTask> {
  const body: Record<string, unknown> = {};
  if (fields.content !== undefined) body.content = fields.content;
  if (fields.description !== undefined) body.description = fields.description;
  if (fields.section_id !== undefined) body.section_id = fields.section_id;
  if (fields.assignee_id !== undefined) body.assignee_id = fields.assignee_id;
  if (fields.due_string !== undefined) body.due_string = fields.due_string;
  if (fields.priority !== undefined) body.priority = fields.priority;
  if (fields.labels !== undefined) body.labels = fields.labels;

  return request<TodoistTask>(token, `/tasks/${taskId}`, {
    method: "POST",
    body: JSON.stringify(body),
  });
}

/**
 * List sections for a project.
 */
export async function listSections(
  token: string,
  projectId: string
): Promise<TodoistSection[]> {
  return request<TodoistSection[]>(
    token,
    `/sections?project_id=${encodeURIComponent(projectId)}`
  );
}

/**
 * List comments for a task.
 */
export async function listComments(
  token: string,
  taskId: string
): Promise<TodoistComment[]> {
  return request<TodoistComment[]>(
    token,
    `/comments?task_id=${encodeURIComponent(taskId)}`
  );
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

  const response = await fetch(`${SYNC_URL}/uploads/add`, {
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
 *
 * Todoist's REST v2 supports POST /comments/{id} for partial updates.
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
  return request<TodoistCollaborator[]>(
    token,
    `/projects/${projectId}/collaborators`
  );
}
