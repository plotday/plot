import { GoogleDrive } from "@plotday/tool-google-drive";
import {
  type Activity,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  ActorType,
  type NewActivityWithNotes,
  type Note,
  type Priority,
  type Actor,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type {
  DocumentAuth,
  DocumentTool,
} from "@plotday/twister/common/documents";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";
import { Uuid } from "@plotday/twister/utils/uuid";

/**
 * Document Comments Twist
 *
 * Syncs documents and comments from Google Drive with Plot.
 * Converts documents into Plot activities with notes for comments,
 * and syncs Plot notes back as comments on the documents.
 */
export default class DocumentComments extends Twist<DocumentComments> {
  build(build: ToolBuilder) {
    return {
      googleDrive: build(GoogleDrive),
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

  // --- Lifecycle ---

  /**
   * Called when twist is activated.
   * Creates a private onboarding activity with Google Drive auth link.
   */
  async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
    const authLink = await this.tools.googleDrive.requestAuth(
      this.onAuthComplete,
      "google-drive"
    );

    const activityId = await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect Google Drive",
      private: true,
      notes: [
        {
          content:
            "Connect your Google Drive account to sync documents and comments to Plot.",
          links: [authLink],
          ...(context?.actor ? { mentions: [{ id: context.actor.id }] } : {}),
        },
      ],
    });

    await this.set("onboarding_activity_id", activityId);
  }

  /**
   * Called when OAuth completes.
   * Fetches available folders and presents selection UI.
   */
  async onAuthComplete(auth: DocumentAuth, _provider: string) {
    await this.set("auth_token", auth.authToken);

    // Fetch folders
    const folders = await this.tools.googleDrive.getFolders(auth.authToken);

    if (folders.length === 0) {
      await this.updateOnboardingActivity("No Google Drive folders found.");
      return;
    }

    // Create folder selection links
    const links: Array<ActivityLink> = await Promise.all(
      folders.map(async (folder) => ({
        type: ActivityLinkType.callback as const,
        title: folder.name,
        callback: await this.linkCallback(
          this.onFolderSelected,
          folder.id,
          folder.name
        ),
      }))
    );

    // Add folder selection to onboarding activity
    const activity = await this.getParentActivity();
    if (activity) {
      await this.tools.plot.createNote({
        activity,
        content: "Choose which Google Drive folders to sync:",
        links,
      });
    }
  }

  /**
   * Called when user selects a folder to sync.
   */
  async onFolderSelected(
    _link: ActivityLink,
    folderId: string,
    folderName: string
  ) {
    const authToken = await this.get<string>("auth_token");
    if (!authToken) {
      throw new Error("No auth token found");
    }

    // Track synced folders
    const synced = (await this.get<string[]>("synced_folders")) || [];
    if (!synced.includes(folderId)) {
      synced.push(folderId);
      await this.set("synced_folders", synced);
    }

    // Notify user
    const activity = await this.getParentActivity();
    if (activity) {
      await this.tools.plot.createNote({
        activity,
        content: `Syncing documents from "${folderName}". They will appear shortly.`,
      });
    }

    // Start sync
    await this.tools.googleDrive.startSync(
      {
        authToken,
        folderId,
      },
      this.onDocument
    );
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

    // Try the note author's credentials first, then fall back to installer auth
    const actorId = note.author.id as string;
    const installerAuthToken = await this.get<string>("auth_token");

    const authTokensToTry = [
      actorId,
      ...(installerAuthToken && installerAuthToken !== actorId
        ? [installerAuthToken]
        : []),
    ];

    for (const authToken of authTokensToTry) {
      try {
        let commentKey: string | void;
        if (commentId && tool.addDocumentReply) {
          // Reply to existing comment thread
          commentKey = await tool.addDocumentReply(
            authToken,
            activity.meta,
            commentId,
            note.content,
            note.id
          );
        } else if (tool.addDocumentComment) {
          // Top-level comment
          commentKey = await tool.addDocumentComment(
            authToken,
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
        return; // Success
      } catch (error) {
        if (
          authToken === actorId &&
          installerAuthToken &&
          installerAuthToken !== actorId
        ) {
          console.warn(
            `Actor ${actorId} has no auth, falling back to installer`
          );
          continue;
        }
        console.error("Failed to sync note to provider:", error);
      }
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

  /**
   * Called when twist is deactivated.
   * Stops all syncs and cleans up state.
   */
  async deactivate() {
    const synced = (await this.get<string[]>("synced_folders")) || [];
    const authToken = await this.get<string>("auth_token");

    if (authToken) {
      for (const folderId of synced) {
        try {
          await this.tools.googleDrive.stopSync(authToken, folderId);
        } catch (error) {
          console.warn(
            `Failed to stop sync for folder ${folderId}:`,
            error
          );
        }
      }
    }

    await this.clear("auth_token");
    await this.clear("synced_folders");
    await this.clear("onboarding_activity_id");
  }

  // --- Helpers ---

  private async getParentActivity(): Promise<Pick<Activity, "id"> | undefined> {
    const id = await this.get<Uuid>("onboarding_activity_id");
    return id ? { id } : undefined;
  }

  private async updateOnboardingActivity(message: string) {
    const activity = await this.getParentActivity();
    if (activity) {
      await this.tools.plot.createNote({
        activity,
        content: message,
      });
    }
  }
}
