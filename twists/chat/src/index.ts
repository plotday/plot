import { Type } from "typebox";

import {
  type ActivityLink,
  ActivityLinkType,
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
You can also create tasks, but should only do so when the user explicitly asks you to.
You can provide either or both inline and standalone links. Only use standalone links for key references, such as a website that answers the user's question in detail.`,
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
      response: Type.String({ description: "Response to the user's prompt" }),
      tasks: Type.Optional(
        Type.Array(
          Type.String({
            description: "Description of the task. Can include markdown.",
          }),
          {
            description: "Tasks to create in response to the user's request.",
          }
        )
      ),
      links: Type.Optional(
        Type.Array(
          Type.Object({
            title: Type.String({
              description: "Display text for the link button",
            }),
            url: Type.String({
              description: "Full URL starting with https://",
            }),
          }),
          {
            description: "Key external links to highlight",
          }
        )
      ),
    });

    const response = await this.tools.ai.prompt({
      model: { speed: "balanced", cost: "medium" },
      messages,
      outputSchema: schema,
    });

    // Convert AI links to ActivityLink format
    const activityLinks: ActivityLink[] | null =
      response.output!.links?.map((link) => ({
        type: ActivityLinkType.external,
        title: link.title,
        url: link.url,
      })) || null;

    // Create AI response as a note on the existing activity
    await Promise.all([
      this.tools.plot.createNote({
        activity,
        content: response.output!.response,
        links: activityLinks,
      }),
      ...(response.output!.tasks?.map((task) =>
        this.tools.plot.createNote({
          activity,
          content: task,
          tags: {
            [Tag.Now]: [note.author.id],
          },
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
