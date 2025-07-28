import { Agent, type Priority } from "@plotday/sdk";
import type { Plot } from "@plotday/tools/plot";

export default class PlotAgent extends Agent {
  async activate(_priority: Pick<Priority, "id">) {
    const plot = this.tools.get<Plot>("plot");
    const onboardingPriority = await plot.createPriority({
      title: "Getting Started",
    });
    await plot.createActivity({
      note: "Welcome to Plot!",
      priorityId: onboardingPriority.id,
    });
  }
}
