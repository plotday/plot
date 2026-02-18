import GoogleContacts from "@plotday/tool-google-contacts";
import {
  type ActivityFilter,
  ActivityKind,
  type ActivityLink,
  ActivityLinkType,
  ActivityType,
  type NewActivityWithNotes,
  type NewContact,
  type NewNote,
  Serializable,
  type SyncToolOptions,
  Tag,
  Tool,
  type ToolBuilder,
} from "@plotday/twister";
import {
  type DocumentFolder,
  type DocumentSyncOptions,
  type DocumentTool,
} from "@plotday/twister/common/documents";
import { type Callback } from "@plotday/twister/tools/callbacks";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Syncable,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ContactAccess, Plot } from "@plotday/twister/tools/plot";

import {
  GoogleApi,
  type GoogleDriveComment,
  type GoogleDriveFile,
  type SyncState,
  createComment,
  createReply,
  getChangesStartToken,
  listChanges,
  listComments,
  listFilesInFolder,
  listFolders,
} from "./google-api";

/**
 * Google Drive integration tool.
 *
 * Provides integration with Google Drive, supporting document
 * synchronization, comment syncing, and real-time updates via webhooks.
 *
 * **Features:**
 * - OAuth 2.0 authentication with Google
 * - Folder-based document synchronization
 * - Comment and reply syncing
 * - Webhook-based change notifications
 * - Batch processing for large folders
 * - Bidirectional comment sync
 *
 * **Required OAuth Scopes:**
 * - `https://www.googleapis.com/auth/drive` - Read/write files, folders, comments
 */
export class GoogleDrive extends Tool<GoogleDrive> implements DocumentTool {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly Options: SyncToolOptions;
  declare readonly Options: SyncToolOptions;
  static readonly SCOPES = ["https://www.googleapis.com/auth/drive"];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations, {
        providers: [
          {
            provider: GoogleDrive.PROVIDER,
            scopes: Integrations.MergeScopes(
              GoogleDrive.SCOPES,
              GoogleContacts.SCOPES
            ),
            getSyncables: this.getSyncables,
            onSyncEnabled: this.onSyncEnabled,
            onSyncDisabled: this.onSyncDisabled,
          },
        ],
      }),
      network: build(Network, {
        urls: ["https://www.googleapis.com/drive/*"],
      }),
      plot: build(Plot, {
        contact: {
          access: ContactAccess.Write,
        },
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  /**
   * Returns available Google Drive folders as syncable resources.
   */
  async getSyncables(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Syncable[]> {
    const api = new GoogleApi(token.token);
    const files = await listFolders(api);
    return files.map((f) => ({ id: f.id, title: f.name }));
  }

  /**
   * Called when a syncable folder is enabled for syncing.
   * Creates callback tokens from options and auto-starts sync.
   */
  async onSyncEnabled(syncable: Syncable): Promise<void> {
    await this.set(`sync_enabled_${syncable.id}`, true);

    // Create item callback token from parent's onItem handler
    const itemCallbackToken = await this.tools.callbacks.createFromParent(
      this.options.onItem
    );
    await this.set(`item_callback_${syncable.id}`, itemCallbackToken);

    // Create disable callback if parent provided onSyncableDisabled
    if (this.options.onSyncableDisabled) {
      const filter: ActivityFilter = {
        meta: { syncProvider: "google", syncableId: syncable.id },
      };
      const disableCallbackToken = await this.tools.callbacks.createFromParent(
        this.options.onSyncableDisabled,
        filter
      );
      await this.set(`disable_callback_${syncable.id}`, disableCallbackToken);
    }

    // Auto-start sync: setup watch and queue first batch
    await this.set(`sync_lock_${syncable.id}`, true);

    const api = await this.getApi(syncable.id);
    const changesToken = await getChangesStartToken(api);

    const initialState: SyncState = {
      folderId: syncable.id,
      changesToken,
      sequence: 1,
    };

    await this.set(`sync_state_${syncable.id}`, initialState);
    await this.setupDriveWatch(syncable.id);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      syncable.id,
      true // initialSync
    );
    await this.runTask(syncCallback);
  }

  /**
   * Called when a syncable folder is disabled.
   * Stops sync, runs disable callback, and cleans up stored tokens.
   */
  async onSyncDisabled(syncable: Syncable): Promise<void> {
    await this.stopSync(syncable.id);

    // Run and clean up disable callback
    const disableCallbackToken = await this.get<Callback>(
      `disable_callback_${syncable.id}`
    );
    if (disableCallbackToken) {
      await this.tools.callbacks.run(disableCallbackToken);
      await this.deleteCallback(disableCallbackToken);
      await this.clear(`disable_callback_${syncable.id}`);
    }

    // Clean up item callback
    const itemCallbackToken = await this.get<Callback>(
      `item_callback_${syncable.id}`
    );
    if (itemCallbackToken) {
      await this.deleteCallback(itemCallbackToken);
      await this.clear(`item_callback_${syncable.id}`);
    }

    await this.clear(`sync_enabled_${syncable.id}`);
  }

  private async getApi(folderId: string): Promise<GoogleApi> {
    // Get token for the syncable (folder) from integrations
    const token = await this.tools.integrations.get(
      GoogleDrive.PROVIDER,
      folderId
    );

    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  async getFolders(folderId: string): Promise<DocumentFolder[]> {
    const api = await this.getApi(folderId);
    const files = await listFolders(api);

    return files.map((file) => ({
      id: file.id,
      name: file.name,
      description: file.description || null,
      root: !file.parents || file.parents.length === 0,
    }));
  }

  async startSync<
    TArgs extends Serializable[],
    TCallback extends (activity: NewActivityWithNotes, ...args: TArgs) => any
  >(
    options: {
      folderId: string;
    } & DocumentSyncOptions,
    callback: TCallback,
    ...extraArgs: TArgs
  ): Promise<void> {
    const { folderId } = options;

    // Check if sync is already in progress for this folder
    const syncInProgress = await this.get<boolean>(`sync_lock_${folderId}`);
    if (syncInProgress) {
      return;
    }

    // Set sync lock
    await this.set(`sync_lock_${folderId}`, true);

    // Create callback token for parent
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`item_callback_${folderId}`, callbackToken);

    // Get changes start token for future incremental syncs
    const api = await this.getApi(folderId);
    const changesToken = await getChangesStartToken(api);

    const initialState: SyncState = {
      folderId,
      changesToken,
      sequence: 1,
      timeMin: options.timeMin,
    };

    await this.set(`sync_state_${folderId}`, initialState);

    // Setup webhook for change notifications
    await this.setupDriveWatch(folderId);

    // Start initial sync batch
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      folderId,
      true // initialSync
    );
    await this.runTask(syncCallback);
  }

  async stopSync(folderId: string): Promise<void> {
    // Cancel scheduled renewal task
    const renewalTask = await this.get<string>(
      `watch_renewal_task_${folderId}`
    );
    if (renewalTask) {
      await this.cancelTask(renewalTask);
      await this.clear(`watch_renewal_task_${folderId}`);
    }

    // Stop watch via Google API
    try {
      await this.stopDriveWatch(folderId);
    } catch (error) {
      console.error("Failed to stop drive watch:", error);
    }

    // Clear sync-related storage
    await this.clear(`drive_watch_${folderId}`);
    await this.clear(`sync_state_${folderId}`);
    await this.clear(`sync_lock_${folderId}`);
    await this.clear(`item_callback_${folderId}`);
  }

  async addDocumentComment(
    meta: Record<string, unknown>,
    body: string,
    _noteId?: string
  ): Promise<string | void> {
    const fileId = meta.fileId as string | undefined;
    const folderId = meta.folderId as string | undefined;
    if (!fileId || !folderId) {
      console.warn("No fileId/folderId in activity meta, cannot add comment");
      return;
    }

    const api = await this.getApi(folderId);
    const comment = await createComment(api, fileId, body);
    return `comment-${comment.id}`;
  }

  async addDocumentReply(
    meta: Record<string, unknown>,
    commentId: string,
    body: string,
    _noteId?: string
  ): Promise<string | void> {
    const fileId = meta.fileId as string | undefined;
    const folderId = meta.folderId as string | undefined;
    if (!fileId || !folderId) {
      console.warn("No fileId/folderId in activity meta, cannot add reply");
      return;
    }

    const api = await this.getApi(folderId);
    const reply = await createReply(api, fileId, commentId, body);
    return `reply-${commentId}-${reply.id}`;
  }

  // --- Webhooks ---

  private async setupDriveWatch(folderId: string): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onDriveWebhook,
      folderId
    );

    // Skip webhook setup for localhost (local development)
    if (URL.parse(webhookUrl)?.hostname === "localhost") {
      return;
    }

    try {
      const api = await this.getApi(folderId);
      const watchId = crypto.randomUUID();

      // Watch for changes using the Drive changes API
      const changesToken = await getChangesStartToken(api);
      const watchData = (await api.call(
        "POST",
        "https://www.googleapis.com/drive/v3/changes/watch",
        { pageToken: changesToken },
        {
          id: watchId,
          type: "web_hook",
          address: webhookUrl,
        }
      )) as { expiration: string; resourceId: string };

      const expiry = new Date(parseInt(watchData.expiration));
      const hoursUntilExpiry =
        (expiry.getTime() - Date.now()) / (1000 * 60 * 60);

      await this.set(`drive_watch_${folderId}`, {
        watchId,
        resourceId: watchData.resourceId,
        folderId,
        changesToken,
        expiry,
      });

      // Schedule proactive renewal
      await this.scheduleWatchRenewal(folderId);
    } catch (error) {
      console.error(
        `Failed to setup drive watch for folder ${folderId}:`,
        error
      );
      throw error;
    }
  }

  private async stopDriveWatch(folderId: string): Promise<void> {
    const watchData = await this.get<any>(`drive_watch_${folderId}`);
    if (!watchData) {
      return;
    }

    const api = await this.getApi(folderId);
    await api.call(
      "POST",
      "https://www.googleapis.com/drive/v3/channels/stop",
      undefined,
      {
        id: watchData.watchId,
        resourceId: watchData.resourceId,
      }
    );
  }

  private async scheduleWatchRenewal(folderId: string): Promise<void> {
    const watchData = await this.get<any>(`drive_watch_${folderId}`);
    if (!watchData?.expiry) {
      return;
    }

    const expiry = new Date(watchData.expiry);
    const timeUntilExpiry = expiry.getTime() - Date.now();

    // Renew at 80% of the watch lifetime, with a minimum of 5 minutes before expiry
    const buffer = Math.max(timeUntilExpiry * 0.2, 5 * 60 * 1000);
    const renewalTime = new Date(expiry.getTime() - buffer);

    // Don't schedule if the watch has already expired
    if (renewalTime <= new Date()) {
      return;
    }

    // Always schedule as a task to avoid recursive loops
    const renewalCallback = await this.callback(this.renewDriveWatch, folderId);

    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });

    if (taskToken) {
      await this.set(`watch_renewal_task_${folderId}`, taskToken);
    }
  }

  private async renewDriveWatch(folderId: string): Promise<void> {
    try {
      try {
        await this.stopDriveWatch(folderId);
      } catch {
        // Expected if old watch already expired
      }

      await this.setupDriveWatch(folderId);
    } catch (error) {
      console.error(`Failed to renew watch for folder ${folderId}:`, error);
    }
  }

  async onDriveWebhook(
    _request: WebhookRequest,
    folderId: string
  ): Promise<void> {
    const watchData = await this.get<any>(`drive_watch_${folderId}`);
    if (!watchData) {
      return;
    }

    // Trigger incremental sync
    await this.startIncrementalSync(folderId);
  }

  private async startIncrementalSync(folderId: string): Promise<void> {
    // Check if initial sync is still in progress
    const syncInProgress = await this.get<boolean>(`sync_lock_${folderId}`);
    if (syncInProgress) {
      return;
    }

    // Set sync lock for incremental
    await this.set(`sync_lock_${folderId}`, true);

    const state = await this.get<SyncState>(`sync_state_${folderId}`);
    if (!state?.changesToken) {
      console.error("No changes token found for incremental sync");
      await this.clear(`sync_lock_${folderId}`);
      return;
    }

    const syncCallback = await this.callback(
      this.incrementalSyncBatch,
      folderId,
      state.changesToken
    );
    await this.runTask(syncCallback);
  }

  // --- Sync ---

  async syncBatch(
    batchNumber: number,
    folderId: string,
    initialSync: boolean
  ): Promise<void> {
    try {
      const state = await this.get<SyncState>(`sync_state_${folderId}`);
      if (!state) {
        const syncLock = await this.get<boolean>(`sync_lock_${folderId}`);
        if (syncLock) {
          console.warn(`No sync state found for folder ${folderId}`);
          await this.clear(`sync_lock_${folderId}`);
        }
        return;
      }

      const api = await this.getApi(folderId);
      const result = await listFilesInFolder(api, folderId, state.pageToken);

      // Process files in this batch
      const callbackToken = await this.get<Callback>(
        `item_callback_${folderId}`
      );
      if (!callbackToken) {
        console.warn("No callback token found, skipping file processing");
        return;
      }

      for (const file of result.files) {
        try {
          const activity = await this.buildActivityFromFile(
            api,
            file,
            folderId,
            initialSync
          );
          await this.tools.callbacks.run(callbackToken, activity);
        } catch (error) {
          console.error(`Failed to process file ${file.id}:`, error);
        }
      }

      if (result.nextPageToken) {
        // More pages to process
        await this.set(`sync_state_${folderId}`, {
          ...state,
          pageToken: result.nextPageToken,
        });

        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          folderId,
          initialSync
        );
        await this.runTask(syncCallback);
      } else {
        // Sync complete
        await this.set(`sync_state_${folderId}`, {
          ...state,
          pageToken: undefined,
        });
        await this.clear(`sync_lock_${folderId}`);
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for folder ${folderId}:`,
        error
      );
      throw error;
    }
  }

  async incrementalSyncBatch(
    folderId: string,
    changesToken: string
  ): Promise<void> {
    try {
      const api = await this.getApi(folderId);
      const result = await listChanges(api, changesToken);

      const callbackToken = await this.get<Callback>(
        `item_callback_${folderId}`
      );
      if (!callbackToken) {
        console.warn("No callback token found, skipping incremental sync");
        await this.clear(`sync_lock_${folderId}`);
        return;
      }

      // Filter changes to files in our synced folder
      let processedCount = 0;
      for (const change of result.changes) {
        if (change.removed || !change.file) continue;

        // Check if file is in our folder
        if (!change.file.parents?.includes(folderId)) continue;

        // Skip folders
        if (change.file.mimeType === "application/vnd.google-apps.folder")
          continue;

        processedCount++;

        try {
          const activity = await this.buildActivityFromFile(
            api,
            change.file,
            folderId,
            false // incremental sync
          );
          await this.tools.callbacks.run(callbackToken, activity);
        } catch (error) {
          console.error(
            `Failed to process changed file ${change.fileId}:`,
            error
          );
        }
      }

      if (result.nextPageToken) {
        // More change pages
        const syncCallback = await this.callback(
          this.incrementalSyncBatch,
          folderId,
          result.nextPageToken
        );
        await this.runTask(syncCallback);
      } else {
        // Update stored changes token for next incremental sync
        const newToken = result.newStartPageToken || changesToken;
        const state = await this.get<SyncState>(`sync_state_${folderId}`);
        if (state) {
          await this.set(`sync_state_${folderId}`, {
            ...state,
            changesToken: newToken,
          });
        }
        await this.clear(`sync_lock_${folderId}`);
      }
    } catch (error) {
      console.error(`Error in incremental sync for folder ${folderId}:`, error);
      await this.clear(`sync_lock_${folderId}`);
      throw error;
    }
  }

  // --- Activity Building ---

  private async buildActivityFromFile(
    api: GoogleApi,
    file: GoogleDriveFile,
    folderId: string,
    initialSync: boolean
  ): Promise<NewActivityWithNotes> {
    const canonicalSource = `google-drive:file:${file.id}`;

    // Build author contact from file owner
    let author: NewContact | undefined;
    if (file.owners?.[0]) {
      const owner = file.owners[0];
      if (owner.emailAddress) {
        author = {
          email: owner.emailAddress,
          name: owner.displayName,
        };
      }
    }

    // Build displayName → email lookup from file permissions
    // (Drive API doesn't return emailAddress on comment authors)
    const emailByName = new Map<string, string>();
    if (file.permissions) {
      for (const perm of file.permissions) {
        if (perm.displayName && perm.emailAddress) {
          emailByName.set(perm.displayName, perm.emailAddress);
        }
      }
    }

    // Build notes
    const notes: NewNote[] = [];

    // Summary note with description if available
    notes.push({
      activity: { source: canonicalSource },
      key: "summary",
      content: file.description || null,
      contentType: "text",
      author,
      created: file.createdTime ? new Date(file.createdTime) : new Date(),
    });

    // Fetch and add comments
    try {
      const comments = await listComments(api, file.id);
      for (const comment of comments) {
        notes.push(
          this.buildCommentNote(canonicalSource, comment, emailByName)
        );

        // Add replies
        if (comment.replies) {
          for (const reply of comment.replies) {
            notes.push(
              this.buildReplyNote(
                canonicalSource,
                comment.id,
                reply,
                emailByName
              )
            );
          }
        }
      }
    } catch (error) {
      console.error(`Failed to fetch comments for file ${file.id}:`, error);
    }

    // Build external link
    const links: ActivityLink[] = [];
    if (file.webViewLink) {
      links.push({
        type: ActivityLinkType.external,
        title: "View in Drive",
        url: file.webViewLink,
      });
    }

    // Add links to the summary note if present
    if (links.length > 0 && notes.length > 0) {
      notes[0].links = links;
    }

    const activity: NewActivityWithNotes = {
      source: canonicalSource,
      type: ActivityType.Note,
      kind: ActivityKind.document,
      title: file.name,
      author,
      meta: {
        fileId: file.id,
        folderId,
        mimeType: file.mimeType,
        webViewLink: file.webViewLink || null,
        syncProvider: "google",
        syncableId: folderId,
      },
      notes,
      preview: file.description || null,
      created: file.createdTime ? new Date(file.createdTime) : undefined,
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };

    return activity;
  }

  private buildCommentNote(
    canonicalSource: string,
    comment: GoogleDriveComment,
    emailByName: Map<string, string>
  ): NewNote {
    const email =
      comment.author.emailAddress ||
      (comment.author.displayName
        ? emailByName.get(comment.author.displayName)
        : undefined);
    const commentAuthor: NewContact | undefined = email
      ? {
          email,
          name: comment.author.displayName,
        }
      : undefined;

    return {
      activity: { source: canonicalSource },
      key: `comment-${comment.id}`,
      content: comment.content,
      contentType: comment.htmlContent ? "html" : "text",
      author: commentAuthor,
      created: new Date(comment.createdTime),
      ...(comment.assigneeEmailAddress
        ? { tags: { [Tag.Now]: [{ email: comment.assigneeEmailAddress }] } }
        : {}),
    };
  }

  private buildReplyNote(
    canonicalSource: string,
    commentId: string,
    reply: GoogleDriveComment["replies"] extends (infer R)[] | undefined
      ? R
      : never,
    emailByName: Map<string, string>
  ): NewNote {
    const email =
      reply.author.emailAddress ||
      (reply.author.displayName
        ? emailByName.get(reply.author.displayName)
        : undefined);
    const replyAuthor: NewContact | undefined = email
      ? {
          email,
          name: reply.author.displayName,
        }
      : undefined;

    return {
      activity: { source: canonicalSource },
      key: `reply-${commentId}-${reply.id}`,
      reNote: { key: `comment-${commentId}` },
      content: reply.content,
      contentType: reply.htmlContent ? "html" : "text",
      author: replyAuthor,
      created: new Date(reply.createdTime),
    };
  }
}

export default GoogleDrive;
