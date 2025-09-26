import {
  ActivityType,
  Agent,
  type Priority,
  type Tools,
  createAgent,
} from "@plotday/agent";
import type { Plot } from "@plotday/agent/tools/plot";

export default createAgent(
  class extends Agent {
    private plot: Plot;

    constructor(protected tools: Tools) {
      super();
      this.plot = tools.get<Plot>("plot");
    }

    async activate(_priority: Pick<Priority, "id">) {
      const onboardingPriority = await this.plot.createPriority({
        title: "Getting Started",
      });
      await this.plot.createActivity({
        note: "Welcome to Plot!",
        priority: onboardingPriority,
        type: ActivityType.Note,
      });
    }
  }
);
