import { ITool, type Action, type Uuid } from "..";
import type { Callback } from "./callbacks";

/** Why a chat session stopped. */
export type ChatEndReason =
  /** The user ended it deliberately. */
  | "user"
  /** The session hit its duration cap. */
  | "cap"
  /** The agent or the platform failed. */
  | "error"
  /** The user's client went away and did not come back. */
  | "disconnect";

/**
 * How a realtime conversation should be run. Returned by the twist's spec
 * callback when the user taps a chat action.
 */
export type ChatSpec = {
  /**
   * The complete system prompt. Twist-owned — the runtime appends recent
   * thread notes as conversation history and nothing else.
   */
  instructions: string;
  /** Spoken verbatim to open the conversation. Null to let the agent open. */
  greeting: string | null;
  /** How many recent notes to supply as history. Null for the default of 20. */
  historyLimit: number | null;
  /** TTS voice identifier. Null for Plot's default voice. */
  voice: string | null;
  /**
   * Requested cap in seconds. Clamped down to the platform maximum, never up.
   * Null for the platform maximum.
   */
  maxSeconds: number | null;
  /**
   * Invoked with the finished {@link ChatSession} once the session ends.
   *
   * Delivered at-least-once: a retry after a transient failure can invoke
   * this callback again for the same session. Write it to be safe to run
   * more than once for the same {@link ChatSession.id}.
   */
  onEnded: Callback;
};

/** A {@link ChatSpec} with only the fields a twist must supply. */
export type NewChatSpec = Pick<ChatSpec, "instructions" | "onEnded"> &
  Partial<Omit<ChatSpec, "instructions" | "onEnded">>;

/** One completed turn of a conversation, and the note it became. */
export type ChatTurn = {
  role: "user" | "agent";
  /**
   * May be truncated for a very large transcript. {@link ChatTurn.noteId}
   * always addresses the complete note, so read it directly for the
   * verbatim text of a specific turn.
   */
  content: string;
  at: Date;
  /** The note this turn was written to. */
  noteId: Uuid;
};

/** A finished conversation, handed to the twist's `onEnded` callback. */
export type ChatSession = {
  id: Uuid;
  threadId: Uuid;
  startedAt: Date;
  endedAt: Date;
  durationSeconds: number;
  endedBy: ChatEndReason;
  /** Every turn, in order, user and agent interleaved. */
  turns: ChatTurn[];
};

/**
 * Built-in tool for realtime conversation with the user.
 *
 * A twist attaches a chat action to a note; tapping it opens a conversation
 * the user can speak or type, with the same agent either way. Each finished
 * turn is written into the thread as a note, so the conversation reads the
 * same while it is happening and when the user scrolls back to it later.
 * When it ends, the twist's `onEnded` callback receives the transcript.
 *
 * @example
 * ```typescript
 * class CoachTwist extends Twist<CoachTwist> {
 *   build(build: ToolBuilder) {
 *     return {
 *       plot: build(Plot, { thread: { access: ThreadAccess.Create } }),
 *       chat: build(Chat),
 *     };
 *   }
 *
 *   async offer(threadId: string) {
 *     await this.tools.plot.createNote({
 *       thread: { id: threadId },
 *       content: "Want to talk this through?",
 *       actions: [
 *         await this.tools.chat.action({
 *           title: "Talk it through",
 *           spec: await this.callback(this.launchSpec),
 *           threadId,
 *         }),
 *       ],
 *     });
 *   }
 *
 *   async launchSpec(): Promise<NewChatSpec> {
 *     return {
 *       instructions: "You are a coach. Ask one question at a time.",
 *       greeting: "What's actually holding this up?",
 *       onEnded: await this.callback(this.extract),
 *     };
 *   }
 *
 *   async extract(session: ChatSession) {
 *     // Post-process session.turns however the twist needs.
 *   }
 * }
 * ```
 */
export abstract class Chat extends ITool {
  /**
   * Builds the action to attach to a note.
   *
   * @param opts.title - Button text.
   * @param opts.spec - Callback returning the {@link NewChatSpec}, invoked
   *   when the user taps.
   * @param opts.threadId - The thread the note is going on. Used to build the
   *   fallback link that clients predating chat support open instead.
   */
  abstract action(opts: {
    title: string;
    spec: Callback;
    threadId: Uuid;
  }): Promise<Action>;
}
