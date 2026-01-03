import { Linear } from "@plotday/tool-linear";
import {
  type Activity,
  ActivityLinkType,
  ActivityType,
  type NewActivityWithNotes,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import type { ProjectAuth } from "@plotday/twister/common/projects";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

/**
 * Project Sync Twist
 *
 * Syncs project management tools (currently Linear) with Plot.
 * Converts issues and tasks into Plot activities with notes for comments.
 */
export default class ProjectSync extends Twist<ProjectSync> {
  build(build: ToolBuilder) {
    return {
      linear: build(Linear),
      plot: build(Plot, { activity: { access: ActivityAccess.Create } }),
    };
  }

  /**
   * Called when twist is activated
   * Initiates the auth flow for Linear
   */
  async activate(priority: Pick<Priority, "id">) {
    // Request Linear auth
    const authLink = await this.tools.linear.requestAuth(this.onAuthComplete);

    // Create onboarding activity
    const activity = await this.tools.plot.createActivity({
      type: ActivityType.Action,
      title: "Connect Linear",
      notes: [
        {
          content:
            "Connect your Linear account to start syncing projects and issues to Plot.",
          links: [authLink],
        },
      ],
    });

    // Store for later updates
    await this.set("onboarding_activity_id", activity.id);
  }

  /**
   * Called when Linear OAuth completes
   * Fetches available projects and presents selection UI
   */
  async onAuthComplete(auth: ProjectAuth) {
    // Store auth token
    await this.set("linear_auth", auth.authToken);

    // Fetch projects
    const projects = await this.tools.linear.getProjects(auth.authToken);

    if (projects.length === 0) {
      await this.updateOnboardingActivity("No Linear teams found.");
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
        title: `${project.key}: ${project.name}`,
        callback: await this.callback(
          this.onProjectSelected,
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
        content: "Choose which Linear teams you'd like to sync to Plot:",
        links,
      });
    }
  }

  /**
   * Called when user selects a project to sync
   * Initiates the sync process for that project
   */
  async onProjectSelected(args: any, projectId: string, projectName: string) {
    const authToken = await this.get<string>("linear_auth");
    if (!authToken) {
      throw new Error("No Linear auth token found");
    }

    // Track synced projects
    const synced = (await this.get<string[]>("synced_projects")) || [];
    if (!synced.includes(projectId)) {
      synced.push(projectId);
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

    // Start sync (last 30 days)
    await this.tools.linear.startSync(
      authToken,
      projectId,
      this.onIssue,
      { timeMin: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000) },
      projectId
    );
  }

  /**
   * Called for each issue synced from Linear
   * Creates or updates Plot activities based on issue state
   */
  async onIssue(issue: NewActivityWithNotes, projectId: string) {
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

    // Create new activity for new issue (new thread with initial note)
    await this.tools.plot.createActivity(issue);
  }

  /**
   * Called when twist is deactivated
   * Stops all syncs and cleans up state
   */
  async deactivate() {
    // Stop all syncs
    const authToken = await this.get<string>("linear_auth");
    const synced = (await this.get<string[]>("synced_projects")) || [];

    if (authToken) {
      for (const projectId of synced) {
        await this.tools.linear.stopSync(authToken, projectId);
      }
    }

    // Cleanup
    await this.clear("linear_auth");
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
