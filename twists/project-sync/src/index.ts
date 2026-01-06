import { Asana } from "@plotday/tool-asana";
import { Jira } from "@plotday/tool-jira";
import { Linear } from "@plotday/tool-linear";
import {
  type Activity,
  ActivityLinkType,
  ActivityType,
  ActivityUpdate,
  ActorType,
  type NewActivityWithNotes,
  type Note,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type {
  ProjectAuth,
  ProjectTool,
} from "@plotday/twister/common/projects";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

type ProjectProvider = "linear" | "jira" | "asana";

type StoredProjectAuth = {
  provider: ProjectProvider;
  authToken: string;
};

/**
 * Project Sync Twist
 *
 * Syncs project management tools (Linear, Jira, Asana) with Plot.
 * Converts issues and tasks into Plot activities with notes for comments.
 */
export default class ProjectSync extends Twist<ProjectSync> {
  build(build: ToolBuilder) {
    return {
      linear: build(Linear),
      jira: build(Jira),
      asana: build(Asana),
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
   * Get the tool for a specific project provider
   */
  private getProviderTool(provider: ProjectProvider): ProjectTool {
    switch (provider) {
      case "linear":
        return this.tools.linear;
      case "jira":
        return this.tools.jira;
      case "asana":
        return this.tools.asana;
      default:
        throw new Error(`Unknown provider: ${provider}`);
    }
  }

  /**
   * Get stored auth for a provider
   */
  private async getAuthToken(
    provider: ProjectProvider
  ): Promise<string | null> {
    const auths = await this.getStoredAuths();
    const auth = auths.find((a) => a.provider === provider);
    return auth?.authToken || null;
  }

  /**
   * Store auth for a provider
   */
  private async addStoredAuth(
    provider: ProjectProvider,
    authToken: string
  ): Promise<void> {
    const auths = await this.getStoredAuths();
    const existingIndex = auths.findIndex((a) => a.provider === provider);

    if (existingIndex >= 0) {
      auths[existingIndex].authToken = authToken;
    } else {
      auths.push({ provider, authToken });
    }

    await this.set("project_auths", auths);
  }

  /**
   * Get all stored auths
   */
  private async getStoredAuths(): Promise<StoredProjectAuth[]> {
    return (await this.get<StoredProjectAuth[]>("project_auths")) || [];
  }

  /**
   * Called when twist is activated
   * Presents auth options for all supported providers
   */
  async activate(priority: Pick<Priority, "id">) {
    // Get auth links from all providers
    const linearAuthLink = await this.tools.linear.requestAuth(
      this.onAuthComplete,
      "linear"
    );
    const jiraAuthLink = await this.tools.jira.requestAuth(
      this.onAuthComplete,
      "jira"
    );
    const asanaAuthLink = await this.tools.asana.requestAuth(
      this.onAuthComplete,
      "asana"
    );

    // Create onboarding activity with all provider options
    // Using start: null to create a "Do Someday" item - setup task, not urgent
    const activity = await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect a project management tool",
      start: null, // "Do Someday" - optional setup, not time-sensitive
      notes: [
        {
          content:
            "Connect your project management account to start syncing projects and issues to Plot. Choose one:",
          links: [linearAuthLink, jiraAuthLink, asanaAuthLink],
        },
      ],
    });

    // Store for later updates
    await this.set("onboarding_activity_id", activity.id);
  }

  /**
   * Called when OAuth completes for any provider
   * Fetches available projects and presents selection UI
   */
  async onAuthComplete(auth: ProjectAuth, provider: ProjectProvider) {
    // Store auth token for this provider
    await this.addStoredAuth(provider, auth.authToken);

    // Get the tool for this provider
    const tool = this.getProviderTool(provider);

    // Fetch projects
    const projects = await tool.getProjects(auth.authToken);

    if (projects.length === 0) {
      await this.updateOnboardingActivity(`No ${provider} projects found.`);
      return;
    }

    // Create project selection links
    const links: Array<{
      type: ActivityLinkType.callback;
      title: string;
      callback: any;
    }> = await Promise.all(
      projects.map(async (project) => ({
        type: ActivityLinkType.callback as const,
        title: project.key ? `${project.key}: ${project.name}` : project.name,
        callback: await this.callback(
          this.onProjectSelected,
          provider,
          project.id,
          project.name
        ),
      }))
    );

    // Add project selection to parent activity
    const activity = await this.getParentActivity();
    if (activity) {
      await this.tools.plot.createNote({
        activity,
        content: `Choose which ${provider} projects you'd like to sync to Plot:`,
        links,
      });
    }
  }

  /**
   * Called when user selects a project to sync
   * Initiates the sync process for that project
   */
  async onProjectSelected(
    args: any,
    provider: ProjectProvider,
    projectId: string,
    projectName: string
  ) {
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      throw new Error(`No ${provider} auth token found`);
    }

    // Track synced projects with provider
    const syncKey = `${provider}:${projectId}`;
    const synced = (await this.get<string[]>("synced_projects")) || [];
    if (!synced.includes(syncKey)) {
      synced.push(syncKey);
      await this.set("synced_projects", synced);
    }

    // Notify user that sync is starting
    const activity = await this.getParentActivity();
    if (activity) {
      await this.tools.plot.createNote({
        activity,
        content: `Great! Your issues from ${projectName} will appear shortly.`,
      });
    }

    // Get the tool for this provider
    const tool = this.getProviderTool(provider);

    // Start sync (full history as requested)
    await tool.startSync(
      authToken,
      projectId,
      this.onIssue,
      undefined, // No time filter - sync all issues
      provider,
      projectId
    );
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
   * Called for each issue synced from any provider
   * Creates or updates Plot activities based on issue state
   */
  async onIssue(
    issue: NewActivityWithNotes,
    provider: ProjectProvider,
    projectId: string
  ) {
    // Check if issue already exists (using source for deduplication)
    if (issue.source) {
      const existing = await this.tools.plot.getActivityBySource(issue.source);

      if (existing) {
        // Issue exists - add update as Note to the thread
        if (issue.notes?.[0]?.content) {
          await this.tools.plot.createNote({
            activity: { id: existing.id },
            content: `Issue updated:\n\n${issue.notes[0].content}`,
          });
        }
        return;
      }
    }

    // Filter out empty notes to avoid warnings in Plot tool
    issue.notes = issue.notes?.filter((note) => !this.isNoteEmpty(note));

    // Create new activity for new issue (new thread with initial note)
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createActivity(issue);
  }

  /**
   * Parse source field to extract provider and issue information
   * Format: "{provider}:issue:{projectId}:{issueId}"
   * Examples:
   *   - "linear:issue:team-abc:issue-123"
   *   - "asana:task:proj-456:task-789"
   *   - "jira:issue:PROJ:PROJ-42"
   */
  private parseSource(source: string): {
    provider: ProjectProvider;
    projectId: string;
    issueId: string;
  } | null {
    const parts = source.split(":");
    if (parts.length !== 4) return null;

    const [provider, type, projectId, issueId] = parts;

    // Validate provider
    if (!["linear", "jira", "asana"].includes(provider)) {
      return null;
    }

    // Validate type
    if (!["issue", "task"].includes(type)) {
      return null;
    }

    return {
      provider: provider as ProjectProvider,
      projectId,
      issueId,
    };
  }

  /**
   * Called when an activity created by this twist is updated
   * Syncs changes back to the external service
   */
  private async onActivityUpdated(
    _activity: Activity,
    changes: {
      update: ActivityUpdate;
      previous: Activity;
      tagsAdded: Record<string, string[]>;
      tagsRemoved: Record<string, string[]>;
    }
  ): Promise<void> {
    // Only sync activities with a source (synced from external services)
    if (!changes.update.source) return;

    const parsed = this.parseSource(changes.update.source);
    if (!parsed) return;

    const { provider } = parsed;

    // Get auth token for this provider
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      console.warn(`No auth token found for ${provider}, skipping sync`);
      return;
    }

    const tool = this.getProviderTool(provider);

    try {
      // Sync all changes using the generic updateIssue method
      if (tool.updateIssue) {
        await tool.updateIssue(authToken, changes.update);
        console.log(
          `Synced activity update to ${provider} issue from source ${changes.update.source}`
        );
      }
    } catch (error) {
      console.error(
        `Failed to sync activity update to ${provider} issue ${changes.update.source}:`,
        error
      );
    }
  }

  /**
   * Called when a note is created on an activity created by this twist
   * Syncs the note as a comment to the external service
   */
  private async onNoteCreated(note: Note): Promise<void> {
    // Get parent activity from note
    const activity = note.activity;

    // Only sync activities with a source (synced from external services)
    if (!activity.source) return;

    // Filter out notes created by twists
    if (note.author.type === ActorType.Twist) {
      return;
    }

    const parsed = this.parseSource(activity.source);
    if (!parsed) return;

    const { provider, issueId } = parsed;

    // Get auth token for this provider
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      console.warn(`No auth token found for ${provider}, skipping sync`);
      return;
    }

    const tool = this.getProviderTool(provider);

    // Only sync if note has content
    if (!note.content) return;

    try {
      // Sync note as comment
      if (tool.addIssueComment) {
        await tool.addIssueComment(authToken, issueId, note.content);
        console.log(`Synced note to ${provider} issue ${issueId}`);
      }
    } catch (error) {
      console.error(
        `Failed to sync note to ${provider} issue ${issueId}:`,
        error
      );
    }
  }

  /**
   * Called when twist is deactivated
   * Stops all syncs and cleans up state
   */
  async deactivate() {
    // Stop all syncs
    const auths = await this.getStoredAuths();
    const synced = (await this.get<string[]>("synced_projects")) || [];

    for (const syncKey of synced) {
      // Parse provider:projectId format
      const [provider, projectId] = syncKey.split(":") as [
        ProjectProvider,
        string
      ];

      const authToken = await this.getAuthToken(provider);
      if (authToken) {
        const tool = this.getProviderTool(provider);
        try {
          await tool.stopSync(authToken, projectId);
        } catch (error) {
          console.warn(
            `Failed to stop sync for ${provider}:${projectId}:`,
            error
          );
        }
      }
    }

    // Cleanup
    await this.clear("project_auths");
    await this.clear("synced_projects");
    await this.clear("onboarding_activity_id");
  }

  /**
   * Get the parent onboarding activity reference
   */
  private async getParentActivity(): Promise<Pick<Activity, "id"> | undefined> {
    const id = await this.get<string>("onboarding_activity_id");
    return id ? { id } : undefined;
  }

  /**
   * Helper to update the onboarding activity with status messages
   */
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
