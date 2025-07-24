import type { Agent, Priority, Activity } from "../";

export default class ChatAgent implements Agent {
  async activate(priority: Priority, config: any = {}) {
    
  }

  async activity(activity: Activity, priority: Priority, config: any = {}) {
    const previousActivities = await priority.getRelatedActivities(activity);

    if (activity.note?.includes("@chat") || previousActivities.some((activity: any) => activity.note.includes("@chat")))
    {
      const messages = [
        {role: "system", content: `You are an AI inside of a productivity app. 
Your job is to respond to notes created by the user. 
If a message's role is bot, the message was previously sent by you.
If a question has been answered, don't answer it again.`},
        ...Object.keys(config).length ? [{role: "system", content: config}] : [],
        ...previousActivities.map((prevActivity: any) => ({ role: prevActivity.created_by.startsWith("ab07ab07") ? "bot" : "user", content: prevActivity.note }))
      ];
      const response = await priority.callAI(messages);
      await priority.createActivity({
        note: response,
        parentId: activity.id,
        priorityId: activity.priorityId
      });
    }     
  }
}