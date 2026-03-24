import { Type } from "typebox";

import {
  type Action,
  ActionType,
  ActorType,
  type Note,
  Tag,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import { Options } from "@plotday/twister/options";
import { AI, type AIMessage, AIModel } from "@plotday/twister/tools/ai";
import { ThreadAccess, Plot } from "@plotday/twister/tools/plot";

export default class ChatGPTTwist extends Twist<ChatGPTTwist> {
  build(build: ToolBuilder) {
    return {
      options: build(Options, {
        model: {
          type: "select" as const,
          label: "AI Model",
          description: "The AI model used for chat responses",
          choices: [
            { value: "openai/gpt-5", label: "GPT-5" },
            { value: "openai/gpt-5-mini", label: "GPT-5 Mini (Fast)" },
          ],
          default: "openai/gpt-5",
        },
      }),
      ai: build(AI),
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Respond,
        },
        note: {
          defaultMention: true,
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
    const thread = note.thread;

    // Get all notes in this thread (conversation history)
    const previousNotes = await this.tools.plot.getNotes(thread);

    // Add Thinking tag to indicate processing has started
    await this.tools.plot.updateThread({
      id: thread.id,
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
You can provide either or both inline and standalone links. Only use standalone links for key references, such as a website that answers the user's question in detail.
When writing code blocks, always specify the language (e.g. \`\`\`python, \`\`\`typescript).
You can use markdown tables when presenting structured or comparative data.`,
      },
      // Include thread title as context
      ...(thread.title
        ? [
            {
              role: "user" as const,
              content: thread.title,
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
      model: { speed: "balanced", cost: "medium", hint: this.tools.options.model as AIModel },
      messages,
      outputSchema: schema,
    });

    // Convert AI links to Action format
    const threadActions: Action[] | null =
      response.output!.links?.map((link) => ({
        type: ActionType.external,
        title: link.title,
        url: link.url,
      })) || null;

    // Create AI response as a note on the existing thread
    await Promise.all([
      this.tools.plot.createNote({
        thread,
        content: response.output!.response,
        actions: threadActions,
      }),
      ...(response.output!.tasks?.map((task) =>
        this.tools.plot.createNote({
          thread,
          content: task,
          tags: {
            [Tag.Todo]: [{ id: note.author.id }],
          },
        })
      ) ?? []),
    ]);

    // Remove Thinking tag after response is created
    await this.tools.plot.updateThread({
      id: thread.id,
      twistTags: {
        [Tag.Twist]: false,
      },
    });
  }
}
