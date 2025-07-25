import type { Activity, Agent, Priority } from "../";

export default class PlotAgent implements Agent {
  async activate(priority: Priority, _config: any = {}) {
    const onboardingPriority = await priority.createPriority({
      title: "Getting Started",
    });

    await priority.createActivity({
      note: "Welcome to Plot!",
      priorityId: onboardingPriority.id,
    });
  }

  async activity(_activity: Activity, _priority: Priority, _config: any = {}) {}
}
