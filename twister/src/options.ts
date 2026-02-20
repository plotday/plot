import { ITool } from "./tool";

/**
 * A select option definition for twist configuration.
 * Renders as a dropdown in the Flutter UI.
 */
export type SelectDef = {
  type: "select";
  label: string;
  description?: string;
  choices: ReadonlyArray<{ value: string; label: string }>;
  default: string;
};

/**
 * A text input option definition for twist configuration.
 * Renders as a text field in the Flutter UI.
 */
export type TextDef = {
  type: "text";
  label: string;
  description?: string;
  default: string;
  placeholder?: string;
};

/**
 * A number input option definition for twist configuration.
 * Renders as a number field in the Flutter UI.
 */
export type NumberDef = {
  type: "number";
  label: string;
  description?: string;
  default: number;
  min?: number;
  max?: number;
};

/**
 * A boolean toggle option definition for twist configuration.
 * Renders as a switch in the Flutter UI.
 */
export type BooleanDef = {
  type: "boolean";
  label: string;
  description?: string;
  default: boolean;
};

/**
 * Union of all option definition types.
 */
export type OptionDef = SelectDef | TextDef | NumberDef | BooleanDef;

/**
 * Schema defining all configurable options for a twist.
 * Each key maps to an option definition that describes its type, label, and default value.
 */
export type OptionsSchema = Record<string, OptionDef>;

/**
 * Infers the resolved value types from an options schema.
 * Boolean options resolve to `boolean`, number options to `number`,
 * and select/text options to `string`.
 */
export type ResolvedOptions<T extends OptionsSchema> = {
  [K in keyof T]: T[K] extends BooleanDef
    ? boolean
    : T[K] extends NumberDef
      ? number
      : string;
};

/**
 * Built-in marker class for twist configuration options.
 *
 * Declare options in your twist's `build()` method to expose configurable
 * settings to users. The schema is introspected at deploy time and stored
 * alongside permissions. At runtime, user values are merged with defaults.
 *
 * @example
 * ```typescript
 * import { Options, type OptionsSchema } from "@plotday/twister/options";
 *
 * export default class MyTwist extends Twist<MyTwist> {
 *   build(build: ToolBuilder) {
 *     return {
 *       options: build(Options, {
 *         model: {
 *           type: 'select',
 *           label: 'AI Model',
 *           choices: [
 *             { value: 'fast', label: 'Fast' },
 *             { value: 'smart', label: 'Smart' },
 *           ],
 *           default: 'fast',
 *         },
 *       }),
 *       // ... other tools
 *     };
 *   }
 *
 *   async respond(note: Note) {
 *     const model = this.tools.options.model; // typed as string
 *   }
 * }
 * ```
 */
export abstract class Options extends ITool {}
