import {
  type Action,
  ActionType,
  type Link,
  type NewLinkWithNotes,
} from "@plotday/twister";
import { Tag } from "@plotday/twister/tag";
import { Connector } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import {
  listTaskLists,
  listTasks,
  updateTask,
  type GoogleTask,
} from "./api";

/** 5 minutes in milliseconds */
const POLL_INTERVAL_MS = 5 * 60 * 1000;

type SyncState = {
  pageToken: string | null;
  batchNumber: number;
  tasksProcessed: number;
  initialSync: boolean;
};

/**
 * Google Tasks connector
 *
 * Syncs Google Tasks lists and tasks with Plot threads.
 * Uses polling (5-minute intervals) since Google Tasks API
 * does not support webhooks.
 */
export class GoogleTasks extends Connector<GoogleTasks> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = ["https://www.googleapis.com/auth/tasks"];

  readonly provider = AuthProvider.Google;
  readonly scopes = GoogleTasks.SCOPES;
  readonly linkTypes = [
    {
      type: "task",
      label: "Task",
      // Logo: full-color SVG from static assets (iconify has no logos/google-tasks)
      // logoMono: monochrome version from simple-icons (works fine on iconify)
      logo: "https://plot.day/assets/logo-google-tasks.svg",
      logoMono: "https://api.iconify.design/simple-icons/googletasks.svg",
      statuses: [
        { status: "open", label: "Open" },
        { status: "done", label: "Done", tag: Tag.Done, done: true },
      ],
      supportsAssignee: false,
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://tasks.googleapis.com/*"] }),
      tasks: build(Tasks),
    };
  }

  /**
   * Get an access token for a channel (task list).
   */
  private async getToken(channelId: string): Promise<string> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Google Tasks authentication token available");
    }
    return token.token;
  }

  /**
   * Returns available Google Tasks lists as channels.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const lists = await listTaskLists(token.token);
    return lists.map((list) => ({ id: list.id, title: list.title }));
  }

  /**
   * Called when a channel (task list) is enabled.
   * Starts initial sync and schedules periodic polling.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);
    await this.startBatchSync(channel.id);
  }

  /**
   * Called when a channel is disabled.
   * Stops polling and archives links from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.clear(`sync_enabled_${channel.id}`);
    await this.clear(`sync_state_${channel.id}`);
    await this.clear(`last_sync_time_${channel.id}`);
    await this.clear(`poll_task_${channel.id}`);

    await this.tools.integrations.archiveLinks({
      channelId: channel.id,
    });
  }

  /**
   * Initialize batch sync process for a task list.
   */
  private async startBatchSync(listId: string): Promise<void> {
    await this.set(`sync_state_${listId}`, {
      pageToken: null,
      batchNumber: 1,
      tasksProcessed: 0,
      initialSync: true,
    } satisfies SyncState);

    const batchCallback = await this.callback(this.syncBatch, listId);
    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of tasks from a Google Tasks list.
   */
  private async syncBatch(listId: string): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${listId}`);
    if (!state) {
      throw new Error(`Sync state not found for list ${listId}`);
    }

    const token = await this.getToken(listId);

    // Fetch batch of tasks
    const result = await listTasks(token, listId, {
      showCompleted: false,
      pageToken: state.pageToken ?? undefined,
      maxResults: 50,
    });

    // Separate parent tasks and subtasks
    const parentTasks: GoogleTask[] = [];
    const subtasksByParent = new Map<string, GoogleTask[]>();

    for (const task of result.tasks) {
      if (task.parent) {
        const existing = subtasksByParent.get(task.parent) ?? [];
        existing.push(task);
        subtasksByParent.set(task.parent, existing);
      } else {
        parentTasks.push(task);
      }
    }

    // Process parent tasks with their subtasks
    for (const task of parentTasks) {
      const subtasks = subtasksByParent.get(task.id) ?? [];
      const link = this.transformTask(
        task,
        listId,
        state.initialSync,
        subtasks
      );
      await this.tools.integrations.saveLink(link);
    }

    // Handle subtasks whose parents weren't in this batch
    for (const [parentId, subtasks] of subtasksByParent) {
      if (!parentTasks.some((t) => t.id === parentId)) {
        // Save subtasks as standalone tasks
        for (const subtask of subtasks) {
          const link = this.transformTask(
            subtask,
            listId,
            state.initialSync,
            []
          );
          await this.tools.integrations.saveLink(link);
        }
      }
    }

    if (result.nextPageToken) {
      // More pages to process
      await this.set(`sync_state_${listId}`, {
        pageToken: result.nextPageToken,
        batchNumber: state.batchNumber + 1,
        tasksProcessed: state.tasksProcessed + result.tasks.length,
        initialSync: state.initialSync,
      } satisfies SyncState);

      const nextBatch = await this.callback(this.syncBatch, listId);
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Sync complete — store last sync time and schedule polling
      await this.clear(`sync_state_${listId}`);
      await this.set(
        `last_sync_time_${listId}`,
        new Date().toISOString()
      );
      await this.schedulePeriodicSync(listId);
    }
  }

  /**
   * Schedule the next periodic sync for a task list.
   */
  private async schedulePeriodicSync(listId: string): Promise<void> {
    const runAt = new Date(Date.now() + POLL_INTERVAL_MS);
    const pollCallback = await this.callback(this.periodicSync, listId);
    const taskToken = await this.tools.tasks.runTask(pollCallback, {
      runAt,
    });
    if (taskToken) {
      await this.set(`poll_task_${listId}`, taskToken);
    }
  }

  /**
   * Periodic sync: fetch tasks updated since last sync, then reschedule.
   */
  private async periodicSync(listId: string): Promise<void> {
    // Check if sync is still enabled
    const enabled = await this.get<boolean>(`sync_enabled_${listId}`);
    if (!enabled) return;

    const lastSync = await this.get<string>(`last_sync_time_${listId}`);
    const token = await this.getToken(listId);

    let pageToken: string | undefined;
    do {
      const result = await listTasks(token, listId, {
        updatedMin: lastSync ?? undefined,
        pageToken,
        maxResults: 50,
      });

      // Separate parent tasks and subtasks
      const parentTasks: GoogleTask[] = [];
      const subtasksByParent = new Map<string, GoogleTask[]>();

      for (const task of result.tasks) {
        if (task.parent) {
          const existing = subtasksByParent.get(task.parent) ?? [];
          existing.push(task);
          subtasksByParent.set(task.parent, existing);
        } else {
          parentTasks.push(task);
        }
      }

      for (const task of parentTasks) {
        const subtasks = subtasksByParent.get(task.id) ?? [];
        const link = this.transformTask(task, listId, false, subtasks);
        await this.tools.integrations.saveLink(link);
      }

      // Orphan subtasks
      for (const [parentId, subtasks] of subtasksByParent) {
        if (!parentTasks.some((t) => t.id === parentId)) {
          for (const subtask of subtasks) {
            const link = this.transformTask(subtask, listId, false, []);
            await this.tools.integrations.saveLink(link);
          }
        }
      }

      pageToken = result.nextPageToken;
    } while (pageToken);

    // Update last sync time and reschedule
    await this.set(`last_sync_time_${listId}`, new Date().toISOString());
    await this.schedulePeriodicSync(listId);
  }

  /**
   * Convert a Google Task to a Plot link with notes.
   */
  private transformTask(
    task: GoogleTask,
    listId: string,
    initialSync: boolean,
    subtasks: GoogleTask[]
  ): NewLinkWithNotes {
    const source = `google-tasks:task:${task.id}`;
    const taskUrl =
      task.webViewLink ??
      `https://tasks.google.com/task/${encodeURIComponent(task.id)}`;

    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Google Tasks",
        url: taskUrl,
      },
    ];

    // Build notes
    const notes: any[] = [];

    // Description note
    if (task.notes && task.notes.trim().length > 0) {
      notes.push({
        key: "description",
        content: task.notes,
        contentType: "text" as const,
      });
    }

    // Subtask notes with Todo tag
    for (const subtask of subtasks) {
      notes.push({
        key: `subtask-${subtask.id}`,
        content: subtask.title,
        tags: {
          add: subtask.status === "completed" ? [Tag.Done] : [Tag.Todo],
        },
      });
    }

    return {
      source,
      type: "task",
      title: task.title,
      channelId: listId,
      meta: {
        taskId: task.id,
        listId,
        syncProvider: "google-tasks",
        channelId: listId,
      },
      actions,
      sourceUrl: taskUrl,
      status: task.status === "completed" ? "done" : "open",
      notes,
      preview: task.notes?.slice(0, 200) || null,
      ...(task.due
        ? {
            schedules: [
              {
                start: task.due.split("T")[0],
              },
            ],
          }
        : {}),
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };
  }

  /**
   * Write back link status changes to Google Tasks.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const taskId = link.meta?.taskId as string | undefined;
    const listId = link.meta?.listId as string | undefined;
    if (!taskId || !listId) return;

    const token = await this.getToken(listId);
    const isDone = link.status === "done";

    await updateTask(token, listId, taskId, {
      status: isDone ? "completed" : "needsAction",
    });
  }
}

export default GoogleTasks;
