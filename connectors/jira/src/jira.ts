import { Version3Client } from "jira.js";

import {
  type Action,
  ActionType,
  type Link,
  type Note,
  type Thread,
  type NewLinkWithNotes,
  NewContact,
} from "@plotday/twister";
import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
} from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type StatusIcon,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";
import { Files } from "@plotday/twister/tools/files";

import { textToADF, adfToText } from "./jira-adf";

/**
 * Map a Jira status category key to a curated Plot status icon.
 *
 * Jira status categories are a fixed, workflow-independent classification:
 *   - `new`           → not started   → "todo"
 *   - `indeterminate` → in progress   → "inProgress"
 *   - `done`          → complete       → "done"
 * Anything unexpected falls back to "todo".
 */
export function statusCategoryToIcon(
  key: string | null | undefined
): StatusIcon {
  switch (key) {
    case "new":
      return "todo";
    case "indeterminate":
      return "inProgress";
    case "done":
      return "done";
    default:
      return "todo";
  }
}

type Project = {
  id: string;
  name: string;
  description: string | null;
  key: string | null;
};

type ProjectSyncOptions = {
  timeMin?: Date;
};

type SyncState = {
  startAt: number;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
};

/**
 * Jira project management source
 *
 * Implements the ProjectSource interface for syncing Jira projects and issues
 * with Plot threads.
 */
export class Jira extends Connector<Jira> {
  static readonly PROVIDER = AuthProvider.Atlassian;
  static readonly SCOPES = ["read:jira-work", "write:jira-work", "read:jira-user", "manage:jira-webhook"];
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Atlassian;
  readonly channelNoun = { singular: "project", plural: "projects" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = Jira.SCOPES;
  readonly access = [
    "Reads your issues, projects, and users",
    "Creates and updates issues and posts comments you make in Plot",
    "Keeps Plot up to date as issues change in Jira",
  ];
  readonly linkTypes = [
    {
      type: "issue",
      label: "Issue",
      noteLabel: "Comment",
      sharingModel: "channel" as const,
      logo: "https://api.iconify.design/logos/jira.svg",
      logoMono: "https://api.iconify.design/simple-icons/jira.svg",
      statuses: [
        { status: "open", label: "Open", icon: "todo" as StatusIcon },
        { status: "done", label: "Done", done: true, icon: "done" as StatusIcon },
      ],
      supportsAssignee: true,
      supportsFileAttachments: true,
      // `compose.status` is symbolic ("new"): onCreateLink resolves the
      // project's default workflow status itself. Per-channel linkTypes from
      // getChannels() override this with the project's real first "new"
      // status id.
      compose: { status: "new" },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      // api.atlassian.com is the OAuth-scoped Jira Cloud host this connector
      // talks to (jira.js Version3Client `host`); *.atlassian.net covers
      // attachment `content` URLs.
      network: build(Network, {
        urls: ["https://*.atlassian.net/*", "https://api.atlassian.com/*"],
      }),
      tasks: build(Tasks),
      files: build(Files),
    };
  }

  /**
   * Create Jira API client using channel-based auth
   */
  private async getClient(projectId: string): Promise<Version3Client> {
    const token = await this.tools.integrations.get(projectId);
    if (!token) {
      throw new Error("No Jira authentication token available");
    }
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) {
      throw new Error("Jira cloud ID not found in authorization");
    }
    return new Version3Client({
      host: `https://api.atlassian.com/ex/jira/${cloudId}`,
      authentication: {
        oauth2: {
          accessToken: token.token,
        },
      },
    });
  }

  /**
   * Returns available Jira projects as channel resources.
   */
  async getChannels(_auth: Authorization, token: AuthToken): Promise<Channel[]> {
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) {
      throw new Error("No Jira cloud ID in authorization");
    }
    const client = new Version3Client({
      host: `https://api.atlassian.com/ex/jira/${cloudId}`,
      authentication: { oauth2: { accessToken: token.token } },
    });
    const projects = await client.projects.searchProjects({ maxResults: 100 });

    return Promise.all(
      (projects.values || []).map(async (p) => {
        const { statuses, composeStatus } = await this.buildProjectStatuses(
          client,
          p.id
        );
        return {
          id: p.id,
          title: p.name,
          linkTypes: [
            {
              type: "issue",
              label: "Issue",
              noteLabel: "Comment",
              // Channel-level configs fully shadow the twist-level linkTypes,
              // so sharingModel + logos must be repeated here (matches Linear).
              sharingModel: "channel" as const,
              logo: "https://api.iconify.design/logos/jira.svg",
              logoMono: "https://api.iconify.design/simple-icons/jira.svg",
              statuses,
              supportsAssignee: true,
              supportsFileAttachments: true,
              compose: { status: composeStatus },
            },
          ],
        };
      })
    );
  }

  /**
   * Build the per-project workflow status list for the dynamic channel
   * linkType. Flattens `getAllStatuses` (statuses grouped by issue type) into
   * a deduped list keyed by status id, mapping each status category to a Plot
   * icon. Returns the id of the first "new"-category status for `compose`
   * (falls back to "new" symbolic id, resolved in onCreateLink).
   */
  private async buildProjectStatuses(
    client: Version3Client,
    projectId: string
  ): Promise<{
    statuses: Array<{
      status: string;
      label: string;
      icon: StatusIcon;
      done?: boolean;
    }>;
    composeStatus: string;
  }> {
    try {
      const issueTypeStatuses = await client.projects.getAllStatuses({
        projectIdOrKey: projectId,
      });

      const byId = new Map<
        string,
        { status: string; label: string; icon: StatusIcon; done?: boolean }
      >();
      let firstNewStatusId: string | undefined;

      for (const issueType of issueTypeStatuses || []) {
        for (const status of issueType.statuses || []) {
          if (!status.id || byId.has(status.id)) continue;
          const categoryKey = status.statusCategory?.key;
          byId.set(status.id, {
            status: status.id,
            label: status.name ?? status.id,
            icon: statusCategoryToIcon(categoryKey),
            ...(categoryKey === "done" ? { done: true } : {}),
          });
          if (categoryKey === "new" && !firstNewStatusId) {
            firstNewStatusId = status.id;
          }
        }
      }

      const statuses = [...byId.values()];
      if (statuses.length === 0) {
        // No statuses discoverable — fall back to the static open/done pair.
        return {
          statuses: [
            { status: "open", label: "Open", icon: "todo" },
            { status: "done", label: "Done", done: true, icon: "done" },
          ],
          composeStatus: "new",
        };
      }
      return {
        statuses,
        composeStatus: firstNewStatusId ?? statuses[0].status,
      };
    } catch (error) {
      console.error(
        `Failed to load Jira statuses for project ${projectId}:`,
        error
      );
      return {
        statuses: [
          { status: "open", label: "Open", icon: "todo" },
          { status: "done", label: "Done", done: true, icon: "done" },
        ],
        composeStatus: "new",
      };
    }
  }

  /**
   * Called when a channel is enabled for syncing.
   * Sets up webhook and auto-starts sync.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin && !context?.recovering) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    // Queue webhook setup as a separate task to avoid blocking the HTTP response
    const webhookCallback = await this.callback(
      this.setupJiraWebhook,
      channel.id
    );
    await this.runTask(webhookCallback);

    await this.startBatchSync(channel.id, syncHistoryMin ? { timeMin: syncHistoryMin } : undefined);
  }

  /**
   * Called when a channel is disabled.
   * Stops sync and archives all threads from this channel.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
  }

  /**
   * Get list of Jira projects
   */
  async getProjects(projectId: string): Promise<Project[]> {
    const client = await this.getClient(projectId);

    // Get all projects the user has access to
    const projects = await client.projects.searchProjects({
      maxResults: 100,
    });

    return (projects.values || []).map((project) => ({
      id: project.id,
      name: project.name,
      description: project.description || null,
      key: project.key,
    }));
  }

  /**
   * Start syncing issues from a Jira project
   */
  async startSync(
    options: {
      projectId: string;
    } & ProjectSyncOptions
  ): Promise<void> {
    const { projectId, timeMin } = options;

    // Setup webhook for real-time updates
    await this.setupJiraWebhook(projectId);

    // Start initial batch sync
    await this.startBatchSync(projectId, { timeMin });
  }

  /**
   * Setup Jira webhook for real-time updates.
   * Registers a dynamic webhook via the Jira REST API (expires after 30 days, auto-renewed).
   *
   * Signature verification: Jira dynamic webhooks are NOT HMAC-signed (Atlassian
   * only signs Connect-app webhooks, not REST-registered dynamic webhooks). To
   * harden inbound requests we rely on two layers:
   *   1. The platform-generated webhook URL already carries an unguessable token
   *      in its path (createWebhook), so the endpoint itself is a capability.
   *   2. We additionally generate a random per-project secret, store it under
   *      `webhook_secret_<projectId>`, and append it as a `?secret=` query param
   *      on the URL we register with Jira. onWebhook rejects any inbound request
   *      whose `secret` query param doesn't match (constant-time compare).
   */
  async setupJiraWebhook(
    projectId: string
  ): Promise<void> {
    try {
      const webhookUrl = await this.tools.network.createWebhook(
        {},
        this.onWebhook,
        projectId
      );

      // Skip webhook registration in development
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        return;
      }

      await this.set(`webhook_url_${projectId}`, webhookUrl);

      // Skip if already registered (both onChannelEnabled and startSync call this)
      const existingId = await this.get<number>(`webhook_id_${projectId}`);
      if (existingId) {
        return;
      }

      // Generate (or reuse) a random per-project secret and embed it in the
      // registered URL so we can reject forged inbound requests.
      let secret = await this.get<string>(`webhook_secret_${projectId}`);
      if (!secret) {
        secret = crypto.randomUUID();
        await this.set(`webhook_secret_${projectId}`, secret);
      }
      const registeredUrl = `${webhookUrl}${webhookUrl.includes("?") ? "&" : "?"}secret=${encodeURIComponent(secret)}`;

      const client = await this.getClient(projectId);

      const result = await client.webhooks.registerDynamicWebhooks({
        url: registeredUrl,
        webhooks: [
          {
            jqlFilter: `project = ${projectId}`,
            events: [
              "jira:issue_created",
              "jira:issue_updated",
              "jira:issue_deleted",
              "comment_created",
              "comment_updated",
              "comment_deleted",
            ],
          },
        ],
      });

      const registration = result.webhookRegistrationResult?.[0];
      if (registration?.createdWebhookId) {
        await this.set(
          `webhook_id_${projectId}`,
          registration.createdWebhookId
        );
        await this.scheduleWebhookRenewal(projectId);
      } else if (registration?.errors?.length) {
        console.error(
          "Jira webhook registration errors:",
          registration.errors
        );
      }
    } catch (error) {
      console.error(
        "Failed to register Jira webhook - real-time updates will not work:",
        error
      );
    }
  }

  /**
   * Schedule proactive renewal of a Jira webhook 24 hours before its 30-day expiry.
   */
  private async scheduleWebhookRenewal(projectId: string): Promise<void> {
    // Jira dynamic webhooks expire after 30 days; renew 24h before
    const renewalTime = new Date(
      Date.now() + 29 * 24 * 60 * 60 * 1000
    );

    const renewalCallback = await this.callback(
      this.renewJiraWebhook,
      projectId
    );

    // Singleton scheduled task: re-scheduling under this key atomically
    // replaces any pending renewal, so renewal chains can never accumulate —
    // even if setupJiraWebhook runs again (onChannelEnabled re-dispatch, re-init).
    await this.scheduleTask(`webhook-renewal:${projectId}`, renewalCallback, {
      runAt: renewalTime,
    });
  }

  /**
   * Renew a Jira webhook by refreshing its expiry, or re-registering if refresh fails.
   */
  private async renewJiraWebhook(projectId: string): Promise<void> {
    try {
      const webhookId = await this.get<number>(`webhook_id_${projectId}`);
      if (!webhookId) {
        // No webhook to renew — re-register from scratch
        await this.setupJiraWebhook(projectId);
        return;
      }

      const client = await this.getClient(projectId);

      try {
        await client.webhooks.refreshWebhooks({
          webhookIds: [webhookId],
        });
      } catch (refreshError) {
        console.warn(
          `Failed to refresh Jira webhook ${webhookId}, re-registering:`,
          refreshError
        );
        // Delete old webhook (best effort)
        try {
          await client.webhooks.deleteWebhookById({
            webhookIds: [webhookId],
          });
        } catch {
          // ignore deletion errors
        }
        await this.clear(`webhook_id_${projectId}`);

        // Re-register from scratch
        await this.setupJiraWebhook(projectId);
        return;
      }

      // Refresh succeeded — schedule next renewal
      await this.scheduleWebhookRenewal(projectId);
    } catch (error) {
      console.error(
        `Failed to renew Jira webhook for project ${projectId}:`,
        error
      );
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    // Initialize sync state with options stored in state
    await this.set(`sync_state_${projectId}`, {
      startAt: 0,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
      timeMin: options?.timeMin?.toISOString() ?? null,
    });

    // Queue first batch
    const batchCallback = await this.callback(
      this.syncBatch,
      projectId,
      options
    );

    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    const client = await this.getClient(projectId);

    // Build JQL query
    let jql = `project = ${projectId}`;
    if (options?.timeMin) {
      const timeMinStr = options.timeMin.toISOString().split("T")[0];
      jql += ` AND created >= "${timeMinStr}"`;
    }
    jql += ` ORDER BY created ASC`;

    // Fetch batch of issues (50 at a time)
    const batchSize = 50;
    const searchResult = await client.issueSearch.searchForIssuesUsingJql({
      jql,
      startAt: state.startAt,
      maxResults: batchSize,
      fields: [
        "summary",
        "description",
        "status",
        "assignee",
        "reporter",
        "creator",
        "comment",
        "attachment",
        "created",
        "updated",
      ],
    });

    // Process each issue
    for (const issue of searchResult.issues || []) {
      const linkWithNotes = await this.convertIssueToLink(
        issue,
        projectId
      );
      // Set unread based on sync type (false for initial sync to avoid notification overload)
      linkWithNotes.unread = !state.initialSync;
      // Inject sync metadata for filtering on disable
      linkWithNotes.channelId = projectId;
      linkWithNotes.meta = { ...linkWithNotes.meta, syncProvider: "atlassian", syncableId: projectId };
      await this.tools.integrations.saveLink(linkWithNotes);
    }

    // Check if more pages
    const totalIssues = searchResult.total || 0;
    const nextStartAt = state.startAt + batchSize;

    if (nextStartAt < totalIssues) {
      await this.set(`sync_state_${projectId}`, {
        startAt: nextStartAt,
        batchNumber: state.batchNumber + 1,
        issuesProcessed:
          state.issuesProcessed + (searchResult.issues?.length || 0),
        initialSync: state.initialSync,
      });

      // Queue next batch
      const nextBatch = await this.callback(
        this.syncBatch,
        projectId,
        options
      );
      await this.tools.tasks.runTask(nextBatch);
    } else {
      // Initial sync is complete - cleanup sync state
      await this.clear(`sync_state_${projectId}`);
    }
  }

  /**
   * Get the cloud ID using channel-based auth
   */
  private async getCloudId(projectId: string): Promise<string> {
    const token = await this.tools.integrations.get(projectId);
    if (!token) throw new Error("No Jira token available");
    const cloudId = token.provider?.cloud_id;
    if (!cloudId) throw new Error("Jira cloud ID not found");
    return cloudId;
  }

  /**
   * Convert a Jira issue to a Plot Link
   */
  private async convertIssueToLink(
    issue: any,
    projectId: string
  ): Promise<NewLinkWithNotes> {
    const fields = issue.fields || {};
    const comments = fields.comment?.comments || [];
    const reporter = fields.reporter || fields.creator;
    const assignee = fields.assignee;

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (reporter) {
      authorContact = {
        ...(reporter.emailAddress ? { email: reporter.emailAddress } : {}),
        name: reporter.displayName,
        avatar: reporter.avatarUrls?.["48x48"],
        ...atlassianSource(reporter.accountId),
      };
    }
    if (assignee) {
      assigneeContact = {
        ...(assignee.emailAddress ? { email: assignee.emailAddress } : {}),
        name: assignee.displayName,
        avatar: assignee.avatarUrls?.["48x48"],
        ...atlassianSource(assignee.accountId),
      };
    }

    // Get cloud ID for constructing stable source identifier and issue URL
    let cloudId: string | undefined;
    let issueUrl: string | undefined;
    try {
      cloudId = await this.getCloudId(projectId);
      issueUrl = `https://api.atlassian.com/ex/jira/${cloudId}/browse/${issue.key}`;
    } catch (error) {
      console.error("Failed to get cloud ID for issue URL:", error);
    }

    // Build notes array: always create initial note with description and link
    const notes: any[] = [];

    // Extract description (if any). Jira stores rich text as ADF; convert to
    // plain text with the shared symmetric transform so the baseline matches
    // the write-back path (`adfToText(textToADF(body))`).
    let description: string | null = null;
    if (fields.description) {
      const extracted =
        typeof fields.description === "string"
          ? fields.description
          : adfToText(fields.description);
      if (extracted && extracted.trim().length > 0) {
        description = extracted;
      }
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

    // Build thread-level actions
    const threadActions: Action[] = [];
    if (issueUrl) {
      threadActions.push({
        type: ActionType.external,
        title: `Open in Jira`,
        url: issueUrl,
      });
    }

    // Inbound attachments → fileRef actions. Cache attachment id → projectId
    // so downloadAttachment can resolve the right client later.
    for (const att of fields.attachment || []) {
      if (!att?.id) continue;
      // Intentionally retained for the connector instance's lifetime: this
      // cache is not cleared on disable (the store has no prefix-clear). Low,
      // bounded cardinality and self-correcting on re-sync, so leaving stale
      // entries is acceptable.
      await this.set(`jira:att-project:${att.id}`, projectId);
      threadActions.push({
        type: ActionType.fileRef,
        ref: String(att.id),
        fileName: att.filename ?? "attachment",
        fileSize: typeof att.size === "number" ? att.size : null,
        mimeType: att.mimeType ?? "application/octet-stream",
      });
    }

    // Create initial note with description (actions moved to thread level)
    notes.push({
      key: "description",
      content: description,
      created: fields.created ? new Date(fields.created) : undefined,
      author: authorContact,
    });

    // Add comments as additional notes (with unique IDs, not upserted)
    for (const comment of comments) {
      // Extract comment author
      let commentAuthor: NewContact | undefined;
      const author = comment.author;
      if (author) {
        commentAuthor = {
          ...(author.emailAddress ? { email: author.emailAddress } : {}),
          name: author.displayName,
          avatar: author.avatarUrl,
          ...atlassianSource(author.accountId),
        };
      }

      const commentText =
        typeof comment.body === "string"
          ? comment.body
          : adfToText(comment.body);
      notes.push({
        key: `comment-${comment.id}`,
        content: commentText,
        created: comment.created ? new Date(comment.created) : undefined,
        author: commentAuthor,
      });
    }

    return {
      ...(source ? { source } : {}),
      type: "issue",
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null, // Explicitly set to null for unassigned issues
      // Use the issue's real workflow status id — matches the per-project
      // statuses emitted from getChannels(). Falls back to open/done only when
      // status is absent.
      status:
        fields.status?.id ?? (fields.resolutiondate ? "done" : "open"),
      actions: threadActions.length > 0 ? threadActions : undefined,
      sourceUrl: issueUrl ?? null,
      notes,
      preview: description || null,
    };
  }

  /**
   * Update issue with new values from the app: title, description-less field
   * edits, assignee (resolved email → accountId), and status (via the
   * transition whose target status id matches `link.status`).
   */
  async updateIssue(link: Link): Promise<void> {
    const issueKey = link.meta?.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in link meta");
    }
    const projectId = link.meta?.projectId as string;

    const client = await this.getClient(projectId);

    // Handle field updates (title, assignee).
    const updateFields: Record<string, unknown> = {};

    if (link.title) {
      updateFields.summary = link.title;
    }

    // Assignee: resolve the Plot actor's email to a Jira accountId. `null`
    // unassigns. Skip the field entirely if we can't resolve (don't clobber).
    if (!link.assignee) {
      updateFields.assignee = null;
    } else {
      const accountId = await this.resolveAccountId(client, link.assignee.email);
      if (accountId) {
        updateFields.assignee = { id: accountId };
      } else {
        console.warn(
          `No Jira user found for assignee email ${link.assignee.email ?? "(none)"}, skipping assignee update`
        );
      }
    }

    if (Object.keys(updateFields).length > 0) {
      await client.issues.editIssue({
        issueIdOrKey: issueKey,
        fields: updateFields,
      });
    }

    // Status: find the transition whose target status id matches link.status
    // (status ids come from the expanded per-project model). Fall back to a
    // transition whose target status category matches, in case the link still
    // carries a category-shaped status ("done"/"open"/etc.) from the static
    // linkType fallback.
    if (link.status) {
      const transitions = await client.issues.getTransitions({
        issueIdOrKey: issueKey,
      });
      const list = transitions.transitions ?? [];

      let target = list.find((tr) => tr.to?.id === link.status);
      if (!target) {
        const wantCategory =
          link.status === "done"
            ? "done"
            : link.status === "open"
              ? "new"
              : link.status;
        target = list.find(
          (tr) => tr.to?.statusCategory?.key === wantCategory
        );
      }

      if (target?.id) {
        await client.issues.doTransition({
          issueIdOrKey: issueKey,
          transition: { id: target.id },
        });
      }
    }
  }

  /**
   * Called when a link's status / assignee / title is changed from the Plot
   * app. Delegates to updateIssue. Best-effort: a failed external write is
   * reconciled on the next sync-in (external is the source of truth).
   */
  async onLinkUpdated(link: Link): Promise<void> {
    const issueKey = link.meta?.issueKey as string | undefined;
    const projectId = link.meta?.projectId as string | undefined;
    if (!issueKey || !projectId) return;

    try {
      await this.updateIssue(link);
    } catch (error) {
      console.error(
        "[jira] onLinkUpdated write-back failed:",
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  /**
   * Resolve a Plot actor email to a Jira accountId via user search, cached
   * under `jira_user:<email>`. Returns null when no email or no match.
   */
  private async resolveAccountId(
    client: Version3Client,
    email: string | null | undefined
  ): Promise<string | null> {
    if (!email) return null;
    const cached = await this.get<string>(`jira_user:${email}`);
    if (cached) return cached;

    const users = await client.userSearch.findUsers({ query: email });
    // Prefer an exact emailAddress match; fall back to the first result.
    const match =
      users.find(
        (u) => u.emailAddress?.toLowerCase() === email.toLowerCase()
      ) ?? users[0];
    if (match?.accountId) {
      // Intentionally retained for the connector instance's lifetime: this
      // cache is not cleared on disable (the store has no prefix-clear). Low,
      // bounded cardinality and self-correcting on re-sync, so leaving stale
      // entries is acceptable.
      await this.set(`jira_user:${email}`, match.accountId);
      return match.accountId;
    }
    return null;
  }

  /**
   * Create a new Jira issue from a Plot thread. `draft.channelId` is the Jira
   * project id; `draft.status` is the project's first "new"-category status id
   * (from the per-project compose config) or the symbolic "new" fallback.
   */
  async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "issue") return null;

    const projectId = draft.channelId;
    const client = await this.getClient(projectId);

    // Resolve the default issue type: prefer a non-subtask named "Task",
    // else the first non-subtask issue type.
    const meta = await client.issues.getCreateIssueMetaIssueTypes({
      projectIdOrKey: projectId,
    });
    const issueTypes = (meta.issueTypes ?? []).filter((it) => !it.subtask);
    const issueType =
      issueTypes.find((it) => it.name?.toLowerCase() === "task") ??
      issueTypes[0];
    if (!issueType?.id) {
      console.error(
        `No usable Jira issue type found for project ${projectId}`
      );
      return null;
    }

    const created = await client.issues.createIssue({
      fields: {
        summary: draft.title,
        project: { id: projectId },
        issuetype: { id: issueType.id },
        ...(draft.noteContent
          ? { description: textToADF(draft.noteContent) }
          : {}),
      },
    });

    if (!created.id) return null;

    // Fetch the created issue for its key + URL.
    let issueKey: string | undefined = created.key;
    let issueUrl: string | undefined;
    try {
      const cloudId = await this.getCloudId(projectId);
      issueUrl = issueKey
        ? `https://api.atlassian.com/ex/jira/${cloudId}/browse/${issueKey}`
        : undefined;
      const source = `jira:${cloudId}:issue:${created.id}`;

      // Resolve the REAL workflow status id the issue landed in. `draft.status`
      // may be the symbolic "new" fallback (when the per-project compose path
      // couldn't discover a real status id), which is NOT a valid Jira status
      // id — persisting it would leave the link with a phantom status until the
      // first sync-in corrects it. Fetch the created issue's actual
      // fields.status.id (mirrors how Linear resolves the real state on create)
      // and fall back to draft.status only if the fetch fails.
      let resolvedStatus: string | undefined = draft.status ?? undefined;
      try {
        const issue = await client.issues.getIssue({
          issueIdOrKey: created.id,
          fields: ["status"],
        });
        const realStatusId = issue.fields?.status?.id;
        if (realStatusId) {
          resolvedStatus = realStatusId;
        }
      } catch (statusError) {
        console.error(
          "Failed to resolve created Jira issue status, falling back to draft status:",
          statusError
        );
      }

      const threadActions: Action[] = [];
      if (issueUrl) {
        threadActions.push({
          type: ActionType.external,
          title: "Open in Jira",
          url: issueUrl,
        });
      }

      return {
        source,
        type: "issue",
        title: draft.title,
        status: resolvedStatus,
        meta: {
          issueKey: issueKey ?? created.id,
          projectId,
        },
        actions: threadActions.length > 0 ? threadActions : undefined,
        sourceUrl: issueUrl ?? null,
        // Bind the opening note to the issue description (the same
        // "description" key sync-in emits) so edits round-trip via
        // onNoteUpdated. externalContent is the description as Jira stored it
        // — adfToText(textToADF(body)) matches convertIssueToLink's inbound
        // adfToText so the baseline hash lines up.
        originatingNote: {
          key: "description",
          externalContent: draft.noteContent
            ? adfToText(textToADF(draft.noteContent))
            : undefined,
        },
      };
    } catch (error) {
      console.error("Failed to finalize created Jira issue:", error);
      return null;
    }
  }

  /**
   * Called when a note is created on a thread owned by this connector.
   *
   * Returns a {@link NoteWriteBackResult} so the runtime can set the note's
   * key to `comment-{id}` and record the ADF-extracted plain text as the
   * sync baseline. Sync-in (both batch search and webhook paths) runs the
   * comment's ADF body through `adfToText` before building the NewNote, so we
   * mirror that same extraction here — when nothing has changed on the Jira
   * side the hash matches and Plot's richer content is preserved.
   */
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const fileActions = (note.actions ?? []).filter(
      (a): a is Extract<Action, { type: typeof ActionType.file }> =>
        a.type === ActionType.file
    );
    return this.addIssueComment(thread.meta ?? {}, note.content ?? "", fileActions);
  }

  /**
   * Called when a Plot user edits an existing note on a Jira-owned thread.
   * For the "description" note, edits the issue description; for comment notes
   * (key `comment-<id>`), edits the corresponding comment. Refreshes the sync
   * baseline from the round-tripped ADF text so the next sync-in matches.
   */
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    if (!note.key) return;

    const issueKey = thread.meta?.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in thread meta");
    }
    const projectId = thread.meta?.projectId as string;
    const client = await this.getClient(projectId);

    const body = note.content ?? "";

    // The opening note maps to the issue description (key "description"),
    // which is part of the issue body, not a comment.
    if (note.key === "description") {
      await client.issues.editIssue({
        issueIdOrKey: issueKey,
        fields: { description: textToADF(body) },
      });
      // Sync-in runs the description ADF through adfToText, so match that with
      // adfToText(textToADF(body)) for the baseline.
      return { externalContent: adfToText(textToADF(body)) };
    }

    const commentMatch = note.key.match(/^comment-(.+)$/);
    if (!commentMatch) return;
    const commentId = commentMatch[1];

    const adfBody = textToADF(body);
    const result = await client.issueComments.updateComment({
      issueIdOrKey: issueKey,
      id: commentId,
      body: adfBody,
    });

    // Sync-in extracts plain text from the comment's ADF body — mirror that
    // here so the baseline hash matches on the next sync-in pass.
    const externalContent = result?.body
      ? typeof result.body === "string"
        ? result.body
        : adfToText(result.body)
      : adfToText(adfBody);

    return { externalContent };
  }

  /**
   * Add a comment to a Jira issue, optionally uploading file attachments.
   *
   * Jira attaches files to the issue (not to a specific comment), so file
   * actions are uploaded via `issueAttachments.addAttachment` and the comment
   * body itself is left as the note text.
   *
   * @param meta - Thread metadata containing issueKey and projectId
   * @param body - Comment text (converted to ADF format)
   * @param fileActions - Optional file actions to upload as issue attachments
   * @param noteId - Optional Plot note ID for dedup
   */
  async addIssueComment(
    meta: import("@plotday/twister").ThreadMeta,
    body: string,
    fileActions: Array<Extract<Action, { type: typeof ActionType.file }>> = [],
    noteId?: string,
  ): Promise<NoteWriteBackResult | void> {
    const issueKey = meta.issueKey as string | undefined;
    if (!issueKey) {
      throw new Error("Jira issue key not found in thread meta");
    }
    const projectId = meta.projectId as string;
    const client = await this.getClient(projectId);

    // Upload any attached files to the issue. Jira attaches to the issue, not
    // the comment — best-effort per file.
    for (const action of fileActions) {
      try {
        const file = await this.tools.files.read(action.fileId);
        // Use a Blob (universally supported under the Workers runtime) for the
        // multipart body rather than a Node Buffer.
        const blob = new Blob([file.data as BlobPart], {
          type: file.mimeType,
        });
        await client.issueAttachments.addAttachment({
          issueIdOrKey: issueKey,
          attachment: {
            filename: file.fileName,
            file: blob,
            mimeType: file.mimeType,
          },
        });
      } catch (e) {
        console.error("Jira file attachment upload failed", action.fileId, e);
      }
    }

    // Convert plain text to Atlassian Document Format (ADF)
    const adfBody = textToADF(body);

    const result = await client.issueComments.addComment({
      issueIdOrKey: issueKey,
      comment: adfBody,
      properties: noteId ? [{ key: "plotNoteId", value: noteId }] : undefined,
    });

    if (result?.id) {
      // Sync-in extracts plain text from the comment's ADF body — mirror
      // that same extraction here so the next sync-in's hash matches the
      // baseline we're about to record.
      const externalContent = result.body
        ? typeof result.body === "string"
          ? result.body
          : adfToText(result.body)
        : adfToText(adfBody);
      return {
        key: `comment-${result.id}`,
        externalContent,
      };
    }
  }

  /**
   * Download a Jira attachment identified by its attachment id (`ref`).
   *
   * The ref is emitted as an `ActionType.fileRef` action during inbound sync
   * in `convertIssueToLink`, which also caches `jira:att-project:<id>`. Jira
   * attachment `content` URLs require an Authorization header, so a bare
   * redirect would 401 — we fetch the bytes via `getAttachmentContent` (which
   * carries OAuth auth) and stream the Buffer back instead.
   */
  override async downloadAttachment(
    ref: string
  ): Promise<{ body: Uint8Array; mimeType: string }> {
    const projectId = await this.get<string>(`jira:att-project:${ref}`);
    if (!projectId) {
      throw new Error(
        `Unknown Jira attachment: ${ref}. The attachment may have been ` +
          `synced before file support was enabled. Try re-syncing the Jira connection.`
      );
    }
    const client = await this.getClient(projectId);
    // getAttachmentContent returns a Buffer (a Uint8Array subclass) in Node,
    // or an ArrayBuffer-like under the Workers runtime. Normalize to Uint8Array
    // without re-interpreting the bytes.
    const content = (await client.issueAttachments.getAttachmentContent({
      id: ref,
    })) as unknown;
    const body =
      content instanceof Uint8Array
        ? content
        : new Uint8Array(content as ArrayBuffer);
    return {
      body,
      mimeType: "application/octet-stream",
    };
  }

  /**
   * Handle incoming webhook events from Jira
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string
  ): Promise<void> {
    // Verify the registration secret. Jira dynamic webhooks aren't HMAC-signed,
    // so we compare the `secret` query param against the per-project secret we
    // embedded in the registered URL (constant-time). A missing stored secret
    // (e.g. webhook registered before this hardening landed) is allowed through
    // for backwards compatibility, but a present-and-mismatched secret is
    // rejected.
    const storedSecret = await this.get<string>(`webhook_secret_${projectId}`);
    if (storedSecret) {
      const providedSecret = request.params?.secret ?? "";
      if (!constantTimeEqual(providedSecret, storedSecret)) {
        console.warn("Jira webhook secret mismatch, dropping request");
        return;
      }
    }

    const payload = request.body as any;

    // Split handling by webhook event type for efficiency
    if (payload.webhookEvent?.startsWith("jira:issue_")) {
      await this.handleIssueWebhook(payload, projectId);
    } else if (payload.webhookEvent?.startsWith("comment_")) {
      await this.handleCommentWebhook(payload, projectId);
    } else {
      console.log("Ignoring webhook event:", payload.webhookEvent);
    }
  }

  /**
   * Handle issue webhook events - only updates issue metadata, not comments
   */
  private async handleIssueWebhook(
    payload: any,
    projectId: string
  ): Promise<void> {
    const issue = payload.issue;
    if (!issue) {
      console.error("No issue in webhook payload");
      return;
    }

    const fields = issue.fields || {};
    const reporter = fields.reporter || fields.creator;
    const assignee = fields.assignee;

    // Prepare author and assignee contacts
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (reporter) {
      authorContact = {
        ...(reporter.emailAddress ? { email: reporter.emailAddress } : {}),
        name: reporter.displayName,
        avatar: reporter.avatarUrls?.["48x48"],
        ...atlassianSource(reporter.accountId),
      };
    }
    if (assignee) {
      assigneeContact = {
        ...(assignee.emailAddress ? { email: assignee.emailAddress } : {}),
        name: assignee.displayName,
        avatar: assignee.avatarUrls?.["48x48"],
        ...atlassianSource(assignee.accountId),
      };
    }

    // Get cloud ID for constructing stable source identifier
    let cloudId: string | undefined;
    try {
      cloudId = await this.getCloudId(projectId);
    } catch (error) {
      console.error("Failed to get cloud ID for source identifier:", error);
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

    // Extract description
    let description: string | null = null;
    if (fields.description) {
      const extracted =
        typeof fields.description === "string"
          ? fields.description
          : adfToText(fields.description);
      if (extracted && extracted.trim().length > 0) {
        description = extracted;
      }
    }

    // Create partial link update (empty notes = doesn't touch existing notes)
    const link: NewLinkWithNotes = {
      ...(source ? { source } : {}),
      type: "issue",
      title: fields.summary || issue.key,
      created: fields.created ? new Date(fields.created) : undefined,
      meta: {
        issueKey: issue.key,
        projectId,
      },
      author: authorContact,
      assignee: assigneeContact ?? null,
      status: fields.status?.id ?? (fields.resolutiondate ? "done" : "open"),
      preview: description || null,
      notes: [],
    };

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Handle comment webhook events - only updates the specific comment
   */
  private async handleCommentWebhook(
    payload: any,
    projectId: string
  ): Promise<void> {
    const comment = payload.comment;
    const issue = payload.issue;

    if (!comment || !issue) {
      console.error("Missing comment or issue in webhook payload");
      return;
    }

    // Get cloud ID for constructing stable source identifier
    let cloudId: string | undefined;
    try {
      cloudId = await this.getCloudId(projectId);
    } catch (error) {
      console.error("Failed to get cloud ID for source identifier:", error);
    }

    // Stable source identifier using immutable issue ID (not mutable issue.key)
    const source = cloudId && issue.id
      ? `jira:${cloudId}:issue:${issue.id}`
      : undefined;

    // Extract comment author
    let commentAuthor: NewContact | undefined;
    const author = comment.author;
    if (author) {
      commentAuthor = {
        ...(author.emailAddress ? { email: author.emailAddress } : {}),
        name: author.displayName,
        avatar: author.avatarUrls?.["48x48"],
        ...atlassianSource(author.accountId),
      };
    }

    // Extract comment text
    const commentText =
      typeof comment.body === "string"
        ? comment.body
        : adfToText(comment.body);

    // Check for Plot note ID in comment properties (set when comment was created from Plot)
    const plotNoteId = comment.properties?.find(
      (p: any) => p.key === "plotNoteId"
    )?.value;

    // Create link update with single comment note
    const link: NewLinkWithNotes = {
      ...(source ? { source } : {}),
      type: "issue",
      title: issue.fields?.summary || issue.key,
      notes: [
        {
          key: `comment-${comment.id}`,
          // If this comment originated from Plot, identify by note ID so we update the existing note
          // rather than creating a duplicate
          ...(plotNoteId ? { id: plotNoteId } : {}),
          content: commentText,
          created: comment.created ? new Date(comment.created) : undefined,
          author: commentAuthor,
        } as any,
      ],
      meta: {
        issueKey: issue.key,
        projectId,
      },
    };

    await this.tools.integrations.saveLink(link);
  }

  /**
   * Stop syncing a Jira project
   */
  async stopSync(projectId: string): Promise<void> {
    // Cancel pending webhook renewal task (singleton keyed by project)
    await this.cancelScheduledTask(`webhook-renewal:${projectId}`);

    // Delete webhook from Jira
    const webhookId = await this.get<number>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const client = await this.getClient(projectId);
        await client.webhooks.deleteWebhookById({
          webhookIds: [webhookId],
        });
      } catch (error) {
        console.warn("Failed to delete Jira webhook:", error);
      }
    }

    // Cleanup stored state
    await this.clear(`webhook_id_${projectId}`);
    await this.clear(`webhook_url_${projectId}`);
    await this.clear(`webhook_secret_${projectId}`);
    await this.clear(`sync_state_${projectId}`);
  }
}

/**
 * Returns a `source` property for NewContact if the Atlassian accountId is valid.
 * Used for Atlassian personal data reporting compliance.
 */
function atlassianSource(accountId: string | undefined): Pick<NewContact, "source"> | {} {
  if (accountId && accountId !== "_unknown_") {
    return { source: { accountId } };
  }
  return {};
}

/**
 * Constant-time string comparison to avoid leaking secret length / content via
 * timing. Returns false immediately on length mismatch (length is not secret),
 * then XORs all bytes so the loop runtime doesn't depend on where they differ.
 */
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

export default Jira;
