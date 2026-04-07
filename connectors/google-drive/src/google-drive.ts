import GoogleContacts from "@plotday/connector-google-contacts";
import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  type Note,
  type Thread,
  Connector,
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
  getRootFolderId,
  listChanges,
  listComments,
  listFilesInFolder,
  listFolders,
  listSharedDrives,
  listSharedWithMe,
} from "./google-api";

const VIRTUAL_MY_DRIVE = "my-drive";
const VIRTUAL_SHARED_DRIVES = "shared-drives";
const VIRTUAL_SHARED_WITH_ME = "shared-with-me";

function isVirtualChannel(id: string): boolean {
  return id === VIRTUAL_MY_DRIVE || id === VIRTUAL_SHARED_DRIVES || id === VIRTUAL_SHARED_WITH_ME;
}

const MIME_TO_LINK_TYPE: Record<string, string> = {
  "application/vnd.google-apps.document": "doc",
  "application/vnd.google-apps.spreadsheet": "sheet",
  "application/vnd.google-apps.presentation": "slide",
  "application/vnd.google-apps.form": "form",
};

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
export class GoogleDrive extends Connector<GoogleDrive> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = ["https://www.googleapis.com/auth/drive"];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Google;
  readonly scopes = Integrations.MergeScopes(GoogleDrive.SCOPES, GoogleContacts.SCOPES);
  readonly linkTypes = [
    { type: "doc", label: "Document", logo: "https://api.iconify.design/simple-icons/googledocs.svg?color=%234285F4", logoMono: "https://api.iconify.design/simple-icons/googledocs.svg" },
    { type: "sheet", label: "Spreadsheet", logo: "https://api.iconify.design/simple-icons/googlesheets.svg?color=%2334A853", logoMono: "https://api.iconify.design/simple-icons/googlesheets.svg" },
    { type: "slide", label: "Presentation", logo: "https://api.iconify.design/simple-icons/googleslides.svg?color=%23FBBC04", logoMono: "https://api.iconify.design/simple-icons/googleslides.svg" },
    { type: "form", label: "Form", logo: "https://api.iconify.design/simple-icons/googleforms.svg?color=%23673AB7", logoMono: "https://api.iconify.design/simple-icons/googleforms.svg" },
    { type: "document", label: "File", logo: "https://api.iconify.design/logos/google-drive.svg", logoMono: "https://api.iconify.design/simple-icons/googledrive.svg" },
  ];

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

    // Separate owned folders (My Drive) from shared-with-me folders.
    // Drive API omits ownedByMe for shared drive files, so only === true is truly owned.
    const ownedFolders = folders.filter(f => f.ownedByMe === true);

    // Build node map for owned folders only
    type ChannelNode = { id: string; title: string; children: ChannelNode[] };
    const nodeMap = new Map<string, ChannelNode>();
    for (const f of ownedFolders) {
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

    // Build separate tree for shared-with-me folders (not owned, not in a shared drive)
    const sharedWithMeNodeMap = new Map<string, ChannelNode>();
    const sharedDriveIds = new Set(sharedDriveMap.keys());
    for (const f of folders) {
      if (f.ownedByMe !== true && !nodeMap.has(f.id)) {
        sharedWithMeNodeMap.set(f.id, { id: f.id, title: f.name, children: [] });
      }
    }

    // Also add non-owned folders that live inside shared drives to the main nodeMap
    for (const f of folders) {
      if (f.ownedByMe !== true && !nodeMap.has(f.id)) {
        const parentId = f.parents?.[0];
        if (parentId && (nodeMap.has(parentId) || sharedDriveIds.has(parentId))) {
          // This folder belongs in a shared drive, move it to the main map
          const node = sharedWithMeNodeMap.get(f.id)!;
          sharedWithMeNodeMap.delete(f.id);
          nodeMap.set(f.id, node);
        }
      }
    }

    // Link children to parents (My Drive + shared drive trees)
    const roots: ChannelNode[] = [];
    for (const f of folders) {
      const node = nodeMap.get(f.id);
      if (!node) continue;
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
      // No known parent in our set -> root folder (My Drive), only if owned
      if (f.ownedByMe === true) {
        roots.push(node);
      }
    }

    // Link children to parents (shared-with-me tree)
    const sharedWithMeRoots: ChannelNode[] = [];
    for (const f of folders) {
      const node = sharedWithMeNodeMap.get(f.id);
      if (!node) continue;
      const parentId = f.parents?.[0];
      if (parentId) {
        const parentNode = sharedWithMeNodeMap.get(parentId);
        if (parentNode) {
          parentNode.children.push(node);
          continue;
        }
      }
      sharedWithMeRoots.push(node);
    }

    // Strip empty children arrays for clean output
    const clean = (nodes: ChannelNode[]): Channel[] => {
      return nodes.map((n) => {
        if (n.children.length > 0) {
          return { id: n.id, title: n.title, children: clean(n.children) };
        }
        return { id: n.id, title: n.title };
      });
    };

    // Nest under virtual parent channels
    const result: Channel[] = [
      {
        id: VIRTUAL_MY_DRIVE,
        title: "My Drive",
        ...(roots.length > 0 ? { children: clean(roots) } : {}),
      },
    ];

    if (sharedDriveMap.size > 0) {
      result.push({
        id: VIRTUAL_SHARED_DRIVES,
        title: "Shared drives",
        children: clean([...sharedDriveMap.values()]),
      });
    }

    result.push({
      id: VIRTUAL_SHARED_WITH_ME,
      title: "Shared with me",
      ...(sharedWithMeRoots.length > 0 ? { children: clean(sharedWithMeRoots) } : {}),
    });

    return result;
  }

  /**
   * Called when a channel folder is enabled for syncing.
   */
  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);
    await this.set(`sync_lock_${channel.id}`, true);

    // Queue all initialization work as a task to avoid blocking the HTTP response.
    // initChannel makes multiple API calls (changes token, sub-channel discovery,
    // webhook setup) that would cause the client to spin if run inline.
    const initCallback = await this.callback(this.initChannel, channel.id);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a channel: sets up sync state, webhook, and starts the first sync batch.
   * Runs as a task to avoid blocking the HTTP response from onChannelEnabled.
   */
  async initChannel(channelId: string): Promise<void> {
    console.log(`[google-drive] initChannel started for ${channelId}`);
    const api = await this.getApi(channelId);
    const changesToken = await getChangesStartToken(api);

    if (isVirtualChannel(channelId) && channelId !== VIRTUAL_SHARED_WITH_ME) {
      // My Drive / Shared drives: discover sub-channels and iterate
      const subChannelIds = await this.discoverSubChannels(api, channelId);
      const initialState: SyncState = {
        folderId: channelId,
        changesToken,
        sequence: 1,
        virtualChannelId: channelId,
        subChannelIds,
        currentSubChannelIndex: 0,
      };
      await this.set(`sync_state_${channelId}`, initialState);
    } else {
      // Individual folder or Shared with me
      const initialState: SyncState = {
        folderId: channelId,
        changesToken,
        sequence: 1,
        ...(channelId === VIRTUAL_SHARED_WITH_ME ? { virtualChannelId: channelId } : {}),
      };
      await this.set(`sync_state_${channelId}`, initialState);
    }

    console.log(`[google-drive] Setting up drive watch for ${channelId}`);
    await this.setupDriveWatch(channelId);

    // Run first batch inline (we're already in a task context) to avoid an
    // extra queue cycle delay. Subsequent batches are queued as tasks.
    console.log(`[google-drive] Starting initial sync for ${channelId}`);
    await this.syncBatch(1, channelId, true);
    console.log(`[google-drive] initChannel completed for ${channelId}`);
  }

  /**
   * Called when a channel folder is disabled.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  private async getApi(folderId: string, authChannelId?: string): Promise<GoogleApi> {
    // Get token for the channel (folder) from integrations
    const token = await this.tools.integrations.get(authChannelId ?? folderId);

    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new GoogleApi(token.token);
  }

  /**
   * Discover sub-channel IDs for a virtual parent channel.
   */
  private async discoverSubChannels(api: GoogleApi, virtualChannelId: string): Promise<string[]> {
    if (virtualChannelId === VIRTUAL_SHARED_DRIVES) {
      const drives = await listSharedDrives(api);
      return drives.map(d => d.id);
    }
    // VIRTUAL_MY_DRIVE: real root folder ID (for files at the top level) + root-level owned folders.
    // We resolve "root" to the actual ID because file.parents in changes always uses the real ID.
    const [folders, sharedDrives, rootId] = await Promise.all([
      listFolders(api),
      listSharedDrives(api),
      getRootFolderId(api),
    ]);
    const sharedDriveIds = new Set(sharedDrives.map(d => d.id));
    const ownedFolders = folders.filter(f => f.ownedByMe === true);
    const folderIds = new Set(ownedFolders.map(f => f.id));
    const rootLevelFolders = ownedFolders
      .filter(f => {
        const parentId = f.parents?.[0];
        if (!parentId) return true;
        return !folderIds.has(parentId) && !sharedDriveIds.has(parentId);
      })
      .map(f => f.id);
    // Include the real root ID so files at the top level of My Drive are synced
    return [rootId, ...rootLevelFolders];
  }

  /**
   * Sync files from a newly discovered sub-channel under a virtual parent.
   */
  private async syncNewSubChannel(
    virtualChannelId: string,
    subChannelId: string,
    pageToken?: string
  ): Promise<void> {
    const api = await this.getApi(virtualChannelId, virtualChannelId);
    const result = await listFilesInFolder(api, subChannelId, pageToken);

    for (const file of result.files) {
      try {
        const thread = await this.buildThreadFromFile(
          api, file, subChannelId, false, virtualChannelId
        );
        await this.tools.integrations.saveLink(thread);
        if (file.modifiedTime) {
          await this.set(`last_modified_${file.id}`, file.modifiedTime);
        }
      } catch (error) {
        console.error(`Failed to process file ${file.id}:`, error);
      }
    }

    if (result.nextPageToken) {
      const nextCallback = await this.callback(
        this.syncNewSubChannel, virtualChannelId, subChannelId, result.nextPageToken
      );
      await this.runTask(nextCallback);
    }
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
    const authChannelId = meta.authChannelId as string | undefined;
    if (!fileId || !folderId) {
      console.warn("No fileId/folderId in thread meta, cannot add comment");
      return;
    }

    const api = await this.getApi(folderId, authChannelId);
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
    const authChannelId = meta.authChannelId as string | undefined;
    if (!fileId || !folderId) {
      console.warn("No fileId/folderId in thread meta, cannot add reply");
      return;
    }

    const api = await this.getApi(folderId, authChannelId);
    const reply = await createReply(api, fileId, commentId, body);
    return `reply-${commentId}-${reply.id}`;
  }

  /**
   * Called when a user replies to a note on a thread owned by this connector.
   * Routes the reply back to Google Docs as a comment reply.
   * Only syncs replies to existing comments (identified via reNoteKey).
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<string | void> {
    const reNoteKey = thread.meta?.reNoteKey as string | undefined;
    if (!reNoteKey) return;

    // Extract commentId from note keys: "comment-{commentId}" or "reply-{commentId}-{replyId}"
    const commentMatch = reNoteKey.match(/^(?:comment-|reply-)([^-]+)/);
    if (!commentMatch) return;

    const commentId = commentMatch[1];
    return this.addDocumentReply(
      thread.meta ?? {},
      commentId,
      note.content ?? "",
      note.id
    );
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
      const api = await this.getApi(folderId, isVirtualChannel(folderId) ? folderId : undefined);
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
      const api = await this.getApi(folderId, isVirtualChannel(folderId) ? folderId : undefined);
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
    console.log(`[google-drive] renewDriveWatch called for ${folderId}`);
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
    console.log(`[google-drive] onDriveWebhook called for ${folderId}`);
    const watchData = await this.get<any>(`drive_watch_${folderId}`);
    if (!watchData) {
      console.log(`[google-drive] No watch data for ${folderId}, skipping`);
      return;
    }

    // Watch renewal is handled proactively by scheduleWatchRenewal (set up in
    // setupDriveWatch). No reactive renewal here — Google's default watch expiry
    // is ~1 hour in dev, so a reactive "<1 hour" check loops infinitely since
    // each new watch fires an immediate sync notification.

    // Trigger incremental sync
    await this.startIncrementalSync(folderId);
  }

  private async startIncrementalSync(folderId: string): Promise<void> {
    // Check if initial sync is still in progress
    const syncInProgress = await this.get<boolean>(`sync_lock_${folderId}`);
    if (syncInProgress) {
      console.log(`[google-drive] Skipping incremental sync for ${folderId}: sync lock held`);
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

    console.log(`[google-drive] Starting incremental sync for ${folderId}`);
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

      const authChannelId = state.virtualChannelId;
      const api = await this.getApi(folderId, authChannelId);

      if (state.virtualChannelId === VIRTUAL_SHARED_WITH_ME) {
        // Shared with me: query-based sync
        const result = await listSharedWithMe(api, state.pageToken);
        for (const file of result.files) {
          try {
            const thread = await this.buildThreadFromFile(
              api, file, file.parents?.[0] ?? folderId, initialSync, state.virtualChannelId
            );
            await this.tools.integrations.saveLink(thread);
            if (file.modifiedTime) {
              await this.set(`last_modified_${file.id}`, file.modifiedTime);
            }
          } catch (error) {
            console.error(`Failed to process file ${file.id}:`, error);
          }
        }

        if (result.nextPageToken) {
          await this.set(`sync_state_${folderId}`, { ...state, pageToken: result.nextPageToken });
          const syncCallback = await this.callback(this.syncBatch, batchNumber + 1, folderId, initialSync);
          await this.runTask(syncCallback);
        } else {
          await this.set(`sync_state_${folderId}`, { ...state, pageToken: undefined });
          await this.clear(`sync_lock_${folderId}`);
        }
      } else if (state.subChannelIds) {
        // My Drive / Shared drives: iterate sub-channels
        const subIndex = state.currentSubChannelIndex ?? 0;
        if (subIndex >= state.subChannelIds.length) {
          await this.set(`sync_state_${folderId}`, {
            ...state, pageToken: undefined, currentSubChannelIndex: undefined,
          });
          await this.clear(`sync_lock_${folderId}`);
          return;
        }

        const currentSubId = state.subChannelIds[subIndex];
        const result = await listFilesInFolder(api, currentSubId, state.pageToken);

        for (const file of result.files) {
          try {
            const thread = await this.buildThreadFromFile(
              api, file, currentSubId, initialSync, state.virtualChannelId
            );
            await this.tools.integrations.saveLink(thread);
            if (file.modifiedTime) {
              await this.set(`last_modified_${file.id}`, file.modifiedTime);
            }
          } catch (error) {
            console.error(`Failed to process file ${file.id}:`, error);
          }
        }

        if (result.nextPageToken) {
          await this.set(`sync_state_${folderId}`, { ...state, pageToken: result.nextPageToken });
        } else {
          // Move to next sub-channel
          await this.set(`sync_state_${folderId}`, {
            ...state, pageToken: undefined, currentSubChannelIndex: subIndex + 1,
          });
        }

        const syncCallback = await this.callback(this.syncBatch, batchNumber + 1, folderId, initialSync);
        await this.runTask(syncCallback);
      } else {
        // Non-virtual: single folder sync
        const result = await listFilesInFolder(api, folderId, state.pageToken);

        for (const file of result.files) {
          try {
            const thread = await this.buildThreadFromFile(api, file, folderId, initialSync);
            await this.tools.integrations.saveLink(thread);
            if (file.modifiedTime) {
              await this.set(`last_modified_${file.id}`, file.modifiedTime);
            }
          } catch (error) {
            console.error(`Failed to process file ${file.id}:`, error);
          }
        }

        if (result.nextPageToken) {
          await this.set(`sync_state_${folderId}`, { ...state, pageToken: result.nextPageToken });
          const syncCallback = await this.callback(this.syncBatch, batchNumber + 1, folderId, initialSync);
          await this.runTask(syncCallback);
        } else {
          await this.set(`sync_state_${folderId}`, { ...state, pageToken: undefined });
          await this.clear(`sync_lock_${folderId}`);
        }
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
      const state = await this.get<SyncState>(`sync_state_${folderId}`);
      const authChannelId = state?.virtualChannelId;
      const api = await this.getApi(folderId, authChannelId);
      const result = await listChanges(api, changesToken);
      console.log(`[google-drive] incrementalSyncBatch for ${folderId}: ${result.changes.length} changes, hasMore=${!!result.nextPageToken}`);

      // Determine which files to accept based on channel type
      const isSharedWithMe = state?.virtualChannelId === VIRTUAL_SHARED_WITH_ME;
      const trackedFolderIds = state?.subChannelIds
        ? new Set(state.subChannelIds)
        : isSharedWithMe ? null : new Set([folderId]);

      for (const change of result.changes) {
        if (change.removed || !change.file) continue;

        // Skip folders
        if (change.file.mimeType === "application/vnd.google-apps.folder") continue;

        if (isSharedWithMe) {
          // Shared with me: accept files not owned by the user
          if (change.file.ownedByMe !== false) continue;
        } else if (trackedFolderIds) {
          // Folder-based: check if file is in a tracked folder
          if (!change.file.parents?.some(p => trackedFolderIds.has(p))) {
            console.log(`[google-drive] Skipping change ${change.fileId}: parents=${JSON.stringify(change.file.parents)}, tracked=${JSON.stringify([...trackedFolderIds])}`);
            continue;
          }
        }

        // Skip files whose modifiedTime hasn't changed since last sync.
        // Reading comments updates viewedByMeTime which shows up as a change
        // but doesn't change modifiedTime — without this check we'd loop.
        const lastModified = await this.get<string>(`last_modified_${change.fileId}`);
        if (lastModified && change.file.modifiedTime === lastModified) {
          continue;
        }

        try {
          const fileFolderId = trackedFolderIds
            ? (change.file.parents?.find(p => trackedFolderIds.has(p)) ?? folderId)
            : (change.file.parents?.[0] ?? folderId);
          const thread = await this.buildThreadFromFile(
            api, change.file, fileFolderId, false, authChannelId
          );
          await this.tools.integrations.saveLink(thread);
          if (change.file.modifiedTime) {
            await this.set(`last_modified_${change.fileId}`, change.file.modifiedTime);
          }
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
        if (state) {
          // For virtual channels with sub-channels: discover new ones
          let updatedSubChannelIds = state.subChannelIds;
          if (state.virtualChannelId && state.subChannelIds) {
            const currentSubIds = await this.discoverSubChannels(api, state.virtualChannelId);
            const existingSet = new Set(state.subChannelIds);
            const newSubIds = currentSubIds.filter(id => !existingSet.has(id));

            if (newSubIds.length > 0) {
              updatedSubChannelIds = [...state.subChannelIds, ...newSubIds];
              // Queue initial sync for new sub-channels
              for (const newId of newSubIds) {
                const newSubCallback = await this.callback(
                  this.syncNewSubChannel, state.virtualChannelId, newId
                );
                await this.runTask(newSubCallback);
              }
            }
          }

          await this.set(`sync_state_${folderId}`, {
            ...state,
            changesToken: newToken,
            ...(updatedSubChannelIds ? { subChannelIds: updatedSubChannelIds } : {}),
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
    initialSync: boolean,
    channelId?: string
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
      type: MIME_TO_LINK_TYPE[file.mimeType] ?? "document",
      title: file.name,
      author,
      sourceUrl: file.webViewLink ?? null,
      actions: actions.length > 0 ? actions : null,
      channelId: channelId ?? folderId,
      meta: {
        fileId: file.id,
        folderId,
        mimeType: file.mimeType,
        webViewLink: file.webViewLink || null,
        syncProvider: "google",
        syncableId: channelId ?? folderId,
        ...(channelId ? { authChannelId: channelId } : {}),
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
