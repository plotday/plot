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
import {
  Plot,
  PriorityAccess,
  ThreadAccess,
} from "@plotday/twister/tools/plot";
import { AI } from "@plotday/twister/tools/ai";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Create,
        },
        note: {
          intents: [{
            description: "Answer questions about content, activities, notes, and links",
            examples: [
              "What did we discuss about the product launch?",
              "Find notes about the marketing budget",
              "Summarize what we know about project X",
            ],
            handler: this.onSearchQuery,
          }],
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
    const todoActors = context?.actor ? [{ id: context.actor.id }] : [];

    const onboardingPriority = await this.tools.plot.createPriority({
      title: "Getting Started",
      key: "@plot.getting-started",
      parent: { key: "@plot" },
      color: ThemeColor.Catalyst, // Color 0 - Green
    });

    if (!onboardingPriority.created) {
      return;
    }

    // Welcome to Plot!
    await this.tools.plot.createThread({
      title: "Welcome to Plot!",
      notes: [
        {
          content:
            "Plot is your workspace for making progress on what matters most. **Priorities**, **Threads**, and **Notes** are the core building blocks of Plot:\n\n" +
            "- **Priorities**: The roles, goals, and projects in your life — the areas you direct your focus and energy toward. Examples include Work, Personal, Launch New Product, Team Leader, and Learn French.\n" +
            '- **Threads**: Everything related to something you work on, collected in one place. A thread can contain notes, messages, links syncing with external items, and chats with twists. Threads are the core thing you mark "to do" and schedule.\n' +
            "- **Notes**: The content within threads. Notes can be personal notes, messages to others, or synced comments with connected apps. Notes can become tasks and can be assigned to multiple people.",
        },
        {
          content:
            'Marking a thread "to do" means you need to do something with it — it could be as simple as reading and thinking, or it could mean taking action. Think of it like starring items in your inbox. Both "to do" and scheduling are personal to you — others in the same priority won\'t see your to-do list. You can also schedule threads so you deal with them at the right time.',
        },
        {
          content:
            "Threads can contain links to items in external services — documents, calendar events, web pages, issues, and more. These are created by connections (more on that later). Links keep everything related to your work in one place, so you always have the context you need.",
        },
      ],
      preview: "Plot is your workspace for making progress on what matters.",
      priority: onboardingPriority,
    });

    // Create your initial Priorities (TO DO)
    await this.tools.plot.createThread({
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
      ],
      preview:
        "Priorities are contexts for focus and often correspond to roles (like VP Marketing and Parent) and goals (like Launch New Product and Run a Marathon). **Nesting priorities** creates a hierarchy — for example, Work > Projects > Feature X > Planning — that lets you organize at different levels of detail.",
      priority: onboardingPriority,
    });

    // Add your Connections (TO DO)
    await this.tools.plot.createThread({
      title: "Add your Connections",
      tags: { [Tag.Todo]: todoActors },
      notes: [
        {
          content:
            "**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.",
        },
        {
          content:
            "Each connection has channels you can enable or disable, letting you control exactly what syncs. Use the **Connections** command in settings to browse available connections and manage which ones are active.",
        },
      ],
      preview:
        "**Connections** sync items from your other apps and services into Plot, often two-way. For example, connect your calendar to see events as threads, or connect your email to bring in conversations. You can view and interact with items right from Plot — see and add comments on documents, respond to messages, update issues — the goal is to bring everything into one place.",
      priority: onboardingPriority,
    });

    // Explore Twists (TO DO)
    await this.tools.plot.createThread({
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
      ],
      preview:
        "**Twists** are automations, workflows, and agents that do helpful things with your threads — often working with items from your connections. For example, a twist might triage your inbox, summarize meeting notes, or create follow-up tasks from action items.",
      priority: onboardingPriority,
    });

    // Getting Around
    await this.tools.plot.createThread({
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
            "- **Swipe right** on threads: mark To Do (or mark done if already doing)\n" +
            "- **Swipe left** on threads: schedule to do later",
        },
      ],
      preview: "Keyboard and touch shortcuts",
      priority: onboardingPriority,
    });

    // Clean up without losing anything
    await this.tools.plot.createThread({
      title: "Clean up without losing anything",
      notes: [
        {
          content:
            "When you're done with the Getting Started threads and no longer need this priority, you can **archive it**. Archived priorities and their threads are always available in Plot — they're just hidden from your main view to reduce clutter. You can view and unarchive them anytime if you need to reference them again.",
        },
        {
          content: "Archive the Getting Started priority",
          tags: { [Tag.Todo]: todoActors },
        },
      ],
      preview:
        "When you're done with the Getting Started threads and no longer need this priority, you can **archive it**. Archived priorities and their threads are always available in Plot — they're just hidden from your main view to reduce clutter. You can view and unarchive them anytime if you need to reference them again.",
      priority: onboardingPriority,
    });
  }

  async onSearchQuery(note: Note): Promise<void> {
    const query = note.content;
    if (!query?.trim()) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: "What would you like to know? Ask me a question about your content.",
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
        content: "I couldn't find any relevant content. Try rephrasing or being more specific.",
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
      const context = results.map((r, i) => {
        const location = [r.priority.title, r.thread.title].filter(Boolean).join(" > ");
        const body = r.type === "link"
          ? `[${r.title}](${r.sourceUrl || ""})${r.content ? "\n" + r.content : ""}`
          : r.content || "(no content)";
        return `[${i + 1}] ${location}\n${body}`;
      }).join("\n\n");

      const response = await this.tools.ai.prompt({
        model: { speed: "fast", cost: "medium" },
        system: "You answer questions using the user's own notes and links as context. " +
          "Answer directly — don't say things like \"based on the provided content\" or " +
          "\"according to your notes\". Just give the answer naturally, as if you know it. " +
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
      // AI unavailable — show results directly
      const resultsList = results.slice(0, 5).map(r => {
        const location = [r.priority.title, r.thread.title].filter(Boolean).join(" > ");
        return `- **${location}**: ${r.content?.substring(0, 200) || "(no content)"}`;
      }).join("\n");

      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: `Here's what I found:\n\n${resultsList}`,
        actions: actions.length > 0 ? actions : undefined,
      });
    }
  }
}

export default PlotTwist;
