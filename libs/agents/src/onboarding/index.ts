import type { Agent, Priority, Activity } from "../";

export default class OnboardingAgent implements Agent {
  async activate(priority: Priority, config: any = {}) {
    const onboardingPriority = await priority.createPriority({
      title: "Getting Started"
    });
    
    await priority.createActivity({
      note: "Welcome to Plot!",
      priorityId: onboardingPriority.id
    });
  }

  async activity(activity: Activity, priority: Priority, config: any = {}) {
    
  }
}
