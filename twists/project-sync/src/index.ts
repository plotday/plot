import { Asana } from "@plotday/tool-asana";
import { GitHubIssues } from "@plotday/tool-github-issues";
import { Jira } from "@plotday/tool-jira";
import { Linear } from "@plotday/tool-linear";
import {
  type Thread,
  type ThreadFilter,
  ActorType,
  type NewThreadWithNotes,
  type Note,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type { ProjectTool } from "@plotday/twister/common/projects";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";

type ProjectProvider = "linear" | "jira" | "asana" | "github-issues";

/**
 * Project Sync Twist
 *
 * Syncs project management tools (Linear, Jira, Asana) with Plot.
 * Converts issues and tasks into Plot activities with notes for comments.
 */
export default class ProjectSync extends Twist<ProjectSync> {
  build(build: ToolBuilder) {
    return {
      linear: build(Linear, {
        onItem: this.onLinearItem,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      jira: build(Jira, {
        onItem: this.onJiraItem,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      asana: build(Asana, {
        onItem: this.onAsanaItem,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      githubIssues: build(GitHubIssues, {
        onItem: this.onGitHubIssuesItem,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Create,
          updated: this.onThreadUpdated,
        },
        note: {
          created: this.onNoteCreated,
        },
      }),
    };
  }

  /**
   * Get the tool for a specific project provider
   */
  private getProviderTool(provider: ProjectProvider): ProjectTool {
    switch (provider) {
      case "linear":
        return this.tools.linear;
      case "jira":
        return this.tools.jira;
      case "asana":
        return this.tools.asana;
      case "github-issues":
        return this.tools.githubIssues;
      default:
        throw new Error(`Unknown provider: ${provider}`);
    }
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and project selection are now handled in the twist edit modal.
  }

  async onLinearItem(item: NewThreadWithNotes) {
    return this.onIssue(item, "linear");
  }

  async onJiraItem(item: NewThreadWithNotes) {
    return this.onIssue(item, "jira");
  }

  async onAsanaItem(item: NewThreadWithNotes) {
    return this.onIssue(item, "asana");
  }

  async onGitHubIssuesItem(item: NewThreadWithNotes) {
    return this.onIssue(item, "github-issues");
  }

  async onSyncableDisabled(filter: ThreadFilter): Promise<void> {
    await this.tools.plot.updateThread({ match: filter, archived: true });
  }

  /**
   * Check if a note is fully empty (no content, no links, no mentions)
   */
  private isNoteEmpty(note: {
    content?: string | null;
    links?: any[] | null;
    mentions?: any[] | null;
  }): boolean {
    return (
      (!note.content || note.content.trim() === "") &&
      (!note.links || note.links.length === 0) &&
      (!note.mentions || note.mentions.length === 0)
    );
  }

  /**
   * Called for each issue synced from any provider.
   * Creates or updates Plot activities based on issue state.
   */
  async onIssue(
    issue: NewThreadWithNotes,
    provider: ProjectProvider
  ) {
    // Add provider to meta for routing updates back to the correct tool
    issue.meta = { ...issue.meta, provider };

    // Filter out empty notes to avoid warnings in Plot tool
    issue.notes = issue.notes?.filter((note) => !this.isNoteEmpty(note));

    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createThread(issue);
  }

  /**
   * Called when a thread created by this twist is updated.
   * Syncs changes back to the external service.
   */
  private async onThreadUpdated(
    thread: Thread,
    _changes: {
      tagsAdded: Record<string, string[]>;
      tagsRemoved: Record<string, string[]>;
    }
  ): Promise<void> {
    // Get provider from meta (set by this twist when creating the thread)
    const provider = thread.meta?.provider as ProjectProvider | undefined;
    if (!provider) return;

    const tool = this.getProviderTool(provider);

    try {
      // Sync all changes using the generic updateIssue method
      // Tool reads its own IDs from thread.meta (e.g., linearId, taskGid, issueKey)
      // Tool resolves auth token internally via integrations
      if (tool.updateIssue) {
        await tool.updateIssue(thread);
      }
    } catch (error) {
      console.error(`Failed to sync thread update to ${provider}:`, error);
    }
  }

  /**
   * Called when a note is created on a thread created by this twist.
   * Syncs the note as a comment to the external service.
   */
  private async onNoteCreated(note: Note): Promise<void> {
    const thread = note.thread;

    // Filter out notes created by twists to prevent loops
    if (note.author.type === ActorType.Twist) {
      return;
    }

    // Only sync if note has content
    if (!note.content) {
      return;
    }

    // Get provider from meta (set by this twist when creating the thread)
    const provider = thread.meta?.provider as ProjectProvider | undefined;
    if (!provider || !thread.meta) {
      return;
    }

    const tool = this.getProviderTool(provider);
    if (!tool.addIssueComment) {
      console.warn(`Provider ${provider} does not support adding comments`);
      return;
    }

    try {
      // Tool resolves auth token internally via integrations
      const commentKey = await tool.addIssueComment(
        thread.meta,
        note.content,
        note.id
      );
      if (commentKey) {
        await this.tools.plot.updateNote({ id: note.id, key: commentKey });
      }
    } catch (error) {
      console.error(`Failed to sync note to ${provider}:`, error);
    }
  }
}
