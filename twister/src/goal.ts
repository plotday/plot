/**
 * @fileoverview
 * Goal entity types.
 *
 * Goals are per-user, cross-cutting intentions — "ship the feature by
 * Friday", "3 hours a week on leads" — that Plot uses to shape each day's
 * priorities. They are structured agent memory, readable and writable by
 * twists with the `Plot.Options.goals` permission and read server-side by
 * Plot's day-planning pipeline. Goals are strictly per-user; there is no
 * sharing.
 *
 * Types follow the Twister entity standard: required fields plain, nullable
 * fields `| null` (never optional), and New* / Update* types use `Partial<>`
 * so omitted (`undefined`) fields are distinguishable from explicitly
 * cleared (`null`) ones.
 */

/**
 * Lifecycle status of a goal.
 * - `active`: live; shapes day planning.
 * - `completed`: achieved.
 * - `dropped`: cancelled by the user, kept for memory ("cancel my goal
 *   to…" sets this — goals are never hard-deleted).
 */
export type GoalStatus = "active" | "completed" | "dropped";

/**
 * Recurring effort budget for a goal, e.g. "3 hours a week on leads" →
 * `{ hours: 3, per: "week" }`.
 */
export type GoalCadence = {
  /** Hours of effort per period. */
  hours: number;
  /** The period the hours apply to. */
  per: "day" | "week" | "month";
};

/**
 * A per-user goal.
 */
export type Goal = {
  /** Unique identifier for the goal */
  id: string;
  /** Short imperative, e.g. "Ship the Today feature" */
  title: string;
  /** Freeform elaboration / agent notes */
  details: string | null;
  /** Lifecycle status */
  status: GoalStatus;
  /** Deadline intent as an ISO date (YYYY-MM-DD): "by end of week" */
  targetDate: string | null;
  /** Planned work day as an ISO date (YYYY-MM-DD): "I'll work on it Friday" */
  scheduledOn: string | null;
  /** Recurring effort budget */
  cadence: GoalCadence | null;
  /** Linked focus id, or null when the goal isn't tied to a focus */
  focusId: string | null;
};

/** Type for creating a new goal: `title` is required, all else optional. */
export type NewGoal = Pick<Goal, "title"> & Partial<Omit<Goal, "id" | "title">>;

/**
 * Type for partially updating a goal: `id` is required; omitted fields are
 * left unchanged, `null` clears a nullable field.
 */
export type GoalUpdate = Pick<Goal, "id"> & Partial<Omit<Goal, "id">>;
