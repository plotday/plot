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

export type TodoistComment = {
  id: string;
  task_id: string;
  content: string;
  posted_at: string;
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
 * Create a comment on a task.
 */
export async function createComment(
  token: string,
  taskId: string,
  content: string
): Promise<TodoistComment> {
  return request<TodoistComment>(token, "/comments", {
    method: "POST",
    body: JSON.stringify({ task_id: taskId, content }),
  });
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

/**
 * Verify a Todoist webhook signature using HMAC-SHA256.
 */
export async function verifyWebhookSignature(
  clientSecret: string,
  rawBody: string,
  signature: string | undefined
): Promise<boolean> {
  if (!signature) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(clientSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(rawBody)
  );

  // Convert to base64
  const expectedSignature = btoa(
    String.fromCharCode(...new Uint8Array(signatureBytes))
  );

  return signature === expectedSignature;
}
