import {
  type Action,
  ActionType,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  Source,
  type ToolBuilder,
} from "@plotday/twister";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import type { Note, Thread } from "@plotday/twister/plot";

import {
  NotionApi,
  type NotionComment,
  type NotionPage,
  type SyncState,
  createComment,
  getPage,
  getPageTitle,
  getUser,
  listAllComments,
  richTextToPlain,
  searchPages,
} from "./notion-api";

/**
 * Notion integration source.
 *
 * Syncs Notion pages and their comments into Plot as links with notes.
 * Top-level pages (parent.type === "workspace") appear as channels.
 * Supports bidirectional comment sync and webhook-based updates.
 */
export class Notion extends Source<Notion> {
  static readonly PROVIDER = AuthProvider.Notion;
  static readonly SCOPES: string[] = [];

  readonly provider = AuthProvider.Notion;
  readonly scopes: string[] = [];
  readonly linkTypes = [
    {
      type: "page",
      label: "Page",
      logo: "https://api.iconify.design/logos/notion-icon.svg",
      logoMono: "https://api.iconify.design/simple-icons/notion.svg",
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://api.notion.com/*"],
      }),
    };
  }

  // --- Channels ---

  /**
   * Returns available Notion pages as channels.
   * Top-level pages (workspace parents) are root channels.
   * Child pages are nested under their parent.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new NotionApi(token.token);

    // Fetch all accessible pages
    const allPages: NotionPage[] = [];
    let cursor: string | undefined;
    do {
      const result = await searchPages(api, { cursor });
      allPages.push(...result.pages);
      cursor = result.nextCursor ?? undefined;
    } while (cursor);

    // Build parent-child map
    type ChannelNode = { id: string; title: string; children: ChannelNode[] };
    const nodeMap = new Map<string, ChannelNode>();
    for (const page of allPages) {
      nodeMap.set(page.id, {
        id: page.id,
        title: getPageTitle(page),
        children: [],
      });
    }

    // Link children to parents, collect roots
    const roots: ChannelNode[] = [];
    for (const page of allPages) {
      const node = nodeMap.get(page.id)!;
      if (page.parent.type === "page_id") {
        const parent = nodeMap.get(page.parent.page_id);
        if (parent) {
          parent.children.push(node);
          continue;
        }
      }
      // Workspace parent or unknown parent → root
      if (page.parent.type === "workspace" || page.parent.type === "page_id") {
        roots.push(node);
      }
      // database_id parents are excluded from channel list
    }

    // Convert to Channel format
    const toChannels = (nodes: ChannelNode[]): Channel[] =>
      nodes.map((n) =>
        n.children.length > 0
          ? { id: n.id, title: n.title, children: toChannels(n.children) }
          : { id: n.id, title: n.title }
      );

    return toChannels(roots);
  }

  // --- Channel Lifecycle ---

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);
    await this.set(`sync_lock_${channel.id}`, true);

    const initialState: SyncState = {
      channelId: channel.id,
      batchNumber: 1,
    };
    await this.set(`sync_state_${channel.id}`, initialState);

    // Setup webhook for real-time updates
    await this.setupWebhook(channel.id);

    // Start initial sync
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      channel.id,
      true, // initialSync
      null as string | null // cursor
    );
    await this.runTask(syncCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  private async stopSync(channelId: string): Promise<void> {
    // Cancel scheduled poll task
    const pollTask = await this.get<string>(`poll_task_${channelId}`);
    if (pollTask) {
      await this.cancelTask(pollTask);
      await this.clear(`poll_task_${channelId}`);
    }

    // Clean up webhook URL
    const webhookUrl = await this.get<string>(`webhook_url_${channelId}`);
    if (webhookUrl) {
      try {
        await this.tools.network.deleteWebhook(webhookUrl);
      } catch {
        // Webhook may already be gone
      }
      await this.clear(`webhook_url_${channelId}`);
    }

    // Clean up webhook instruction activity
    await this.clear(`webhook_instruction_source_${channelId}`);
    await this.clear(`webhook_verification_token`);
    await this.clear(`webhook_active_${channelId}`);

    // Clear sync state
    await this.clear(`sync_state_${channelId}`);
    await this.clear(`sync_lock_${channelId}`);
  }

  // --- API Client ---

  private async getApi(channelId: string): Promise<NotionApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("Authorization no longer available");
    }
    return new NotionApi(token.token);
  }

  // --- Sync ---

  async syncBatch(
    batchNumber: number,
    channelId: string,
    initialSync: boolean,
    cursor: string | null
  ): Promise<void> {
    try {
      const api = await this.getApi(channelId);

      // Search for all pages
      const result = await searchPages(api, {
        cursor: cursor ?? undefined,
        sortDirection: "ascending",
      });

      // Filter to pages that are descendants of the channel page
      const descendantPages = await this.filterDescendants(
        result.pages,
        channelId
      );

      for (const page of descendantPages) {
        try {
          const link = await this.buildLinkFromPage(
            api,
            page,
            channelId,
            initialSync
          );
          await this.tools.integrations.saveLink(link);
        } catch (error) {
          console.error(`Failed to process page ${page.id}:`, error);
        }
      }

      if (result.nextCursor) {
        // More pages to process
        const nextCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          channelId,
          initialSync,
          result.nextCursor
        );
        await this.runTask(nextCallback);
      } else {
        // Sync complete — save last poll time and release lock
        await this.set(`sync_state_${channelId}`, {
          channelId,
          lastPollTime: new Date().toISOString(),
          batchNumber,
        });
        await this.clear(`sync_lock_${channelId}`);

        // Schedule polling if webhook is not active
        const webhookActive = await this.get<boolean>(
          `webhook_active_${channelId}`
        );
        if (!webhookActive) {
          await this.schedulePoll(channelId);
        }
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );
      await this.clear(`sync_lock_${channelId}`);
      throw error;
    }
  }

  /**
   * Filter pages to only those that are descendants of the channel page.
   * A page is a descendant if it has the channel page as an ancestor
   * in its parent chain, or if it IS the channel page itself.
   */
  private async filterDescendants(
    pages: NotionPage[],
    channelId: string
  ): Promise<NotionPage[]> {
    const descendants: NotionPage[] = [];
    // Build a set of known descendant IDs, starting with the channel itself
    const descendantIds = new Set<string>([channelId]);

    // Multiple passes to catch nested descendants
    // Pages may arrive in any order, so we iterate until no new descendants found
    let foundNew = true;
    while (foundNew) {
      foundNew = false;
      for (const page of pages) {
        if (descendantIds.has(page.id)) continue;
        if (
          page.parent.type === "page_id" &&
          descendantIds.has(page.parent.page_id)
        ) {
          descendantIds.add(page.id);
          foundNew = true;
        }
      }
    }

    for (const page of pages) {
      if (descendantIds.has(page.id)) {
        descendants.push(page);
      }
    }

    return descendants;
  }

  // --- Polling ---

  private async schedulePoll(channelId: string): Promise<void> {
    const pollCallback = await this.callback(this.pollForChanges, channelId);
    const pollTime = new Date(Date.now() + 5 * 60 * 1000); // 5 minutes
    const taskToken = await this.runTask(pollCallback, { runAt: pollTime });
    if (taskToken) {
      await this.set(`poll_task_${channelId}`, taskToken);
    }
  }

  async pollForChanges(channelId: string): Promise<void> {
    // Check if channel is still enabled
    const enabled = await this.get<boolean>(`sync_enabled_${channelId}`);
    if (!enabled) return;

    // Check if webhook has taken over
    const webhookActive = await this.get<boolean>(
      `webhook_active_${channelId}`
    );
    if (webhookActive) return;

    // Check sync lock
    const locked = await this.get<boolean>(`sync_lock_${channelId}`);
    if (locked) {
      // Sync in progress, reschedule poll
      await this.schedulePoll(channelId);
      return;
    }

    await this.set(`sync_lock_${channelId}`, true);

    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      const api = await this.getApi(channelId);

      // Search for recently modified pages
      const result = await searchPages(api, {
        sortDirection: "descending",
      });

      const lastPollTime = state?.lastPollTime
        ? new Date(state.lastPollTime)
        : null;

      // Filter to pages modified since last poll
      const modifiedPages = lastPollTime
        ? result.pages.filter(
            (p) => new Date(p.last_edited_time) > lastPollTime
          )
        : result.pages;

      // Filter to descendants of the channel
      const descendantPages = await this.filterDescendants(
        modifiedPages,
        channelId
      );

      for (const page of descendantPages) {
        try {
          const link = await this.buildLinkFromPage(
            api,
            page,
            channelId,
            false // incremental
          );
          await this.tools.integrations.saveLink(link);
        } catch (error) {
          console.error(`Failed to sync page ${page.id}:`, error);
        }
      }

      // Update poll time
      await this.set(`sync_state_${channelId}`, {
        channelId,
        lastPollTime: new Date().toISOString(),
        batchNumber: (state?.batchNumber ?? 0) + 1,
      });
    } catch (error) {
      console.error(`Error polling for changes on channel ${channelId}:`, error);
    } finally {
      await this.clear(`sync_lock_${channelId}`);
    }

    // Schedule next poll
    await this.schedulePoll(channelId);
  }

  // --- Webhooks ---

  private async setupWebhook(channelId: string): Promise<void> {
    const webhookUrl = await this.tools.network.createWebhook(
      {},
      this.onNotionWebhook,
      channelId
    );

    // Skip webhook setup for localhost
    if (
      webhookUrl.includes("localhost") ||
      webhookUrl.includes("127.0.0.1")
    ) {
      return;
    }

    await this.set(`webhook_url_${channelId}`, webhookUrl);

    // Create an instruction activity for manual webhook setup
    const instructionSource = `notion:webhook-instructions:${channelId}`;
    const instructionNotes: NewNote[] = [
      {
        thread: { source: instructionSource },
        key: "instructions",
        content: [
          "To enable real-time updates from Notion, set up a webhook:",
          "",
          "1. Go to https://www.notion.so/profile/integrations",
          "2. Select your integration",
          "3. Go to the Webhooks tab",
          "4. Click \"Create subscription\"",
          `5. Paste this URL: ${webhookUrl}`,
          "6. Select events: page.created, page.content_updated, page.properties_updated, page.deleted, comment.created, comment.updated, comment.deleted",
          "7. Save the subscription",
          "",
          "Once configured, Notion will send a verification request. Updates will then sync in real-time instead of every 5 minutes.",
        ].join("\n"),
        contentType: "text",
      },
    ];
    await this.tools.integrations.saveLink({
      source: instructionSource,
      type: "page",
      title: "Set up Notion webhooks",
      channelId,
      meta: {
        syncProvider: "notion",
        channelId,
      },
      notes: instructionNotes,
      unread: false,
      archived: false,
    });

    await this.set(`webhook_instruction_source_${channelId}`, instructionSource);
  }

  async onNotionWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    const body = request.body as Record<string, any>;

    // Handle verification challenge
    if (body?.verification_token) {
      await this.set(`webhook_verification_token`, body.verification_token);
      return;
    }

    // Verify webhook signature if we have a verification token
    const verificationToken = await this.get<string>(
      `webhook_verification_token`
    );
    if (verificationToken && request.rawBody) {
      const signature = request.headers["x-notion-signature"];
      if (signature) {
        const isValid = await this.verifySignature(
          request.rawBody,
          signature,
          verificationToken
        );
        if (!isValid) {
          console.warn("Invalid Notion webhook signature");
          return;
        }
      }
    }

    // Mark webhook as active (disables polling)
    const wasActive = await this.get<boolean>(`webhook_active_${channelId}`);
    if (!wasActive) {
      await this.set(`webhook_active_${channelId}`, true);
      // Cancel polling task
      const pollTask = await this.get<string>(`poll_task_${channelId}`);
      if (pollTask) {
        await this.cancelTask(pollTask);
        await this.clear(`poll_task_${channelId}`);
      }
    }

    // Process webhook events
    const eventType = body?.type as string | undefined;
    if (!eventType) return;

    try {
      const api = await this.getApi(channelId);

      if (eventType === "page.deleted") {
        // Archive the link for the deleted page
        const pageId = body?.entity?.id as string;
        if (pageId) {
          await this.tools.integrations.archiveLinks({
            meta: { syncProvider: "notion", channelId },
          });
        }
        return;
      }

      // For page/comment events, re-sync the affected page
      const pageId =
        body?.entity?.id as string ??
        body?.data?.parent?.page_id as string;
      if (!pageId) return;

      // Check if this page is a descendant of our channel
      try {
        const page = await getPage(api, pageId);
        const descendants = await this.filterDescendants([page], channelId);
        if (descendants.length === 0) return;

        const link = await this.buildLinkFromPage(
          api,
          page,
          channelId,
          false // incremental
        );
        await this.tools.integrations.saveLink(link);
      } catch (error) {
        console.error(`Failed to process webhook for page ${pageId}:`, error);
      }
    } catch (error) {
      console.error(`Error processing webhook event:`, error);
    }
  }

  private async verifySignature(
    rawBody: string,
    signature: string,
    secret: string
  ): Promise<boolean> {
    try {
      const encoder = new TextEncoder();
      const key = await crypto.subtle.importKey(
        "raw",
        encoder.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
      );
      const sig = await crypto.subtle.sign(
        "HMAC",
        key,
        encoder.encode(rawBody)
      );
      const expected = Array.from(new Uint8Array(sig))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
      return `sha256=${expected}` === signature;
    } catch {
      return false;
    }
  }

  // --- Thread Building ---

  private async buildLinkFromPage(
    api: NotionApi,
    page: NotionPage,
    channelId: string,
    initialSync: boolean
  ): Promise<NewLinkWithNotes> {
    const canonicalSource = `notion:page:${page.id}`;
    const title = getPageTitle(page);

    // Resolve author
    const author = await this.resolveUser(api, page.created_by.id);

    // Build notes from comments
    const notes: NewNote[] = [];

    try {
      const comments = await listAllComments(api, page.id);

      // Group comments by discussion_id
      const discussions = new Map<string, NotionComment[]>();
      for (const comment of comments) {
        const existing = discussions.get(comment.discussion_id) ?? [];
        existing.push(comment);
        discussions.set(comment.discussion_id, existing);
      }

      for (const [, threadComments] of discussions) {
        // Sort by created_time
        threadComments.sort(
          (a, b) =>
            new Date(a.created_time).getTime() -
            new Date(b.created_time).getTime()
        );

        const firstComment = threadComments[0];
        const firstKey = `comment-${firstComment.id}`;

        for (let i = 0; i < threadComments.length; i++) {
          const comment = threadComments[i];
          const commentAuthor = await this.resolveUser(
            api,
            comment.created_by.id
          );
          const content = richTextToPlain(comment.rich_text);
          const key = `comment-${comment.id}`;

          const note: NewNote = {
            thread: { source: canonicalSource },
            key,
            content,
            contentType: "text",
            author: commentAuthor,
            created: new Date(comment.created_time),
            // Replies reference the first comment in the discussion
            ...(i > 0 ? { reNote: { key: firstKey } } : {}),
          };

          notes.push(note);
        }
      }
    } catch (error) {
      console.error(`Failed to fetch comments for page ${page.id}:`, error);
    }

    // Build external action
    const actions: Action[] = [
      {
        type: ActionType.external,
        title: "Open in Notion",
        url: page.url,
      },
    ];

    const link: NewLinkWithNotes = {
      source: canonicalSource,
      type: "page",
      title,
      author,
      sourceUrl: page.url,
      actions,
      channelId,
      meta: {
        pageId: page.id,
        syncProvider: "notion",
        channelId,
      },
      notes,
      created: new Date(page.created_time),
      ...(initialSync ? { unread: false } : {}),
      ...(initialSync ? { archived: false } : {}),
    };

    return link;
  }

  // --- User Resolution ---

  private async resolveUser(
    api: NotionApi,
    userId: string
  ): Promise<NewContact | undefined> {
    // Check cache
    const cached = await this.get<{
      email: string;
      name: string | null;
      avatar: string | null;
    }>(`user_${userId}`);
    if (cached) {
      return cached.email
        ? {
            email: cached.email,
            name: cached.name ?? undefined,
            avatar: cached.avatar ?? undefined,
          }
        : undefined;
    }

    // Fetch user from API
    try {
      const user = await getUser(api, userId);
      const email = user.person?.email;

      await this.set(`user_${userId}`, {
        email: email ?? null,
        name: user.name,
        avatar: user.avatar_url,
      });

      if (!email) return undefined;

      return {
        email,
        name: user.name ?? undefined,
        avatar: user.avatar_url ?? undefined,
      };
    } catch {
      // Bot users or deleted users may not be fetchable
      return undefined;
    }
  }

  // --- Bidirectional Sync ---

  async addComment(
    meta: Record<string, unknown>,
    body: string
  ): Promise<string | void> {
    const pageId = meta.pageId as string | undefined;
    const channelId = meta.channelId as string | undefined;
    if (!pageId || !channelId) {
      console.warn("No pageId/channelId in thread meta, cannot add comment");
      return;
    }

    const api = await this.getApi(channelId);
    const comment = await createComment(api, pageId, body);
    return `comment-${comment.id}`;
  }

  /**
   * Called when a note is created on a thread owned by this source.
   * Syncs the comment back to Notion.
   */
  override async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<void> {
    if (!note.content) return;
    await this.addComment(thread.meta ?? {}, note.content);
  }
}

export default Notion;
