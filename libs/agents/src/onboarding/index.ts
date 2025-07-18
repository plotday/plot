import type { Agent, Priority, Activity } from "../";

export default class OnboardingAgent implements Agent {
  async activate(priority: Priority, config: any = {}) {
    await priority.createActivity({
      note: "Welcome to Plot!",
    });
  }

  async activity(activity: Activity, priority: Priority, config: any = {}) {
    
  }
}