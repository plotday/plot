import GoogleContacts from "@plotday/source-google-contacts";
import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  Source,
  type ToolBuilder,
  Tag,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

type DocumentFolder = {
  id: string;
  name: string;
  description: string | null;
  root: boolean;
};

type DocumentSyncOptions = {
  timeMin?: Date;
};

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
  listSharedDrives,
} from "./google-api";

/**
 * Google Drive integration source.
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
export class GoogleDrive extends Source<GoogleDrive> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = ["https://www.googleapis.com/auth/drive"];

  readonly provider = AuthProvider.Google;
  readonly scopes = Integrations.MergeScopes(GoogleDrive.SCOPES, GoogleContacts.SCOPES);
  readonly linkTypes = [{ type: "document", label: "Document", logo: "https://api.iconify.design/logos/google-drive.svg" }];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://www.googleapis.com/drive/*"],
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  /**
   * Returns available Google Drive folders as a channel tree.
   * Shared drives and root-level My Drive folders appear at the top level,
   * with subfolders nested under their parents.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GoogleApi(token.token);
    const [folders, sharedDrives] = await Promise.all([
      listFolders(api),
      listSharedDrives(api),
    ]);

    // Build node map for all folders
    type ChannelNode = { id: string; title: string; children: ChannelNode[] };
    const nodeMap = new Map<string, ChannelNode>();
    for (const f of folders) {
      nodeMap.set(f.id, { id: f.id, title: f.name, children: [] });
    }

    // Build shared drive node map
    const sharedDriveMap = new Map<string, ChannelNode>();
    for (const drive of sharedDrives) {
      sharedDriveMap.set(drive.id, {
        id: drive.id,
        title: drive.name,
        children: [],
      });
    }

    // Link children to parents
    const roots: ChannelNode[] = [];
    for (const f of folders) {
      const node = nodeMap.get(f.id)!;
      const parentId = f.parents?.[0];
      if (parentId) {
        const parentFolder = nodeMap.get(parentId);
        if (parentFolder) {
          parentFolder.children.push(node);
          continue;
        }
        const parentDrive = sharedDriveMap.get(parentId);
        if (parentDrive) {
          parentDrive.children.push(node);
          continue;
        }
      }
      // No known parent in our set -> root folder (My Drive)
      roots.push(node);
    }

    // Combine: shared drives first, then root My Drive folders
    const allRoots = [...sharedDriveMap.values(), ...roots];

    // Strip empty children arrays for clean output
    const clean = (nodes: ChannelNode[]): Channel[] => {
      return nodes.map((n) => {
        if (n.children.length > 0) {
          return { id: n.id, title: n.title, children: clean(n.children) };
        }
        return { id: n.id, title: n.title };
      });
    };

    return clean(allRoots);
  }

  /**
   * Called when a channel folder is enabled for syncing.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup watch and queue first batch
    await this.set(`sync_lock_${channel.id}`, true);

    const api = await this.getApi(channel.id);
    const changesToken = await getChangesStartToken(api);

    const initialState: SyncState = {
      folderId: channel.id,
      changesToken,
      sequence: 1,
    };

    await this.set(`sync_state_${channel.id}`, initialState);
    await this.setupDriveWatch(channel.id);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      channel.id,
      true // initialSync
    );
    await this.runTask(syncCallback);
  }

  /**
   * Called when a channel folder is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  private async getApi(folderId: string): Promise<GoogleApi> {
    // Get token for the channel (folder) from integrations
    const token = await this.tools.integrations.get(folderId);

    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  async getFolders(folderId: string): Promise<DocumentFolder[]> {
    const api = await this.getApi(folderId);
    const [files, drives] = await Promise.all([
      listFolders(api),
      listSharedDrives(api),
    ]);

    const driveIds = new Set(drives.map((d) => d.id));

    return files.map((file) => ({
      id: file.id,
      name: file.name,
      description: file.description || null,
      root:
        !file.parents ||
        file.parents.length === 0 ||
        file.parents.every((p) => driveIds.has(p)),
    }));
  }

  async startSync(
    options: {
      folderId: string;
    } & DocumentSyncOptions,
  ): Promise<void> {
    const { folderId } = options;

    // Check if sync is already in progress for this folder
    const syncInProgress = await this.get<boolean>(`sync_lock_${folderId}`);
    if (syncInProgress) {
      return;
    }

    // Set sync lock
    await this.set(`sync_lock_${folderId}`, true);

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
    await this.stopDriveWatch(folderId);

    // Clear sync-related storage
    await this.clear(`drive_watch_${folderId}`);
    await this.clear(`sync_state_${folderId}`);
    await this.clear(`sync_lock_${folderId}`);
  }

  async addDocumentComment(
    meta: Record<string, unknown>,
    body: string,
    _noteId?: string
  ): Promise<string | void> {
    const fileId = meta.fileId as string | undefined;
    const folderId = meta.folderId as string | undefined;
    if (!fileId || !folderId) {
      console.warn("No fileId/folderId in thread meta, cannot add comment");
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
      console.warn("No fileId/folderId in thread meta, cannot add reply");
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
        { pageToken: changesToken, supportsAllDrives: true },
        {
          id: watchId,
          type: "web_hook",
          address: webhookUrl,
        }
      )) as { expiration: string; resourceId: string };

      const expiry = new Date(parseInt(watchData.expiration));

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

    try {
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
    } catch (error) {
      console.warn(
        `Failed to stop drive watch for folder ${folderId}:`,
        error instanceof Error ? error.message : error
      );
    }
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

    // Reactive expiry check - renew if watch expires within 1 hour
    const expiry = new Date(watchData.expiry);
    const hoursUntilExpiry = (expiry.getTime() - Date.now()) / (1000 * 60 * 60);
    if (hoursUntilExpiry < 1) {
      this.renewDriveWatch(folderId).catch((error) => {
        console.error(`Failed to reactively renew watch for ${folderId}:`, error);
      });
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

      for (const file of result.files) {
        try {
          const thread = await this.buildThreadFromFile(
            api,
            file,
            folderId,
            initialSync
          );
          await this.tools.integrations.saveLink(thread);
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

      // Filter changes to files in our synced folder
      for (const change of result.changes) {
        if (change.removed || !change.file) continue;

        // Check if file is in our folder
        if (!change.file.parents?.includes(folderId)) continue;

        // Skip folders
        if (change.file.mimeType === "application/vnd.google-apps.folder")
          continue;

        try {
          const thread = await this.buildThreadFromFile(
            api,
            change.file,
            folderId,
            false // incremental sync
          );
          await this.tools.integrations.saveLink(thread);
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

  // --- Thread Building ---

  private async buildThreadFromFile(
    api: GoogleApi,
    file: GoogleDriveFile,
    folderId: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
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

    // Build displayName -> email lookup from file permissions
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
      thread: { source: canonicalSource },
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

    // Build external action
    const actions: Action[] = [];
    if (file.webViewLink) {
      actions.push({
        type: ActionType.external,
        title: "View in Drive",
        url: file.webViewLink,
      });
    }

    const thread: NewLinkWithNotes = {
      source: canonicalSource,
      type: "document",
      title: file.name,
      author,
      sourceUrl: file.webViewLink ?? null,
      actions: actions.length > 0 ? actions : null,
      channelId: folderId,
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

    return thread;
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
      thread: { source: canonicalSource },
      key: `comment-${comment.id}`,
      content: comment.content,
      contentType: comment.htmlContent ? "html" : "text",
      author: commentAuthor,
      created: new Date(comment.createdTime),
      ...(comment.assigneeEmailAddress
        ? { tags: { [Tag.Todo]: [{ email: comment.assigneeEmailAddress }] } }
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
      thread: { source: canonicalSource },
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
