import {
  type Activity,
  ActivityType,
  Agent,
  AuthorType,
  Tag,
  Tools,
} from "@plotday/sdk";
import { AI, AIModel, type AIMessage } from "@plotday/sdk/tools/ai";
import { Plot } from "@plotday/sdk/tools/plot";
import { Type } from "typebox";

export default class extends Agent {
  private ai: AI;
  private plot: Plot;

  constructor(protected tools: Tools) {
    super();
    this.ai = tools.get(AI);
    this.plot = tools.get(Plot);
  }

  async activity(
    activity: Activity,
    changes?: {
      previous: Activity;
      tagsAdded: Record<number, string[]>;
      tagsRemoved: Record<number, string[]>;
    },
  ) {
    if (changes) return;

    const previousActivities = await this.plot.getThread(activity);

    if (
      activity.note?.includes("@chat") ||
      previousActivities.some((activity: any) =>
        activity.note.includes("@chat"),
      )
    ) {
      // Add Thinking tag to indicate processing has started
      await this.plot.updateActivity({
        id: activity.id,
        tags: {
          [Tag.Agent]: true,
        },
      });

      const messages: AIMessage[] = [
        {
          role: "system",
          content: `You are an AI assistant inside of a productivity app. 
You respond helpfully to user requests.
You can also create tasks, but should only do so when the user explicitly asks you to.`,
        },
        ...previousActivities
          .filter((a) => a.note ?? a.title)
          .map(
            (prevActivity) =>
              ({
                role:
                  prevActivity.author.type === AuthorType.Agent
                    ? "assistant"
                    : "user",
                content: (prevActivity.note ?? prevActivity.title)!,
              }) satisfies AIMessage,
          ),
      ];

      const schema = Type.Object({
        message: Type.Object({
          note: Type.String({ description: "Response to the user's prompt" }),
          title: Type.String({
            description: "Short title for the response notee",
          }),
        }),
        action_items: Type.Optional(
          Type.Array(
            Type.Object({
              note: Type.Optional(
                Type.String({
                  description:
                    "Optional detailed description of the action item. Can include markdown. Only add when important details are needed beyond the title.",
                }),
              ),
              title: Type.String({
                description:
                  "Succinct description of the action item (no markdown)",
              }),
            }),
            {
              description: "Tasks to create in response to the user's request.",
            },
          ),
        ),
      });

      const response = await this.ai.prompt({
        model: AIModel.LLAMA_33_70B,
        messages,
        outputSchema: schema,
      });

      await Promise.all([
        this.plot.createActivity({
          title: response.output!.message.title,
          note: response.output!.message.note,
          parent: activity,
          priority: activity.priority,
          type: activity.type,
        }),
        ...(response.output!.action_items?.map((item: any) =>
          this.plot.createActivity({
            title: item.title,
            note: item.note,
            parent: activity,
            priority: activity.priority,
            type: ActivityType.Task,
            start: new Date(),
          }),
        ) ?? []),
      ]);

      // Remove Thinking tag after response is created
      await this.plot.updateActivity({
        id: activity.id,
        tags: {
          [Tag.Agent]: false,
        },
      });
    }
  }
}
