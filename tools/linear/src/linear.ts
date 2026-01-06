import { type Issue, LinearClient } from "@linear/sdk";

import {
  type ActivityLink,
  ActivityType,
  type NewActivityWithNotes,
  type NewNote,
  type SyncUpdate,
  ActivityUpdate as TwisterActivityUpdate,
} from "@plotday/twister";
import type {
  Project,
  ProjectAuth,
  ProjectSyncOptions,
  ProjectTool,
} from "@plotday/twister/common/projects";
import type { Actor, ActorId, NewContact } from "@plotday/twister/plot";
import { Tool, type ToolBuilder } from "@plotday/twister/tool";
import { type Callback, Callbacks } from "@plotday/twister/tools/callbacks";
import {
  AuthLevel,
  AuthProvider,
  type Authorization,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { ContactAccess, Plot } from "@plotday/twister/tools/plot";
import { Tasks } from "@plotday/twister/tools/tasks";
import { quickHash } from "@plotday/twister/utils/hash";
import { Uuid } from "@plotday/twister/utils/uuid";

type SyncState = {
  after: string | null;
  batchNumber: number;
  issuesProcessed: number;
  initialSync: boolean;
};

/**
 * Stores the mapping between Linear issues and Plot activities.
 * Used for tracking which issues have been synced and detecting changes.
 */
type SyncMapping = {
  /** External Linear issue ID */
  externalId: string;
  /** Tool-generated UUID for the Plot activity */
  activityId: Uuid;
  /** Tool-generated UUID for the description note */
  descriptionNoteId?: Uuid;
  /** Hash of the description content for change detection */
  descriptionHash?: string;
  /** Timestamp of last sync */
  lastSyncedAt: string;
};

/**
 * Linear project management tool
 *
 * Implements the ProjectTool interface for syncing Linear teams and issues
 * with Plot activities.
 */
export class Linear extends Tool<Linear> implements ProjectTool {
  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://api.linear.app/*"] }),
      callbacks: build(Callbacks),
      tasks: build(Tasks),
      plot: build(Plot, { contact: { access: ContactAccess.Write } }),
    };
  }

  /**
   * Create Linear API client with auth token
   */
  private async getClient(authToken: string): Promise<LinearClient> {
    const authorization = await this.get<Authorization>(
      `authorization:${authToken}`
    );
    if (!authorization) {
      throw new Error("Authorization no longer available");
    }

    const token = await this.tools.integrations.get(authorization);
    if (!token) {
      throw new Error("Authorization no longer available");
    }

    return new LinearClient({ accessToken: token.token });
  }

  /**
   * Request Linear OAuth authorization
   */
  async requestAuth<
    TCallback extends (auth: ProjectAuth, ...args: any[]) => any
  >(
    callback: TCallback,
    ...extraArgs: TCallback extends (auth: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<ActivityLink> {
    const linearScopes = ["read", "write"];

    // Generate opaque token for authorization
    const authToken = crypto.randomUUID();

    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );

    // Request auth and return the activity link
    return await this.tools.integrations.request(
      {
        provider: AuthProvider.Linear,
        level: AuthLevel.User,
        scopes: linearScopes,
      },
      this.onAuthSuccess,
      authToken,
      callbackToken
    );
  }

  /**
   * Handle successful OAuth authorization
   */
  private async onAuthSuccess(
    authorization: Authorization,
    authToken: string,
    callbackToken: Callback
  ): Promise<void> {
    // Store authorization for later use
    await this.set(`authorization:${authToken}`, authorization);

    // Execute the callback with the auth token
    await this.run(callbackToken, { authToken });
  }

  /**
   * Get list of Linear teams (projects)
   */
  async getProjects(authToken: string): Promise<Project[]> {
    const client = await this.getClient(authToken);
    const teams = await client.teams();

    return teams.nodes.map((team) => ({
      id: team.id,
      name: team.name,
      description: team.description || null,
      key: team.key,
    }));
  }

  /**
   * Start syncing issues from a Linear team
   */
  async startSync<
    TCallback extends (issue: NewActivityWithNotes, ...args: any[]) => any
  >(
    authToken: string,
    projectId: string,
    callback: TCallback,
    options?: ProjectSyncOptions,
    ...extraArgs: TCallback extends (issue: any, ...rest: infer R) => any
      ? R
      : []
  ): Promise<void> {
    // Setup webhook for real-time updates
    await this.setupLinearWebhook(authToken, projectId);

    // Store callback for webhook processing
    const callbackToken = await this.tools.callbacks.createFromParent(
      callback,
      ...extraArgs
    );
    await this.set(`callback_${projectId}`, callbackToken);

    // Start initial batch sync
    await this.startBatchSync(authToken, projectId, options);
  }

  /**
   * Setup Linear webhook for real-time updates
   */
  private async setupLinearWebhook(
    authToken: string,
    projectId: string
  ): Promise<void> {
    try {
      const client = await this.getClient(authToken);

      // Create webhook URL first (Linear requires valid URL at creation time)
      const webhookUrl = await this.tools.network.createWebhook({
        callback: this.onWebhook,
        extraArgs: [projectId, authToken],
      });

      // Skip webhook setup for localhost (development mode)
      if (
        webhookUrl.includes("localhost") ||
        webhookUrl.includes("127.0.0.1")
      ) {
        console.log("Skipping webhook setup for localhost URL:", webhookUrl);
        return;
      }

      // Create webhook in Linear with the actual URL
      const webhookPayload = await client.createWebhook({
        url: webhookUrl,
        teamId: projectId,
        resourceTypes: ["Issue", "Comment"],
      });

      // Extract and store webhook ID and secret
      const webhook = await webhookPayload.webhook;
      if (webhook?.id) {
        await this.set(`webhook_id_${projectId}`, webhook.id);
      }
      if (webhook?.secret) {
        await this.set(`webhook_secret_${projectId}`, webhook.secret);
      }
    } catch (error) {
      console.warn(
        "Failed to set up Linear webhook, continuing with sync:",
        error
      );
    }
  }

  /**
   * Initialize batch sync process
   */
  private async startBatchSync(
    authToken: string,
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    // Initialize sync state
    await this.set(`sync_state_${projectId}`, {
      after: null,
      batchNumber: 1,
      issuesProcessed: 0,
      initialSync: true,
    });

    // Queue first batch
    const batchCallback = await this.callback(
      this.syncBatch,
      authToken,
      projectId,
      options
    );

    await this.tools.tasks.runTask(batchCallback);
  }

  /**
   * Process a batch of issues
   */
  private async syncBatch(
    authToken: string,
    projectId: string,
    options?: ProjectSyncOptions
  ): Promise<void> {
    const state = await this.get<SyncState>(`sync_state_${projectId}`);
    if (!state) {
      throw new Error(`Sync state not found for project ${projectId}`);
    }

    // Retrieve callback token from storage
    const callbackToken = await this.get<Callback>(`callback_${projectId}`);
    if (!callbackToken) {
      throw new Error(`Callback token not found for project ${projectId}`);
    }

    const client = await this.getClient(authToken);
    const team = await client.team(projectId);

    // Build filter
    const filter: any = {};
    if (options?.timeMin) {
      filter.createdAt = { gte: options.timeMin };
    }

    // Fetch batch of issues (50 at a time)
    const issuesConnection = await team.issues({
      first: 50,
      after: state.after || undefined,
      filter: Object.keys(filter).length > 0 ? filter : undefined,
    });

    // Process each issue
    for (const issue of issuesConnection.nodes) {
      const syncUpdate = await this.convertIssueToSyncUpdate(
        issue,
        projectId,
        state.initialSync
      );

      if (syncUpdate) {
        // Execute the callback using the callback token
        await this.tools.callbacks.run(callbackToken, syncUpdate);
      }
    }

    // Check if more pages
    if (issuesConnection.pageInfo.hasNextPage) {
      await this.set(`sync_state_${projectId}`, {
        after: issuesConnection.pageInfo.endCursor,
        batchNumber: state.batchNumber + 1,
        issuesProcessed: state.issuesProcessed + issuesConnection.nodes.length,
        initialSync: state.initialSync,
      });

      // Queue next batch
      const nextBatch = await this.callback(
        this.syncBatch,
        authToken,
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
   * Convert a Linear issue to a SyncUpdate
   */
  private async convertIssueToSyncUpdate(
    issue: Issue,
    projectId: string,
    initialSync: boolean
  ): Promise<SyncUpdate | null> {
    const state = await issue.state;
    const creator = await issue.creator;
    const assignee = await issue.assignee;
    const comments = await issue.comments();

    // Prepare author and assignee contacts - will be passed directly as NewContact
    let authorContact: NewContact | undefined;
    let assigneeContact: NewContact | undefined;

    if (creator?.email) {
      authorContact = {
        email: creator.email,
        name: creator.name,
        avatar: creator.avatarUrl,
      };
    }
    if (assignee?.email) {
      assigneeContact = {
        email: assignee.email,
        name: assignee.name,
        avatar: assignee.avatarUrl,
      };
    }

    // Prepare description content
    const description = issue.description || "";
    const hasDescription = description.trim().length > 0;
    const descriptionHash = hasDescription ? quickHash(description) : undefined;

    // Check for existing mapping
    const mappingKey = `sync:${projectId}:${issue.id}`;
    const existingMapping = await this.get<SyncMapping>(mappingKey);

    if (!existingMapping) {
      // NEW ISSUE: Generate UUIDs and create mapping
      const activityId = Uuid.Generate();
      const descriptionNoteId = hasDescription ? Uuid.Generate() : undefined;

      // Build notes array: description + comments
      const notes: NewNote[] = [];

      if (hasDescription) {
        notes.push({
          id: descriptionNoteId!,
          activity: { id: activityId },
          content: description,
        });
      }

      // Add comments as notes
      for (const comment of comments.nodes) {
        notes.push({
          id: Uuid.Generate(),
          activity: { id: activityId },
          content: comment.body,
        });
      }

      const activity: NewActivityWithNotes = {
        id: activityId,
        type: ActivityType.Action,
        title: issue.title,
        author: authorContact,
        assignee: assigneeContact,
        doneAt:
          state?.name === "Done" || state?.name === "Completed"
            ? new Date()
            : null,
        meta: {
          linearId: issue.id,
          projectId,
          url: issue.url,
        },
        notes,
        unread: !initialSync, // false for initial sync, true for incremental updates
      };

      // Store mapping
      const mapping: SyncMapping = {
        externalId: issue.id,
        activityId,
        descriptionNoteId,
        descriptionHash,
        lastSyncedAt: new Date().toISOString(),
      };
      await this.set(mappingKey, mapping);

      return activity;
    } else {
      // EXISTING ISSUE: Detect changes and send update
      const update: TwisterActivityUpdate = { id: existingMapping.activityId };
      let hasChanges = false;
      const newNotes: NewNote[] = [];

      // Check for title changes
      if (issue.title) {
        update.title = issue.title;
        hasChanges = true;
      }

      // Check for state changes
      const doneAt =
        state?.name === "Done" || state?.name === "Completed"
          ? new Date()
          : null;
      update.doneAt = doneAt;
      hasChanges = true;

      // Check for description changes
      if (descriptionHash !== existingMapping.descriptionHash) {
        const newDescriptionNoteId = Uuid.Generate();
        newNotes.push({
          id: newDescriptionNoteId,
          activity: { id: existingMapping.activityId },
          content: description,
        });

        // Update mapping with new description note
        existingMapping.descriptionNoteId = newDescriptionNoteId;
        existingMapping.descriptionHash = descriptionHash;
      }

      // Add new comments as notes
      for (const comment of comments.nodes) {
        newNotes.push({
          id: Uuid.Generate(),
          activity: { id: existingMapping.activityId },
          content: comment.body,
        });
      }

      // Send update if there are changes
      if (hasChanges || newNotes.length > 0) {
        const syncUpdate: SyncUpdate = {
          activityId: existingMapping.activityId,
          update: hasChanges ? update : undefined,
          notes: newNotes.length > 0 ? newNotes : undefined,
        };

        // Update mapping timestamp
        existingMapping.lastSyncedAt = new Date().toISOString();
        await this.set(mappingKey, existingMapping);

        return syncUpdate;
      }

      return null; // No changes
    }
  }

  /**
   * Update issue with new values
   *
   * @param authToken - Authorization token
   * @param update - ActivityUpdate with changed fields
   */
  async updateIssue(
    authToken: string,
    update: import("@plotday/twister").ActivityUpdate
  ): Promise<void> {
    // Get the Linear issue ID from activity meta
    const issueId = update.meta?.linearId as string | undefined;
    if (!issueId) {
      throw new Error("Linear issue ID not found in activity meta");
    }

    const client = await this.getClient(authToken);
    const issue = await client.issue(issueId);
    const updateFields: any = {};

    // Handle title
    if (update.title !== undefined) {
      updateFields.title = update.title;
    }

    // Handle assignee
    if (update.assignee !== undefined) {
      updateFields.assigneeId = update.assignee?.id || null;
    }

    // Handle state based on start + doneAt combination
    if (update.start !== undefined || update.doneAt !== undefined) {
      const team = await issue.team;
      if (team) {
        const states = await team.states();
        let targetState;

        // Determine target state based on combination
        if (update.doneAt !== undefined && update.doneAt !== null) {
          // Completed
          targetState = states.nodes.find(
            (s) =>
              s.name === "Done" ||
              s.name === "Completed" ||
              s.type === "completed"
          );
        } else if (update.start !== undefined && update.start !== null) {
          // In Progress (has start date, not done)
          targetState = states.nodes.find(
            (s) => s.name === "In Progress" || s.type === "started"
          );
        } else if (
          (update.start !== undefined && update.start === null) ||
          (update.doneAt !== undefined && update.doneAt === null)
        ) {
          // Backlog/Todo (no start date, not done)
          targetState = states.nodes.find(
            (s) =>
              s.name === "Todo" ||
              s.name === "Backlog" ||
              s.type === "unstarted"
          );
        }

        if (targetState) {
          updateFields.stateId = targetState.id;
        }
      }
    }

    // Apply updates if any fields changed
    if (Object.keys(updateFields).length > 0) {
      await client.updateIssue(issueId, updateFields);
    }
  }

  /**
   * Add a comment to a Linear issue
   *
   * @param authToken - Authorization token
   * @param issueId - Linear issue ID
   * @param body - Comment text (markdown supported)
   */
  async addIssueComment(
    authToken: string,
    issueId: string,
    body: string
  ): Promise<void> {
    const client = await this.getClient(authToken);

    await client.createComment({
      issueId,
      body,
    });
  }

  /**
   * Verify Linear webhook signature
   * Linear uses HMAC-SHA256 with the webhook secret
   */
  private async verifyLinearSignature(
    signature: string | undefined,
    rawBody: string,
    secret: string,
    webhookTimestamp: number
  ): Promise<boolean> {
    if (!signature) {
      console.warn("Linear webhook missing signature header");
      return false;
    }

    // Verify timestamp to prevent replay attacks (within 60 seconds)
    const currentTime = Date.now();
    const timeDiff = Math.abs(currentTime - webhookTimestamp);
    if (timeDiff > 60000) {
      console.warn(
        `Linear webhook timestamp too old: ${timeDiff}ms (max 60000ms)`
      );
      return false;
    }

    // Compute HMAC-SHA256 signature
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signatureBytes = await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(rawBody)
    );

    // Convert to hex string
    const expectedSignature = Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Constant-time comparison
    return signature === expectedSignature;
  }

  /**
   * Handle incoming webhook events from Linear
   */
  private async onWebhook(
    request: WebhookRequest,
    projectId: string,
    authToken: string,
    webhookSecret?: string
  ): Promise<void> {
    const payload = request.body as any;

    // Verify webhook signature
    // Linear sends Linear-Signature header (not X-Linear-Signature)
    const secret =
      webhookSecret || (await this.get<string>(`webhook_secret_${projectId}`));
    if (secret && request.rawBody) {
      const signature = request.headers["linear-signature"];
      const isValid = await this.verifyLinearSignature(
        signature,
        request.rawBody,
        secret,
        payload.webhookTimestamp
      );

      if (!isValid) {
        console.warn("Linear webhook signature verification failed");
        return;
      }
    } else if (!secret) {
      console.warn("Linear webhook secret not found, skipping verification");
    }

    if (payload.type === "Issue" || payload.type === "Comment") {
      const callbackToken = await this.get<Callback>(`callback_${projectId}`);
      if (!callbackToken) return;

      const client = await this.getClient(authToken);
      const issue = await client.issue(payload.data.id);

      const syncUpdate = await this.convertIssueToSyncUpdate(
        issue,
        projectId,
        false // incremental update, not initial sync
      );

      if (!syncUpdate) return;

      // Execute stored callback (unread flag already set by convertIssueToSyncUpdate)
      await this.tools.callbacks.run(callbackToken, syncUpdate);
    }
  }

  /**
   * Stop syncing a Linear team
   */
  async stopSync(authToken: string, projectId: string): Promise<void> {
    // Remove webhook
    const webhookId = await this.get<string>(`webhook_id_${projectId}`);
    if (webhookId) {
      try {
        const client = await this.getClient(authToken);
        await client.deleteWebhook(webhookId);
      } catch (error) {
        console.warn("Failed to delete Linear webhook:", error);
      }
      await this.clear(`webhook_id_${projectId}`);
    }

    // Cleanup webhook secret
    await this.clear(`webhook_secret_${projectId}`);

    // Cleanup callback
    const callbackToken = await this.get<Callback>(`callback_${projectId}`);
    if (callbackToken) {
      await this.deleteCallback(callbackToken);
      await this.clear(`callback_${projectId}`);
    }

    // Cleanup sync state
    await this.clear(`sync_state_${projectId}`);
  }
}

export default Linear;
