import {
  ActivityType,
  Agent,
  type Priority,
  type Tools,
  createAgent,
} from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

class PlotAgent extends Agent {
  private plot: Plot;

  constructor(protected tools: Tools) {
    super();
    this.plot = tools.get(Plot);
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

export default createAgent(PlotAgent);
