import { GitHub } from "@plotday/tool-github";
import {
  type Activity,
  type ActivityFilter,
  ActorType,
  type NewActivityWithNotes,
  type Note,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type { SourceControlTool } from "@plotday/twister/common/source-control";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

type SourceControlProvider = "github";

/**
 * Code Review Twist
 *
 * Syncs source control tools (GitHub) with Plot.
 * Converts pull requests into Plot activities with notes for comments
 * and review summaries.
 */
export default class CodeReview extends Twist<CodeReview> {
  build(build: ToolBuilder) {
    return {
      github: build(GitHub, {
        onItem: this.onGitHubItem,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
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
   * Get the tool for a specific source control provider
   */
  private getProviderTool(provider: SourceControlProvider): SourceControlTool {
    switch (provider) {
      case "github":
        return this.tools.github;
      default:
        throw new Error(`Unknown provider: ${provider}`);
    }
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and repository selection are handled in the twist edit modal.
  }

  async onGitHubItem(item: NewActivityWithNotes) {
    return this.onPullRequest(item, "github");
  }

  async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
    await this.tools.plot.updateActivity({ match: filter, archived: true });
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
   * Called for each PR synced from any provider.
   * Creates or updates Plot activities based on PR state.
   */
  async onPullRequest(
    pr: NewActivityWithNotes,
    provider: SourceControlProvider,
  ) {
    // Add provider to meta for routing updates back to the correct tool
    pr.meta = { ...pr.meta, provider };

    // Filter out empty notes to avoid warnings in Plot tool
    pr.notes = pr.notes?.filter((note) => !this.isNoteEmpty(note));

    // Create/upsert - database handles everything automatically
    await this.tools.plot.createActivity(pr);
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
    },
  ): Promise<void> {
    const provider = activity.meta?.provider as
      | SourceControlProvider
      | undefined;
    if (!provider) return;

    const tool = this.getProviderTool(provider);

    try {
      if (tool.updatePRStatus) {
        await tool.updatePRStatus(activity);
      }
    } catch (error) {
      console.error(
        `Failed to sync activity update to ${provider}:`,
        error,
      );
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

    const provider = activity.meta?.provider as
      | SourceControlProvider
      | undefined;
    if (!provider || !activity.meta) {
      return;
    }

    const tool = this.getProviderTool(provider);
    if (!tool.addPRComment) {
      console.warn(
        `Provider ${provider} does not support adding PR comments`,
      );
      return;
    }

    try {
      const commentKey = await tool.addPRComment(
        activity.meta,
        note.content,
        note.id,
      );
      if (commentKey) {
        await this.tools.plot.updateNote({ id: note.id, key: commentKey });
      }
    } catch (error) {
      console.error(`Failed to sync note to ${provider}:`, error);
    }
  }
}
