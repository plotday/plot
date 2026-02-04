import { Asana } from "@plotday/tool-asana";
import { Jira } from "@plotday/tool-jira";
import { Linear } from "@plotday/tool-linear";
import {
  type Activity,
  ActivityLink,
  ActivityLinkType,
  ActivityType,
  type Actor,
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
import { Uuid } from "@plotday/twister/utils/uuid";

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
  async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
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

    // Create onboarding activity — private so only the installing user sees it
    const activityId = await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect a project management tool",
      private: true,
      notes: [
        {
          content:
            "Connect your project management account to start syncing projects and issues to Plot. Choose one:",
          links: [linearAuthLink, jiraAuthLink, asanaAuthLink],
          ...(context?.actor ? { mentions: [{ id: context.actor.id }] } : {}),
        },
      ],
    });

    // Store for later updates
    await this.set("onboarding_activity_id", activityId);
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
    const links: Array<ActivityLink> = await Promise.all(
      projects.map(async (project) => ({
        type: ActivityLinkType.callback as const,
        title: project.key ? `${project.key}: ${project.name}` : project.name,
        callback: await this.linkCallback(
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
    _link: ActivityLink,
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
      {
        authToken,
        projectId,
        // No time filter - sync all issues
      },
      this.onIssue,
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
    _projectId: string
  ) {
    // Add provider to meta for routing updates back to the correct tool
    issue.meta = { ...issue.meta, provider };

    // Filter out empty notes to avoid warnings in Plot tool
    issue.notes = issue.notes?.filter((note) => !this.isNoteEmpty(note));

    // Just create/upsert - database handles everything automatically
    // Note: The unread field is already set by the tool based on sync type
    await this.tools.plot.createActivity(issue);
  }

  /**
   * Called when an activity created by this twist is updated
   * Syncs changes back to the external service
   */
  private async onActivityUpdated(
    activity: Activity,
    _changes: {
      tagsAdded: Record<string, string[]>;
      tagsRemoved: Record<string, string[]>;
    }
  ): Promise<void> {
    // Get provider from meta (set by this twist when creating the activity)
    const provider = activity.meta?.provider as ProjectProvider | undefined;
    if (!provider) return;

    // Get auth token for this provider
    const authToken = await this.getAuthToken(provider);
    if (!authToken) {
      console.warn(`No auth token found for ${provider}, skipping sync`);
      return;
    }

    const tool = this.getProviderTool(provider);

    try {
      // Sync all changes using the generic updateIssue method
      // Tool reads its own IDs from activity.meta (e.g., linearId, taskGid, issueKey)
      if (tool.updateIssue) {
        await tool.updateIssue(authToken, activity);
      }
    } catch (error) {
      console.error(`Failed to sync activity update to ${provider}:`, error);
    }
  }

  /**
   * Called when a note is created on an activity created by this twist
   * Syncs the note as a comment to the external service
   */
  private async onNoteCreated(note: Note): Promise<void> {
    // Get parent activity from note
    const activity = note.activity;

    // Filter out notes created by twists to prevent loops
    if (note.author.type === ActorType.Twist) {
      return;
    }

    // Only sync if note has content
    if (!note.content) {
      return;
    }

    // Get provider from meta (set by this twist when creating the activity)
    const provider = activity.meta?.provider as ProjectProvider | undefined;
    if (!provider || !activity.meta) {
      return;
    }

    const tool = this.getProviderTool(provider);
    if (!tool.addIssueComment) {
      console.warn(`Provider ${provider} does not support adding comments`);
      return;
    }

    // Try the note author's credentials first (per-user auth), then fall back
    // to the installer's stored auth. The tool's getClient() handles lookup
    // via integrations.get(provider, actorId).
    const actorId = note.author.id as string;
    const installerAuthToken = await this.getAuthToken(provider);

    const authTokensToTry = [
      actorId,
      ...(installerAuthToken && installerAuthToken !== actorId
        ? [installerAuthToken]
        : []),
    ];

    for (const authToken of authTokensToTry) {
      try {
        const commentKey = await tool.addIssueComment(
          authToken, activity.meta, note.content, note.id
        );
        if (commentKey) {
          await this.tools.plot.updateNote({ id: note.id, key: commentKey });
        }
        return; // Success
      } catch (error) {
        // If this was the actor's token, try the installer's next
        if (authToken === actorId && installerAuthToken && installerAuthToken !== actorId) {
          console.warn(
            `Actor ${actorId} has no ${provider} auth, falling back to installer auth`
          );
          continue;
        }
        console.error(`Failed to sync note to ${provider}:`, error);
      }
    }
  }

  /**
   * Called when twist is deactivated
   * Stops all syncs and cleans up state
   */
  async deactivate() {
    // Stop all syncs
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
    const id = await this.get<Uuid>("onboarding_activity_id");
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
