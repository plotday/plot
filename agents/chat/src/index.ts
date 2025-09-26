import {
  type Activity,
  ActivityType,
  Agent,
  AuthorType,
  type Tools,
  createAgent,
} from "@plotday/agent";
import type { Ai, LlmMessage } from "@plotday/agent/tools/ai";
import type { Plot } from "@plotday/agent/tools/plot";

export default createAgent(
  class extends Agent {
    private ai: Ai;
    private plot: Plot;

    constructor(tools: Tools) {
      super();
      this.ai = tools.get<Ai>("ai");
      this.plot = tools.get<Plot>("plot");
    }

    async activity(activity: Activity) {
      const previousActivities = await this.plot.getThread(activity);

      if (
        activity.note?.includes("@chat") ||
        previousActivities.some((activity: any) =>
          activity.note.includes("@chat")
        )
      ) {
        const messages: LlmMessage[] = [
          {
            role: "system",
            content: `You are an AI inside of a productivity app. 
Your job is to respond to notes created by the user. 
If a message's role is bot, the message was previously sent by you.
If a question has been answered, don't answer it again.
Add your message to the message attribute.
Add any action items to the array action_items.`,
          },
          ...previousActivities
            .filter((a) => a.note)
            .map(
              (prevActivity) =>
                ({
                  role:
                    prevActivity.author.type === AuthorType.Agent
                      ? "assistant"
                      : "user",
                  content: prevActivity.note!,
                } satisfies LlmMessage)
            ),
        ];

        const schema = {
          type: "object",
          properties: {
            message: {
              type: "object",
              properties: {
                note: {
                  type: "string",
                  description: "response to the user's prompt",
                },
                title: {
                  type: "string",
                  description: "short summary of the main idea of the note",
                },
              },
              required: ["note", "title"],
            },
            action_items: {
              type: "array",
              description:
                "Here you can put individual items of lists or to-dos. This list can be empty if there is no list.",
              items: {
                type: "object",
                properties: {
                  note: {
                    type: "string",
                    description: "description of the action item",
                  },
                  title: {
                    type: "string",
                    description:
                      "short title for the action item, do not use markdown",
                  },
                },
                required: ["note", "title"],
              },
            },
          },
          required: ["message", "action_items"],
        };

        const response = (await this.ai.promptLlm(messages, { schema }))
          .response;

        await Promise.all([
          this.plot.createActivity({
            title: response.message.title,
            note: response.message.note,
            parent: activity,
            priority: activity.priority,
            type: activity.type,
          }),
          ...response.action_items.map((item: any) =>
            this.plot.createActivity({
              title: item.title,
              note: item.note,
              parent: activity,
              priority: activity.priority,
              type: ActivityType.Task,
              start: new Date().toISOString().split("T")[0],
              end: null,
            })
          ),
        ]);
      }
    }
  }
);
