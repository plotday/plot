import {
  LinkType,
  ActivityType,
  type Priority,
  ThemeColor,
  type ToolBuilder,
  Twist,
} from "@plotday/twister";
import {
  ActivityAccess,
  Plot,
  PriorityAccess,
} from "@plotday/twister/tools/plot";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        activity: {
          access: ActivityAccess.Create,
        },
        priority: {
          access: PriorityAccess.Create,
        },
      }),
    };
  }

  async activate(_priority: Pick<Priority, "id">) {
    const onboardingPriority = await this.tools.plot.createPriority({
      title: "Getting Started",
      key: "@plot.getting-started",
      parent: { key: "@plot" },
      color: ThemeColor.Catalyst, // Color 0 - Green
    });

    if (!onboardingPriority.created) {
      return;
    }

    // Welcome note
    await this.tools.plot.createActivity({
      title: "Welcome to Plot!",
      notes: [
        {
          content: `Plot is a workspace for making progress on what matters most to you. **Priorities**, **Activities**, and **Notes** are the core building blocks of Plot:\n\n
- **Priorities**: These are the roles, goals, and projects in your life; they are the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Activities**: This is what you do to make progress in your priorities. They include what has happened and what's coming next, all laid out on a timeline. More about the types of activities below.
- **Notes**: All activities can have notes, which include private notes, shared messages, and updates from connected apps. Notes give you context on progress for that activity.`,
        },
        {
          content:
            "There are four types of activities you can use to organize your work and capture progress in Plot:\n\n" +
            "- **Note activities**: Use these for meeting notes, research, or documentation. Notes can also sync notifications and comments from connected apps, keeping everything up to date.\n" +
            "- **Message activities**: Special Note activities designed for email threads and chat conversations. Each message becomes a note within the activity for easy reference.\n" +
            "- **Action activities**: Tasks and to-dos. They can be unplanned (Do Someday), current (Do Now), or scheduled into the future (Do Later). Mark them done when complete.\n" +
            "- **Event activities**: Scheduled calendar events. Sync your calendar to see them on your timeline and add notes to any event. Recurring events share their notes across all occurrences.",
        },
        {
          content: `The goal is to keep everything related to your priorities in one place, so you can focus on taking the next action to move things forward. As you use Plot, you'll build a rich history of progress and context that helps you stay aligned with your goals.`,
        },
      ],
      preview: `Plot is a workspace for making progress on what matters most to you. **Priorities**, **Activities**, and **Notes** are the core building blocks of Plot:\n\n
- **Priorities**: These are the roles, goals, and projects in your life; they are the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.
- **Activities**: This is what you do to make progress in your priorities. They include what has happened and what's coming next, all laid out on a timeline. More about the types of activities below.
- **Notes**: All activities can have notes, which include private notes, shared messages, and updates from connected apps. Notes give you context on progress for that activity.`,
      priority: onboardingPriority,
      type: ActivityType.Note,
    });

    // Getting around
    await this.tools.plot.createActivity({
      title: "Getting Around",
      notes: [
        {
          content:
            "Plot's goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.",
        },
        {
          content:
            "**Keyboard Navigation**\n\n" +
            "- **Cmd-K** (Ctrl-K on Windows): Open the command palette (you can see more keyboard shortcuts in here)\n" +
            "- **Up/Down arrows**: Select a note within an activity, then Cmd-K (Ctrl-K) to open commands for that note\n" +
            "- **Cmd-Up/Down** (Ctrl-Up/Down on Windows): Select activities in the activity list\n" +
            "- **Cmd-Shift-Up/Down** (Ctrl-Shift-Up/Down on Windows): Open previous/next activity\n" +
            "- **Cmd-N** (Ctrl-N on Windows): Create a new note (Cmd-Shift-N / Ctrl-Shift-N on web browsers)\n" +
            "- **Cmd-Enter** (Ctrl-Enter on Windows): On the new activity page, create an action instead of a note",
        },
        {
          content:
            "**Touch Gestures**\n\n" +
            "- **Long press** on items to open the menu\n" +
            "- **Swipe right** on activities: start Do Now (or mark done if already doing)\n" +
            "- **Swipe left** on activities: schedule to Do Later",
        },
      ],
      preview: "Keyboard and touch shortcuts",
      priority: onboardingPriority,
      type: ActivityType.Note,
    });

    // Onboarding task
    await this.tools.plot.createActivity({
      title: "Create your initial Priorities",
      notes: [
        {
          content:
            "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy - for example, Work > Projects > Feature X > Planning - that lets you organize at different levels of detail.",
        },
        {
          content:
            "**Viewing a priority shows activities from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your activities across all priorities.",
        },
        {
          content:
            "**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you're not missing anything.",
        },
      ],
      preview:
        "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy - for example, Work > Projects > Feature X > Planning - that lets you organize at different levels of detail.",
      priority: onboardingPriority,
      type: ActivityType.Action,
      start: new Date(),
    });

    // Pick your twists
    await this.tools.plot.createActivity({
      title: "Pick your twists",
      notes: [
        {
          content:
            "**Twists** are ways to bring your work from other apps into Plot, automate workflows, and organize your activities. For example, sync your Google Calendar to see events in Plot, or automatically create tasks from emails. Use the **Twists** button to explore available twists and add them to this priority or any of your other priorities.",
        },
        {
          content:
            "You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can integrate any app or automate any workflow specific to your needs.",
          links: [
            {
              type: LinkType.external,
              title: "Learn more about creating twists",
              url: "https://twist.plot.day",
            },
          ],
        },
      ],
      preview:
        "**Twists** are ways to bring your work from other apps into Plot, automate workflows, and organize your activities. For example, sync your Google Calendar to see events in Plot, or automatically create tasks from emails. Use the **Twists** button to explore available twists and add them to this priority or any of your other priorities.",
      priority: onboardingPriority,
      type: ActivityType.Action,
      start: new Date(),
    });

    // Archive when done
    await this.tools.plot.createActivity({
      title: "Archive this priority",
      notes: [
        {
          content:
            "When you're done with the onboarding activities and no longer need this Getting Started priority, you can **archive it**. Archived priorities and their activities are always available in Plot - they're just hidden from your main view to reduce clutter. You can view and unarchive them anytime if you need to reference them again.",
        },
      ],
      preview:
        "When you're done with the onboarding activities and no longer need this Getting Started priority, you can **archive it**. Archived priorities and their activities are always available in Plot - they're just hidden from your main view to reduce clutter. You can view and unarchive them anytime if you need to reference them again.",
      priority: onboardingPriority,
      type: ActivityType.Action,
      start: new Date(),
    });
  }
}

export default PlotTwist;
