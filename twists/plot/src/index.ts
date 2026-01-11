import {
  ActivityType,
  type Priority,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import {
  ActivityAccess,
  Plot,
  PriorityAccess,
} from "@plotday/twister/tools/plot";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
        priority: {
          access: PriorityAccess.Create,
        },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    const onboardingPriority = await this.tools.plot.createPriority({
      title: "Getting Started",
      parent: { key: "@plot" },
    });

    // Welcome note
    await this.tools.plot.createActivity({
      title: "Welcome to Plot!",
      notes: [
        {
          content: "Plot is your focused workspace for making progress on what matters to you most. We're excited to see what you'll do!",
        },
      ],
      priority: onboardingPriority,
      type: ActivityType.Note,
    });

    // Onboarding task
    await this.tools.plot.createActivity({
      title: "Create your initial Priorities",
      notes: [
        {
          content: "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). Nesting priorities is also helpful, so you can, for example, see everything related to work or zoom right in to a specific work project.",
        },
      ],
      priority: onboardingPriority,
      type: ActivityType.Action,
      start: new Date(),
    });
  }
}

export default PlotTwist;
