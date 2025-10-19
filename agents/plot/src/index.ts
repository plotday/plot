import { ActivityType, Agent, type Priority, type Tools } from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

export default class extends Agent {
  private plot: Plot;

  constructor(protected tools: Tools) {
    super(tools);
    this.plot = tools.get(Plot);
  }

  async activate(_priority: Pick<Priority, "id">) {
    const onboardingPriority = await this.plot.createPriority({
      title: "Getting Started",
    });

    // Welcome note
    await this.plot.createActivity({
      title: "Welcome to Plot!",
      note: "Plot is your focused workspace for making progress on what matters to you most. We're excited to see what you'll do!",
      priority: onboardingPriority,
      type: ActivityType.Note,
    });

    // Onboarding task
    await this.plot.createActivity({
      title: "Create your initial Priorities",
      note: "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). Nesting priorities is also helpful, so you can, for example, see everything related to work or zoom right in to a specific work project.",
      priority: onboardingPriority,
      type: ActivityType.Task,
      start: new Date(),
    });
  }
}
