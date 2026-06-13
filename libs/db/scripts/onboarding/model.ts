// libs/db/scripts/onboarding/model.ts

/** Per-user initial state for a thread, applied once at signup. */
export interface StateDef {
  /** thread_state.active — true lands the thread in "Doing". Default false. */
  active: boolean;
  /** thread_state.importance — Updates ordering. null ⇒ omit / use function default. */
  importance: number | null;
  /** Days after join for thread_state."on" daterange start. null/0 ⇒ always-on. */
  dateOffset: number | null;
}

/** One note inside a thread. */
export interface NoteDef {
  /** Stable per-thread key. Section heading "## note: <key>". */
  key: string;
  /** Markdown body. */
  content: string;
}

/** One onboarding thread. */
export interface ThreadDef {
  /** Stable cross-user key (frontmatter `key`). */
  key: string;
  /** Sort order derived from the NN- filename prefix. */
  order: number;
  title: string;
  preview: string;
  state: StateDef;
  notes: NoteDef[];
}

export interface OnboardingModel {
  /** Shared global threads, sorted by `order`. */
  global: ThreadDef[];
  /** Per-user threads (currently exactly one: welcome-user). */
  perUser: ThreadDef[];
}
