import { Type } from "typebox";

import {
  type Activity,
  ActivityType,
  Agent,
  AuthorType,
  Tag,
  type ToolBuilder,
} from "@plotday/agent";
import { AI, type AIMessage } from "@plotday/agent/tools/ai";
import { ActivityAccess, Plot } from "@plotday/agent/tools/plot";

export default class ChatAgent extends Agent<ChatAgent> {
  build(build: ToolBuilder) {
    return {
      ai: build(AI),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Respond,
          intents: {
            "Respond to general questions and requests": this.responsd,
          },
        },
      }),
    };
  }

  async responsd(activity: Activity) {
    const previousActivities = await this.tools.plot.getThread(activity);

    // Add Thinking tag to indicate processing has started
    await this.tools.plot.updateActivity({
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
            } satisfies AIMessage)
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
              })
            ),
            title: Type.String({
              description:
                "Succinct description of the action item (no markdown)",
            }),
          }),
          {
            description: "Tasks to create in response to the user's request.",
          }
        )
      ),
    });

    const response = await this.tools.ai.prompt({
      model: { speed: "balanced", cost: "low" },
      messages,
      outputSchema: schema,
    });

    await Promise.all([
      this.tools.plot.createActivity({
        title: response.output!.message.title,
        note: response.output!.message.note,
        parent: activity,
        priority: activity.priority,
        type: activity.type,
      }),
      ...(response.output!.action_items?.map((item: any) =>
        this.tools.plot.createActivity({
          title: item.title,
          note: item.note,
          parent: activity,
          priority: activity.priority,
          type: ActivityType.Task,
          start: new Date(),
        })
      ) ?? []),
    ]);

    // Remove Thinking tag after response is created
    await this.tools.plot.updateActivity({
      id: activity.id,
      tags: {
        [Tag.Agent]: false,
      },
    });
  }
}
