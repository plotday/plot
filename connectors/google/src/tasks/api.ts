/**
 * Google Tasks API client helpers.
 *
 * Uses the REST API directly since there's no official SDK for Workers.
 * https://developers.google.com/tasks/reference/rest
 */

const BASE_URL = "https://tasks.googleapis.com/tasks/v1";

/**
 * Error thrown by the Google Tasks REST client. Carries the HTTP `status` so
 * callers can distinguish a permanent "resource gone" (404) — e.g. the user
 * deleted a task list while its Plot channel was still enabled — from
 * transient 5xx/429 failures worth retrying. `body` is kept as the raw
 * response text (rather than only baked into `message`) so callers can parse
 * it to distinguish error shapes sharing the same status code.
 *
 * The message format is preserved verbatim (`Google Tasks API error
 * <status>: <body>`) for backwards compatibility with existing logs/grouping.
 */
export class GoogleTasksApiError extends Error {
  readonly status: number;
  readonly body: string;

  constructor(status: number, body: string) {
    super(`Google Tasks API error ${status}: ${body}`);
    this.name = "GoogleTasksApiError";
    this.status = status;
    this.body = body;
  }
}

/**
 * True when the error indicates the target task list no longer exists (or is
 * no longer valid) on Google's side. This is permanent: retrying or
 * reporting it to error tracking is pure noise.
 *
 * List-scoped read/write endpoints (`tasks.list`, `tasks.patch`, ...) return a
 * plain 404 for a deleted list. `tasks.insert` (create) is inconsistent and
 * instead returns a 400 with the literal top-level message "Invalid task
 * list ID" — both shapes mean the same underlying thing and must be
 * recognized here so every call site can treat them identically.
 */
export function isTaskListGoneError(error: unknown): boolean {
  if (!(error instanceof GoogleTasksApiError)) return false;
  if (error.status === 404) return true;
  if (error.status === 400) {
    try {
      const parsed = JSON.parse(error.body) as { error?: { message?: string } };
      return parsed.error?.message === "Invalid task list ID";
    } catch {
      return false;
    }
  }
  return false;
}

export type GoogleTaskList = {
  id: string;
  title: string;
  updated: string;
  selfLink: string;
};

export type GoogleTask = {
  id: string;
  title: string;
  notes?: string;
  status: "needsAction" | "completed";
  due?: string;
  completed?: string;
  updated: string;
  parent?: string;
  position: string;
  selfLink: string;
  webViewLink?: string;
  links?: Array<{ type: string; description: string; link: string }>;
};

type TaskListResponse = {
  items?: GoogleTaskList[];
  nextPageToken?: string;
};

type TasksResponse = {
  items?: GoogleTask[];
  nextPageToken?: string;
};

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
    throw new GoogleTasksApiError(response.status, text);
  }
  return response.json() as Promise<T>;
}

/**
 * List all task lists for the authenticated user.
 */
export async function listTaskLists(
  token: string
): Promise<GoogleTaskList[]> {
  const allLists: GoogleTaskList[] = [];
  let pageToken: string | undefined;

  do {
    const params = new URLSearchParams({ maxResults: "100" });
    if (pageToken) params.set("pageToken", pageToken);

    const result = await request<TaskListResponse>(
      token,
      `/users/@me/lists?${params}`
    );
    if (result.items) {
      allLists.push(...result.items);
    }
    pageToken = result.nextPageToken;
  } while (pageToken);

  return allLists;
}

/**
 * List tasks in a task list.
 */
export async function listTasks(
  token: string,
  listId: string,
  options?: {
    showCompleted?: boolean;
    updatedMin?: string;
    pageToken?: string;
    maxResults?: number;
  }
): Promise<{ tasks: GoogleTask[]; nextPageToken?: string }> {
  const params = new URLSearchParams({
    maxResults: String(options?.maxResults ?? 50),
  });
  if (options?.showCompleted !== undefined) {
    params.set("showCompleted", String(options.showCompleted));
    if (options.showCompleted) {
      params.set("showHidden", "true");
    }
  }
  if (options?.updatedMin) {
    params.set("updatedMin", options.updatedMin);
    // When using updatedMin, must show completed to get status changes
    params.set("showCompleted", "true");
    params.set("showHidden", "true");
  }
  if (options?.pageToken) {
    params.set("pageToken", options.pageToken);
  }

  const result = await request<TasksResponse>(
    token,
    `/lists/${encodeURIComponent(listId)}/tasks?${params}`
  );

  return {
    tasks: result.items ?? [],
    nextPageToken: result.nextPageToken,
  };
}

/**
 * Update a task's status.
 */
export async function updateTask(
  token: string,
  listId: string,
  taskId: string,
  updates: { status?: "needsAction" | "completed" }
): Promise<GoogleTask> {
  return request<GoogleTask>(
    token,
    `/lists/${encodeURIComponent(listId)}/tasks/${encodeURIComponent(taskId)}`,
    {
      method: "PATCH",
      body: JSON.stringify(updates),
    }
  );
}

/**
 * Create a new task in a task list.
 */
export async function createTask(
  token: string,
  listId: string,
  task: {
    title: string;
    notes?: string;
    status?: "needsAction" | "completed";
    due?: string;
  }
): Promise<GoogleTask> {
  return request<GoogleTask>(
    token,
    `/lists/${encodeURIComponent(listId)}/tasks`,
    {
      method: "POST",
      body: JSON.stringify(task),
    }
  );
}
