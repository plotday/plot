import {
  ActionType,
  type Actor,
  type Note,
  type Priority,
  Tag,
  ThemeColor,
  type ToolBuilder,
  Twist,
  type Uuid,
} from "@plotday/twister";
import { AI } from "@plotday/twister/tools/ai";
import {
  Plot,
  PriorityAccess,
  ThreadAccess,
} from "@plotday/twister/tools/plot";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Create,
        },
        note: {
          intents: [
            {
              description:
                "Answer questions about content, activities, notes, and links",
              examples: [
                "What did we discuss about the product launch?",
                "Find notes about the marketing budget",
                "Summarize what we know about project X",
              ],
              handler: this.onSearchQuery,
            },
          ],
        },
        priority: {
          access: PriorityAccess.Create,
        },
        search: true,
      }),
      ai: build(AI, { required: false }),
    };
  }

  async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
    const onboardingPriority = await this.tools.plot.createPriority({
      title: "Getting Started",
      key: "@plot.getting-started",
      parent: { key: "@plot" },
      color: ThemeColor.Catalyst, // Color 0 - Green
    });

    if (!onboardingPriority.created) {
      return;
    }

    // Get owner contact for task assignment and per-user schedules.
    // context.actor.id is a user ID, not a contact ID — use getOwner() for the
    // contact ID needed by tag actor references and recompute_outstanding_tasks.
    const owner = context?.actor ? await this.tools.plot.getOwner() : null;
    const todoActors = owner ? [{ id: owner.id }] : [];

    // Compute schedule dates
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    const tomorrowStr = tomorrow.toISOString().slice(0, 10);

    const dayAfterTomorrow = new Date();
    dayAfterTomorrow.setDate(dayAfterTomorrow.getDate() + 2);
    const dayAfterTomorrowStr = dayAfterTomorrow.toISOString().slice(0, 10);

    const twoDaysAfterTomorrow = new Date();
    twoDaysAfterTomorrow.setDate(twoDaysAfterTomorrow.getDate() + 3);
    const twoDaysAfterTomorrowStr = twoDaysAfterTomorrow.toISOString().slice(0, 10);

    // Welcome to Plot!
    const welcomeId = await this.tools.plot.createThread({
      title: "Welcome to Plot!",
      notes: [
        {
          content:
            "Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:\n\n" +
            "- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.\n" +
            "- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages to collaborators, links syncing with external items, and chats with twists. Threads are the core thing you Start, Schedule, and Finish.\n" +
            "- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Individual notes can be marked as tasks and assigned to people.",
        },
        {
          content:
            "When a thread needs your attention, you **Start** it — it could be as simple as reading and thinking, or it could mean taking action. You can also **Schedule** a thread to choose when you want to act on it. Starting and scheduling build your personal agenda — it's not a shared project board, it's your own action plan.\n\n" +
            "When you're done with your part, you **Finish** the thread. This marks any of your tasks in the thread as done and completes linked items in connected apps — for example, closing a Linear ticket. You (and others) might Start and Finish a thread multiple times as work progresses. There's also a separate **Done** tag you can add to mark a thread as complete for good for everyone.",
        },
        {
          content:
            "The **Agenda** is everything you plan to work on — started and scheduled threads, " +
            "arranged in your preferred order. You can reorder items freely, move them to a " +
            "different time or date, or remove them without losing the thread.\n\n" +
            "The **Activity** view shows what's happening across your priorities — new threads, " +
            "updates, and unread items. From Activity, you can add anything to your Agenda by " +
            "Starting (act on it now) or Scheduling (act on it later).\n\n" +
            "A useful pattern: when a meeting or event appears in Activity from a calendar " +
            "connection, tap **Start** to add a planning slot in your Agenda — useful for " +
            "blocking time to prepare or to follow up afterward.",
        },
        {
          content:
            "Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.",
        },
      ],
      preview: "Plot is your workspace for making progress on what matters.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: welcomeId,
        start: "1970-01-01",
        userId: owner.id,
        order: 100,
      });
    }

    // Create your initial Priorities (TO DO)
    const prioritiesId = await this.tools.plot.createThread({
      title: "Create your initial Priorities",
      tags: { [Tag.Todo]: todoActors },
      notes: [
        {
          content:
            "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.",
        },
        {
          content:
            "**Viewing a priority shows threads from it and all descendants.** When you view Work, you see everything under Work (including Projects, Feature X, etc.). When you view Work > Projects > Feature X, you only see that specific area. **Everything** is the special priority that shows all your threads across all priorities.",
        },
        {
          content:
            "**Best practice:** Organize from broad to specific. Example: Work > Marketing Campaign > Content Strategy, or Personal > Home Renovation > Kitchen Planning. Start with top-level contexts (Work, Personal, Family) then add specific projects within each. This allows you to zoom in for focus, and zoom out to make sure you're not missing anything.",
        },
        {
          content:
            "Create your first priority — for example, **Work** or **Personal**. You can always add more or nest them later.",
          tags: { [Tag.Todo]: todoActors },
        },
      ],
      preview:
        "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: prioritiesId,
        start: "1970-01-01",
        userId: owner.id,
        order: 200,
      });
    }

    // Add your Connections (TO DO)
    const connectionsId = await this.tools.plot.createThread({
      title: "Add your Connections",
      tags: { [Tag.Todo]: todoActors },
      notes: [
        {
          content:
            "**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.",
        },
        {
          content:
            "Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Manage connections** command to browse available connections, vote for upcoming ones, and manage which are active.",
        },
        {
          content:
            "Set up your first connection using the **Manage connections** command.",
          tags: { [Tag.Todo]: todoActors },
        },
      ],
      preview:
        "**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: connectionsId,
        start: "1970-01-01",
        userId: owner.id,
        order: 300,
      });
    }

    // Getting Around
    const gettingAroundId = await this.tools.plot.createThread({
      title: "Getting Around",
      notes: [
        {
          content:
            "Plot's goal is to get you to meaningful work as quickly as possible. Here are some tips for navigating efficiently.",
        },
        {
          content:
            "**Keyboard Navigation**\n\n" +
            "- **Cmd+/** (Ctrl+/ on Windows): Search across all your threads and priorities\n" +
            "- **Cmd+K** (Ctrl+K on Windows): Open the command palette for quick actions\n" +
            "- **Up/Down arrows**: Select a note within a thread, then Cmd+K (Ctrl+K) to open commands for that note\n" +
            "- **Cmd+T** (Ctrl+T on Windows): Focus a thread in the agenda list, then Up/Down to navigate and Enter to open the command menu\n" +
            "- **Cmd+Shift+T** (Ctrl+Shift+T on Windows): Focus a thread in the activity list, then Up/Down to navigate and Enter to open the command menu\n" +
            "- **Cmd+Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread\n" +
            "- **Cmd+N** (Ctrl+N on Windows): Create a new note (Cmd+Shift+N / Ctrl+Shift+N on web browsers)\n" +
            "- **Cmd+Enter** (Ctrl+Enter on Windows): On the new thread page, create a task instead of a note",
        },
        {
          content:
            "**Touch Gestures**\n\n" +
            "- **Long press** on items to open the menu\n" +
            "- **Swipe right** on threads: Start (or Finish if already started)\n" +
            "- **Swipe left** on threads: Schedule for later\n" +
            "- **Share** a link from another app to Plot using the share sheet (iOS and Android)",
        },
      ],
      preview: "Keyboard and touch shortcuts",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: gettingAroundId,
        start: "1970-01-01",
        userId: owner.id,
        order: 400,
      });
    }

    // Explore Twists (TO DO)
    const twistsId = await this.tools.plot.createThread({
      title: "Explore Twists",
      tags: { [Tag.Todo]: todoActors },
      notes: [
        {
          content:
            "**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.",
        },
        {
          content:
            "You can also **create your own twists**, either by describing what you want (Plot AI will generate it for you) or by writing code. Custom twists can automate any workflow specific to your needs.",
          actions: [
            {
              type: ActionType.external,
              title: "Learn more about creating twists",
              url: "https://twist.plot.day",
            },
          ],
        },
        {
          content:
            "You can also **@mention Plot** in any thread to ask questions about your notes and links. Plot will search your content and answer using AI.",
        },
        {
          content:
            "Try **@mentioning Plot** in any thread to ask a question about your notes.",
          tags: { [Tag.Todo]: todoActors },
        },
      ],
      preview:
        "**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: twistsId,
        start: tomorrowStr,
        userId: owner.id,
        order: 100,
      });
    }

    // Set up Notifications (TO DO)
    const notificationsId = await this.tools.plot.createThread({
      title: "Set up Notifications",
      tags: { [Tag.Todo]: todoActors },
      notes: [
        {
          content:
            "Plot has smart notifications that are timed based on urgency rather than sending everything immediately. " +
            "This means new messages and updates won't interrupt you the moment they arrive — instead, they're delivered within a timeframe you control. " +
            "If you're used to getting notified immediately for every message, you may want to adjust these defaults.",
        },
        {
          content:
            "Each priority has two timing settings:\n\n" +
            "- **See requests within** (default: 30 minutes) — how quickly you're notified about messages and mentions\n" +
            "- **See updates within** (default: 1 hour) — how quickly you're notified about other changes\n\n" +
            "To adjust, open a priority's command menu and choose **Notifications**, or tap the notification icon on a priority. " +
            "Settings inherit from parent priorities, so you can set timing once at the top level and all children will follow.",
        },
        {
          content:
            "Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. " +
            "You can customize quiet hours per priority in the same Notifications settings.",
        },
        {
          content: "Adjust notification timing for your most important priority.",
          tags: { [Tag.Todo]: todoActors },
        },
      ],
      preview:
        "Plot delivers notifications based on urgency, not instantly. Adjust per-priority timing to match how you work.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: notificationsId,
        start: dayAfterTomorrowStr,
        userId: owner.id,
        order: 100,
      });
    }

    // Clean up without losing anything
    const cleanUpId = await this.tools.plot.createThread({
      title: "Clean up without losing anything",
      notes: [
        {
          content:
            "When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.",
        },
        {
          content:
            "You can archive both **priorities** and **threads**. Use the command menu on any priority or thread to find the archive option. Archiving a priority hides it and all its threads from the main view.",
        },
      ],
      preview:
        "When something is no longer actively in progress — a completed project, an old priority, a finished thread — you can **archive it**. Archived items are hidden from your main view but never deleted. You can view archived items or unarchive them anytime.",
      priority: onboardingPriority,
    });
    if (owner) {
      await this.tools.plot.createSchedule({
        threadId: cleanUpId,
        start: twoDaysAfterTomorrowStr,
        userId: owner.id,
        order: 100,
      });
    }
  }

  async onSearchQuery(note: Note): Promise<void> {
    const query = note.content;
    if (!query?.trim()) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "What would you like to know? Ask me a question about your content.",
      });
      return;
    }

    // Search scoped to the thread's priority (not the twist's root)
    const results = await this.tools.plot.search(query, {
      priorityId: note.thread.priority.id,
    });

    if (results.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "I couldn't find any relevant content. Try rephrasing or being more specific.",
      });
      return;
    }

    const currentThreadId = note.thread.id;
    const otherResults = results.filter((r) => r.thread.id !== currentThreadId);

    // Prefer threads with link results (original sources) over note-only
    // matches, which are often user questions from previous Q&A threads
    const linkThreadIds = new Set(
      otherResults.filter((r) => r.type === "link").map((r) => r.thread.id)
    );
    const noteOnlyThreadIds = new Set(
      otherResults
        .filter((r) => r.type === "note" && !linkThreadIds.has(r.thread.id))
        .map((r) => r.thread.id)
    );
    const actions = [...linkThreadIds, ...noteOnlyThreadIds]
      .slice(0, 3)
      .map((threadId) => ({
        type: ActionType.thread as const,
        threadId: threadId as Uuid,
      }));

    // Check AI availability before attempting summarization
    const { prompt: canPrompt } = this.tools.ai.available();

    if (canPrompt) {
      // Build RAG context
      const context = results
        .map((r, i) => {
          const location = [r.priority.title, r.thread.title]
            .filter(Boolean)
            .join(" > ");
          const body =
            r.type === "link"
              ? `[${r.title}](${r.sourceUrl || ""})${
                  r.content ? "\n" + r.content : ""
                }`
              : r.content || "(no content)";
          return `[${i + 1}] ${location}\n${body}`;
        })
        .join("\n\n");

      const response = await this.tools.ai.prompt({
        model: { speed: "fast", cost: "medium" },
        system:
          "You answer questions using the user's own notes and links as context. " +
          'Answer directly — don\'t say things like "based on the provided content" or ' +
          '"according to your notes". Just give the answer naturally, as if you know it. ' +
          "If the context doesn't fully answer the question, say what you found and note " +
          "what's missing. Be concise. Reference specific threads when relevant.",
        prompt: `Question: ${query}\n\nRelevant content:\n${context}`,
      });

      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: response.text,
        actions: actions.length > 0 ? actions : undefined,
      });
    } else {
      // AI unavailable — show thread titles with upsell
      const seen = new Set<string>();
      const threadList = otherResults
        .filter((r) => {
          if (seen.has(r.thread.id)) return false;
          seen.add(r.thread.id);
          return true;
        })
        .slice(0, 5)
        .map((r) => `- ${r.thread.title || "(untitled)"}`)
        .join("\n");

      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: `I found these threads that might help:\n\n${threadList}\n\n*Upgrade or add an API key in settings for AI-generated answers.*`,
        actions: actions.length > 0 ? actions : undefined,
      });
    }
  }
}

export default PlotTwist;
