import {
  type Activity,
  ActivityType,
  Agent,
  type Priority,
  type Tools,
  createAgent,
} from "@plotday/sdk";
import { Plot } from "@plotday/sdk/tools/plot";

/**
 * Hello World Agent
 *
 * A minimal agent that creates a welcome activity when activated.
 * This demonstrates the basic structure and lifecycle of a Plot agent.
 */
export default createAgent(
  class extends Agent {
    private plot: Plot;

    constructor(tools: Tools) {
      super();
      // Get the Plot tool for creating/managing activities
      this.plot = tools.get(Plot);
    }

    /**
     * Called when the agent is activated for a priority.
     * Creates a welcome activity to greet the user.
     */
    async activate(priority: Pick<Priority, "id">) {
      await this.plot.createActivity({
        type: ActivityType.Note,
        title: "👋 Welcome to Plot!",
        note: "Your Hello World agent is now active and ready to help organize your activities.",
      });
    }

    /**
     * Called when an activity is routed to this agent.
     * This agent doesn't process activities, but you could add logic here.
     */
    async activity(activity: Activity) {
      console.log("Received activity:", activity.title);
      // Add your activity processing logic here
    }
  }
);
