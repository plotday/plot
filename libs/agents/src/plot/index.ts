import type { Activity, Agent, Plot } from "../";

export default class PlotAgent implements Agent {
  async activate(plot: Plot, _config: any = {}) {
    const onboardingPriority = await plot.createPriority({
      title: "Getting Started",
    });

    await plot.createActivity({
      note: "Welcome to Plot!",
      priorityId: onboardingPriority.id,
    });
  }

  async activity(_plot: Plot, _config: any = {}, _activity: Activity) {}
}
