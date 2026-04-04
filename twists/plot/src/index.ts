import {
  type Action,
  ActionType,
  type Actor,
  type Note,
  type PlanOperation,
  type Priority,
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
import { Type } from "typebox";

class PlotTwist extends Twist<PlotTwist> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: {
          access: ThreadAccess.Full,
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
            {
              description:
                "Organize, move, archive, or rename threads and priorities",
              examples: [
                "Move all threads about project X into the Project X priority",
                "Archive all done threads in this priority",
                "Create a new priority called Q2 Planning and move relevant threads there",
              ],
              handler: this.onOrganizeQuery,
            },
          ],
        },
        priority: {
          access: PriorityAccess.Full,
        },
        search: true,
        requireApproval: true,
      }),
      ai: build(AI, { required: false }),
    };
  }

  async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
    // Look up the Plot App priority (created by DB migration/setup function)
    const plotApp = await this.tools.plot.createPriority({
      title: "Plot App",
      key: "@plot.app",
    });

    // If the priority was just created (first user), we don't have onboarding
    // threads yet — they'll be created by the data migration or staff.
    if (plotApp.created) {
      return;
    }

    // Get owner contact for per-user schedules
    const owner = context?.actor ? await this.tools.plot.getOwner() : null;
    if (!owner) return;

    // Get threads in the Plot App priority
    const threads = await this.tools.plot.getThreads({
      priorityId: plotApp.id,
      includeDescendants: false,
      limit: 20,
    });

    // Compute staggered schedule dates
    const today = new Date();
    const dates = [0, 0, 0, 0, 1, 2, 3].map((offset) => {
      const d = new Date(today);
      d.setDate(d.getDate() + offset);
      return d.toISOString().slice(0, 10);
    });

    // Define expected onboarding thread titles and their schedule order
    const onboardingOrder = [
      { title: "Welcome to Plot!", date: dates[0], order: 100 },
      { title: "Create your initial Priorities", date: dates[1], order: 200 },
      { title: "Add your Connections", date: dates[2], order: 300 },
      { title: "Getting Around", date: dates[3], order: 400 },
      { title: "Explore Twists", date: dates[4], order: 100 },
      { title: "Set up Notifications", date: dates[5], order: 100 },
      { title: "Clean up without losing anything", date: dates[6], order: 100 },
    ];

    // Match threads by title and add to agenda
    for (const config of onboardingOrder) {
      const thread = threads.find((t) => t.title === config.title);
      if (thread) {
        try {
          await this.tools.plot.createSchedule({
            threadId: thread.id,
            start: config.date === dates[0] ? "1970-01-01" : config.date,
            userId: owner.id,
            order: config.order,
          });
        } catch {
          // Schedule may already exist — ignore
        }
      }
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

  async onOrganizeQuery(note: Note): Promise<void> {
    const query = note.content;
    if (!query?.trim()) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "What would you like me to organize? For example:\n\n" +
          '- "Move all threads about project X into the Project X priority"\n' +
          '- "Archive all done threads in this priority"\n' +
          '- "Create a new priority called Q2 Planning and move relevant threads there"',
      });
      return;
    }

    const { prompt: canPrompt } = this.tools.ai.available();
    if (!canPrompt) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "Organizing content requires AI. Please enable AI in your settings or add an API key.",
      });
      return;
    }

    // Gather context: threads, priorities, and search results in parallel
    const [threads, priorities, searchResults] = await Promise.all([
      this.tools.plot.getThreads({
        priorityId: note.thread.priority.id,
        limit: 200,
      }),
      this.tools.plot.getPriorities({ includeDescendants: true }),
      this.tools.plot.search(query, {
        priorityId: note.thread.priority.id,
        limit: 30,
      }),
    ]);

    if (threads.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content: "There are no threads in this priority to organize.",
      });
      return;
    }

    // Serialize context for the AI
    const threadsContext = threads
      .map(
        (t) =>
          `${t.id} | ${t.title} | Priority: ${t.priority.title} (${t.priority.id}) | Archived: ${t.archived ? "yes" : "no"}`
      )
      .join("\n");

    const prioritiesContext = priorities
      .map((p) => `${p.id} | ${p.title}`)
      .join("\n");

    const searchContext =
      searchResults.length > 0
        ? searchResults
            .map((r) => `- [${r.thread.title}] (thread ${r.thread.id})`)
            .join("\n")
        : "(no search results)";

    // Use AI to generate plan operations
    const operationsSchema = Type.Array(
      Type.Union([
        Type.Object({
          type: Type.Literal("updateThread"),
          threadId: Type.String(),
          threadTitle: Type.String(),
          changes: Type.Object({
            archived: Type.Optional(Type.Boolean()),
            title: Type.Optional(Type.String()),
            type: Type.Optional(Type.String()),
            priority: Type.Optional(
              Type.Object({ id: Type.String(), title: Type.String() })
            ),
          }),
        }),
        Type.Object({
          type: Type.Literal("createThread"),
          title: Type.String(),
          priorityId: Type.String(),
          priorityTitle: Type.String(),
        }),
        Type.Object({
          type: Type.Literal("createNote"),
          threadId: Type.String(),
          threadTitle: Type.String(),
          content: Type.String(),
        }),
        Type.Object({
          type: Type.Literal("updatePriority"),
          priorityId: Type.String(),
          priorityTitle: Type.String(),
          changes: Type.Object({
            title: Type.Optional(Type.String()),
            archived: Type.Optional(Type.Boolean()),
            parent: Type.Optional(
              Type.Object({ id: Type.String(), title: Type.String() })
            ),
          }),
        }),
        // Signal to create a new priority before executing the plan
        Type.Object({
          type: Type.Literal("_createPriority"),
          title: Type.String(),
          parentId: Type.String(),
          parentTitle: Type.String(),
        }),
      ])
    );

    const response = await this.tools.ai.prompt({
      model: { speed: "balanced", cost: "medium" },
      system:
        "You are an organizational assistant for a workspace. The user wants to reorganize their content.\n\n" +
        "Given the user's request and the available data, produce a JSON array of operations.\n\n" +
        "Available operation types:\n" +
        '- updateThread: Change a thread\'s title, archived status, or move it to a different priority. Use changes.priority with {id, title} to move. Set changes.archived to true to archive.\n' +
        "- createThread: Create a new thread in a specific priority.\n" +
        "- createNote: Add a note to an existing thread.\n" +
        "- updatePriority: Rename a priority, archive it, or move it under a different parent.\n" +
        '- _createPriority: Signal that a new priority should be created. Use this when the user asks to move threads to a priority that doesn\'t exist yet. Include parentId/parentTitle for where to create it.\n\n' +
        "Rules:\n" +
        "- Only reference thread IDs and priority IDs from the provided data (except for _createPriority).\n" +
        "- Include the current title in threadTitle/priorityTitle fields for display purposes.\n" +
        "- Be conservative: only include operations that clearly match the user's request.\n" +
        "- Tag changes are not supported. If the user asks about tags, return an empty array.\n" +
        "- Only active (non-archived) threads are included in the list below. Already-archived threads cannot be targeted.\n" +
        "- Return an empty array if the request doesn't match any actionable operations.",
      prompt:
        `Request: ${query}\n\n` +
        `Threads (${threads.length}):\n${threadsContext}\n\n` +
        `Priorities (${priorities.length}):\n${prioritiesContext}\n\n` +
        `Search results for "${query}":\n${searchContext}`,
      outputSchema: operationsSchema,
    });

    const aiOperations = response.output;
    if (!aiOperations || aiOperations.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "I couldn't determine any operations to perform for that request. Try being more specific about what you'd like to organize.",
      });
      return;
    }

    // Build lookup sets for validation (use string sets since AI outputs plain strings)
    const threadIds = new Set<string>(threads.map((t) => t.id));
    const priorityIds = new Set<string>(priorities.map((p) => p.id));

    // Handle _createPriority signals: create priorities eagerly, then map them
    const newPriorityMap = new Map<string, Priority>();
    for (const op of aiOperations) {
      if (op.type === "_createPriority") {
        if (!priorityIds.has(op.parentId)) continue;
        const created = await this.tools.plot.createPriority({
          title: op.title,
          parent: { id: op.parentId as Uuid },
        });
        newPriorityMap.set(op.title.toLowerCase(), created);
        priorityIds.add(created.id);
      }
    }

    // Filter to valid PlanOperations and validate IDs
    const validOperations: PlanOperation[] = [];
    for (const op of aiOperations) {
      if (op.type === "_createPriority") continue;

      if (op.type === "updateThread") {
        if (!threadIds.has(op.threadId)) continue;
        if (op.changes.priority) {
          // Check if this references a newly created priority by title
          const newPriority = newPriorityMap.get(
            op.changes.priority.title.toLowerCase()
          );
          if (newPriority) {
            op.changes.priority = { id: newPriority.id, title: newPriority.title };
          } else if (!priorityIds.has(op.changes.priority.id)) {
            continue;
          }
        }
        validOperations.push(op as PlanOperation);
      } else if (op.type === "createThread") {
        const newPriority = newPriorityMap.get(
          op.priorityTitle.toLowerCase()
        );
        if (newPriority) {
          op.priorityId = newPriority.id;
          op.priorityTitle = newPriority.title;
        } else if (!priorityIds.has(op.priorityId)) {
          continue;
        }
        validOperations.push(op as PlanOperation);
      } else if (op.type === "createNote") {
        if (!threadIds.has(op.threadId)) continue;
        validOperations.push(op as PlanOperation);
      } else if (op.type === "updatePriority") {
        if (!priorityIds.has(op.priorityId)) continue;
        if (op.changes.parent && !priorityIds.has(op.changes.parent.id)) {
          continue;
        }
        validOperations.push(op as PlanOperation);
      }
    }

    if (validOperations.length === 0) {
      await this.tools.plot.createNote({
        thread: { id: note.thread.id },
        content:
          "I couldn't find any matching content to act on. Try being more specific about which threads or priorities you'd like to organize.",
      });
      return;
    }

    // Cap at 50 operations
    const operations = validOperations.slice(0, 50);

    // Build human-readable summary
    const summary = operations
      .map((op) => {
        switch (op.type) {
          case "updateThread":
            if (op.changes.priority)
              return `- Move **${op.threadTitle}** to **${op.changes.priority.title}**`;
            if (op.changes.archived)
              return `- Archive **${op.threadTitle}**`;
            if (op.changes.title)
              return `- Rename **${op.threadTitle}** to **${op.changes.title}**`;
            return `- Update **${op.threadTitle}**`;
          case "createThread":
            return `- Create thread **${op.title}** in **${op.priorityTitle}**`;
          case "createNote":
            return `- Add note to **${op.threadTitle}**`;
          case "updatePriority":
            if (op.changes.parent)
              return `- Move priority **${op.priorityTitle}** under **${op.changes.parent.title}**`;
            if (op.changes.archived)
              return `- Archive priority **${op.priorityTitle}**`;
            if (op.changes.title)
              return `- Rename priority **${op.priorityTitle}** to **${op.changes.title}**`;
            return `- Update priority **${op.priorityTitle}**`;
          default:
            return `- Unknown operation`;
        }
      })
      .join("\n");

    const cb = await this.actionCallback(
      this.onPlanResponse,
      note.thread.id as string
    );
    const planAction = this.tools.plot.createPlan({
      title: `Organize: ${query.slice(0, 80)}`,
      operations,
      callback: cb,
    });

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Here's my plan (${operations.length} operation${operations.length === 1 ? "" : "s"}):\n\n${summary}`,
      actions: [planAction],
    });
  }

  async onPlanResponse(
    _action: Action,
    threadId: string
  ): Promise<void> {
    // The API executes operations on approval and calls back with the action.
    // We just post a confirmation note in the original thread.
    await this.tools.plot.createNote({
      thread: { id: threadId as Uuid },
      content: "Done! The plan has been executed.",
    });
  }
}

export default PlotTwist;
