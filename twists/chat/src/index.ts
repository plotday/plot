import { Type } from "typebox";

import {
  ActivityType,
  ActorType,
  type Note,
  Tag,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { AI, type AIMessage } from "@plotday/twister/tools/ai";
import { ActivityAccess, Plot } from "@plotday/twister/tools/plot";

export default class ChatTwist extends Twist<ChatTwist> {
  build(build: ToolBuilder) {
    return {
      ai: build(AI),
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Respond,
        },
        note: {
          intents: [
            {
              description: "Respond to general questions and requests",
              examples: [
                "What's the weather like?",
                "Can you help me plan my day?",
                "Write me a summary of this article",
              ],
              handler: this.respond,
            },
          ],
        },
      }),
    };
  }

  async respond(note: Note) {
    const activity = note.activity;

    // Get all notes in this activity (conversation history)
    const previousNotes = await this.tools.plot.getNotes(activity);

    // Add Thinking tag to indicate processing has started
    await this.tools.plot.updateActivity({
      id: activity.id,
      twistTags: {
        [Tag.Twist]: true,
      },
    });

    const messages: AIMessage[] = [
      {
        role: "system",
        content: `You are an AI assistant inside of a productivity app.
You respond helpfully to user requests.
You can also create tasks, but should only do so when the user explicitly asks you to.`,
      },
      // Include activity title as context
      ...(activity.title
        ? [
            {
              role: "user" as const,
              content: activity.title,
            },
          ]
        : []),
      // Include all previous notes in the conversation
      ...previousNotes
        .filter((n: Note) => n.content)
        .map(
          (prevNote: Note) =>
            ({
              role:
                prevNote.author.type === ActorType.Twist ? "assistant" : "user",
              content: prevNote.content!,
            } satisfies AIMessage)
        ),
    ];

    const schema = Type.Object({
      message: Type.Object({
        note: Type.String({ description: "Response to the user's prompt" }),
        title: Type.String({
          description: "Short title for the response note",
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
      model: { speed: "balanced", cost: "medium" },
      messages,
      outputSchema: schema,
    });

    type ActionItem = {
      title: string;
      note?: string;
    };

    // Note: For now, creating activities without parent relationship
    // Once Note API is available, responses should become Notes
    await Promise.all([
      this.tools.plot.createActivity({
        title: response.output!.message.title,
        notes: [
          {
            content: response.output!.message.note,
          },
        ],
        priority: activity.priority,
        type: activity.type,
      }),
      ...(response.output!.action_items?.map((item: ActionItem) =>
        this.tools.plot.createActivity({
          title: item.title,
          notes: item.note
            ? [
                {
                  content: item.note,
                },
              ]
            : undefined,
          priority: activity.priority,
          type: ActivityType.Action,
          start: new Date(),
        })
      ) ?? []),
    ]);

    // Remove Thinking tag after response is created
    await this.tools.plot.updateActivity({
      id: activity.id,
      twistTags: {
        [Tag.Twist]: false,
      },
    });
  }
}
