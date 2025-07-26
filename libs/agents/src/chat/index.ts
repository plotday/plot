import type { Activity, Agent, LlmMessage, Plot } from "../";

export default class ChatAgent implements Agent {
  async activate(_plot: Plot) {}

  async activity(plot: Plot, activity: Activity) {
    const previousActivities = await plot.getRelatedActivities(activity);

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
                role: prevActivity.createdBy.startsWith("ab07ab07")
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

      const response = (await plot.promptLlm(messages, { schema })).response;

      await Promise.all([
        plot.createActivity({
          title: response.message.title,
          note: response.message.note,
          parentId: activity.id,
          priorityId: activity.priorityId,
        }),
        ...response.action_items.map((item: any) =>
          plot.createActivity({
            title: item.title,
            note: item.note,
            parentId: activity.id,
            priorityId: activity.priorityId,
            doAt: new Date().toISOString().split("T")[0],
          })
        ),
      ]);
    }
  }
}
