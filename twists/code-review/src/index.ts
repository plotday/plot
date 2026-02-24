import { GitHub } from "@plotday/tool-github";
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
import type { SourceControlTool } from "@plotday/twister/common/source-control";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";

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

  async onGitHubItem(item: NewThreadWithNotes) {
    return this.onPullRequest(item, "github");
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
   * Called for each PR synced from any provider.
   * Creates or updates Plot activities based on PR state.
   */
  async onPullRequest(
    pr: NewThreadWithNotes,
    provider: SourceControlProvider,
  ) {
    // Add provider to meta for routing updates back to the correct tool
    pr.meta = { ...pr.meta, provider };

    // Filter out empty notes to avoid warnings in Plot tool
    pr.notes = pr.notes?.filter((note) => !this.isNoteEmpty(note));

    // Create/upsert - database handles everything automatically
    await this.tools.plot.createThread(pr);
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
    },
  ): Promise<void> {
    const provider = thread.meta?.provider as
      | SourceControlProvider
      | undefined;
    if (!provider) return;

    const tool = this.getProviderTool(provider);

    try {
      if (tool.updatePRStatus) {
        await tool.updatePRStatus(thread);
      }
    } catch (error) {
      console.error(
        `Failed to sync thread update to ${provider}:`,
        error,
      );
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

    const provider = thread.meta?.provider as
      | SourceControlProvider
      | undefined;
    if (!provider || !thread.meta) {
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
        thread.meta,
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
