import type { Agent, Priority } from "../";

export default class OnboardingAgent implements Agent {
  async activate(priority: Priority) {
    await priority.createActivity({
      note: "Welcome to Plot!",
    });
  }
}