import { GoogleDrive } from "@plotday/tool-google-drive";
import {
  type ActivityFilter,
  type NewActivityWithNotes,
  type Note,
  type Priority,
  ActorType,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type { DocumentTool } from "@plotday/twister/common/documents";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

/**
 * Document Actions Twist
 *
 * Syncs documents, comments, and action items from Google Drive with Plot.
 * Converts documents into Plot activities with notes for comments,
 * syncs Plot notes back as comments on the documents,
 * and tags action items with Tag.Now for assigned users.
 */
export default class DocumentActions extends Twist<DocumentActions> {
  build(build: ToolBuilder) {
    return {
      googleDrive: build(GoogleDrive, {
        onItem: this.onDocument,
        onSyncableDisabled: this.onSyncableDisabled,
      }),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
        note: {
          created: this.onNoteCreated,
        },
      }),
    };
  }

  /**
   * Get the document tool for a provider.
   * Currently only Google Drive is supported.
   */
  private getProviderTool(_provider: string): DocumentTool {
    return this.tools.googleDrive;
  }

  async activate(_priority: Pick<Priority, "id">) {
    // Auth and folder selection are now handled in the twist edit modal.
  }

  async onSyncableDisabled(filter: ActivityFilter): Promise<void> {
    await this.tools.plot.updateActivity({ match: filter, archived: true });
  }

  /**
   * Called for each document synced from Google Drive.
   */
  async onDocument(doc: NewActivityWithNotes) {
    // Add provider to meta for routing updates back
    doc.meta = { ...doc.meta, provider: "google-drive" };

    await this.tools.plot.createActivity(doc);
  }

  /**
   * Called when a note is created on an activity created by this twist.
   * Syncs the note as a comment or reply to Google Drive.
   */
  private async onNoteCreated(note: Note): Promise<void> {
    const activity = note.activity;

    // Filter out twist-authored notes to prevent loops
    if (note.author.type === ActorType.Twist) {
      return;
    }

    // Only sync if note has content
    if (!note.content) {
      return;
    }

    // Get provider from meta
    const provider = activity.meta?.provider as string | undefined;
    if (!provider || !activity.meta) {
      return;
    }

    const tool = this.getProviderTool(provider);

    // Determine if this is a reply and find the Google Drive comment ID
    let commentId: string | null = null;
    if (note.reNote?.id && tool.addDocumentReply) {
      commentId = await this.resolveCommentId(note);
    }

    try {
      // Tool resolves auth token internally via integrations
      let commentKey: string | void;
      if (commentId && tool.addDocumentReply) {
        // Reply to existing comment thread
        commentKey = await tool.addDocumentReply(
          activity.meta,
          commentId,
          note.content,
          note.id
        );
      } else if (tool.addDocumentComment) {
        // Top-level comment
        commentKey = await tool.addDocumentComment(
          activity.meta,
          note.content,
          note.id
        );
      } else {
        return;
      }
      if (commentKey) {
        await this.tools.plot.updateNote({ id: note.id, key: commentKey });
      }
    } catch (error) {
      console.error("Failed to sync note to provider:", error);
    }
  }

  /**
   * Walks the reNote chain to find the root Google Drive comment ID.
   * Returns the commentId extracted from a key like "comment-{commentId}",
   * or null if the chain doesn't lead to a synced comment.
   */
  private async resolveCommentId(note: Note): Promise<string | null> {
    // Fetch all notes for the activity to build the lookup map
    const notes = await this.tools.plot.getNotes(note.activity);
    const noteMap = new Map(notes.map((n) => [n.id, n]));

    // Walk up the reNote chain
    let currentId = note.reNote?.id;
    const visited = new Set<string>();

    while (currentId) {
      if (visited.has(currentId)) break; // Prevent infinite loops
      visited.add(currentId);

      const parent = noteMap.get(currentId);
      if (!parent) break;

      // Check if this note's key is a comment key
      if (parent.key?.startsWith("comment-")) {
        return parent.key.slice("comment-".length);
      }

      // Check if this note's key is a reply key (extract commentId)
      if (parent.key?.startsWith("reply-")) {
        const parts = parent.key.split("-");
        // key format: "reply-{commentId}-{replyId}"
        if (parts.length >= 3) {
          return parts[1];
        }
      }

      // Continue up the chain
      currentId = parent.reNote?.id;
    }

    return null;
  }
}
