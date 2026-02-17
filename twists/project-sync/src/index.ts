import { Asana } from "@plotday/tool-asana";
import { Jira } from "@plotday/tool-jira";
import { Linear } from "@plotday/tool-linear";
import {
  type Activity,
  ActorType,
  type NewActivityWithNotes,
  type Note,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type { ProjectTool } from "@plotday/twister/common/projects";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

type ProjectProvider = "linear" | "jira" | "asana";

/**
 * Project Sync Twist
 *
 * Syncs project management tools (Linear, Jira, Asana) with Plot.
 * Converts issues and tasks into Plot activities with notes for comments.
 */
export default class ProjectSync extends Twist<ProjectSync> {
  build(build: ToolBuilder) {
    return {
      linear: build(Linear),
      jira: build(Jira),
      asana: build(Asana),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
          updated: this.onActivityUpdated,
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
      default:
        throw new Error(`Unknown provider: ${provider}`);
    }
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and project selection are now handled in the twist edit modal.
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
    issue: NewActivityWithNotes,
    provider: ProjectProvider,
    _projectId: string
  ) {
    // Add provider to meta for routing updates back to the correct tool
    issue.meta = { ...issue.meta, provider };

    // Filter out empty notes to avoid warnings in Plot tool
    issue.notes = issue.notes?.filter((note) => !this.isNoteEmpty(note));

    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createActivity(issue);
  }

  /**
   * Called when an activity created by this twist is updated.
   * Syncs changes back to the external service.
   */
  private async onActivityUpdated(
    activity: Activity,
    _changes: {
      tagsAdded: Record<string, string[]>;
      tagsRemoved: Record<string, string[]>;
    }
  ): Promise<void> {
    // Get provider from meta (set by this twist when creating the activity)
    const provider = activity.meta?.provider as ProjectProvider | undefined;
    if (!provider) return;

    const tool = this.getProviderTool(provider);

    try {
      // Sync all changes using the generic updateIssue method
      // Tool reads its own IDs from activity.meta (e.g., linearId, taskGid, issueKey)
      // Tool resolves auth token internally via integrations
      if (tool.updateIssue) {
        await tool.updateIssue(activity);
      }
    } catch (error) {
      console.error(`Failed to sync activity update to ${provider}:`, error);
    }
  }

  /**
   * Called when a note is created on an activity created by this twist.
   * Syncs the note as a comment to the external service.
   */
  private async onNoteCreated(note: Note): Promise<void> {
    const activity = note.activity;

    // Filter out notes created by twists to prevent loops
    if (note.author.type === ActorType.Twist) {
      return;
    }

    // Only sync if note has content
    if (!note.content) {
      return;
    }

    // Get provider from meta (set by this twist when creating the activity)
    const provider = activity.meta?.provider as ProjectProvider | undefined;
    if (!provider || !activity.meta) {
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
        activity.meta,
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
