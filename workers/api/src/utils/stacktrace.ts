/**
 * Utility for parsing and translating stack traces using sourcemaps.
 *
 * This module helps convert minified/bundled stack traces back to their
 * original source locations, and filters out framework-internal frames.
 */

import { TraceMap, originalPositionFor } from "@jridgewell/trace-mapping";

/**
 * Represents a single frame in a stack trace
 */
export interface StackFrame {
  /** Function name (may be anonymous) */
  functionName: string | null;
  /** Source file path */
  fileName: string | null;
  /** Line number (1-indexed) */
  lineNumber: number | null;
  /** Column number (1-indexed) */
  columnNumber: number | null;
}

/**
 * Regex to parse V8-style stack trace lines
 * Matches formats like:
 *   at functionName (file:line:column)
 *   at file:line:column
 *   at functionName (http://example.com/file.js:10:5)
 */
const STACK_LINE_REGEX =
  /^\s*at (?:(.+?)\s+\()?(?:(.+?):(\d+):(\d+)|([^)]+))\)?/;

/**
 * Parses a JavaScript error stack trace string into structured frames.
 *
 * @param stack - Raw stack trace string from Error.stack
 * @returns Array of parsed stack frames
 *
 * @example
 * ```typescript
 * const error = new Error("Something went wrong");
 * const frames = parseStackTrace(error.stack);
 * // [{ functionName: "myFunc", fileName: "index.js", lineNumber: 42, columnNumber: 15 }, ...]
 * ```
 */
export function parseStackTrace(stack: string | undefined): StackFrame[] {
  if (!stack) return [];

  const lines = stack.split("\n");
  const frames: StackFrame[] = [];

  for (const line of lines) {
    const match = line.match(STACK_LINE_REGEX);
    if (!match) continue;

    const [, functionName, fileName, lineStr, columnStr] = match;

    frames.push({
      functionName: functionName || null,
      fileName: fileName || null,
      lineNumber: lineStr ? parseInt(lineStr, 10) : null,
      columnNumber: columnStr ? parseInt(columnStr, 10) : null,
    });
  }

  return frames;
}

/**
 * Normalizes a source path by removing leading ../ segments.
 *
 * Examples:
 *   ../../../tools/foo/src/bar.ts -> tools/foo/src/bar.ts
 *   ../src/index.ts -> src/index.ts
 *   src/file.ts -> src/file.ts
 */
function normalizeSourcePath(path: string): string {
  // Remove leading ../ segments
  return path.replace(/^(\.\.\/)+/, "");
}

/**
 * Translates stack frames using a sourcemap.
 *
 * Takes frames from a minified/bundled file and maps them back to their
 * original source locations using the provided sourcemap.
 *
 * Uses @jridgewell/trace-mapping to properly decode VLQ mappings and translate
 * bundled positions to original source positions.
 *
 * @param frames - Parsed stack frames from minified code
 * @param sourcemapContent - Sourcemap JSON content
 * @returns Promise resolving to translated frames
 *
 * @example
 * ```typescript
 * const frames = parseStackTrace(error.stack);
 * const sourcemap = await fetchSourcemap("index.js.map");
 * const originalFrames = await translateStackTrace(frames, sourcemap);
 * ```
 */
export async function translateStackTrace(
  frames: StackFrame[],
  sourcemapContent: string
): Promise<StackFrame[]> {
  try {
    const sourcemap = JSON.parse(sourcemapContent);
    const tracer = new TraceMap(sourcemap);

    return frames.map((frame) => {
      // Skip frames without position info
      if (frame.lineNumber === null || frame.columnNumber === null) {
        return frame;
      }

      // Translate position using sourcemap
      const original = originalPositionFor(tracer, {
        line: frame.lineNumber,
        column: frame.columnNumber,
      });

      // If we found a mapping, use the original position
      if (original.source !== null) {
        return {
          ...frame,
          fileName: normalizeSourcePath(original.source),
          lineNumber: original.line,
          columnNumber: original.column,
          functionName: original.name || frame.functionName,
        };
      }

      // No mapping found, return original frame
      return frame;
    });
  } catch (error) {
    console.error("Error translating stack trace:", error);
    return frames; // Return original frames if translation fails
  }
}

/**
 * Formats stack frames back into a readable stack trace string.
 *
 * @param frames - Stack frames to format
 * @returns Formatted stack trace string
 *
 * @example
 * ```typescript
 * const frames = await translateStackTrace(parsedFrames, sourcemap);
 * const readableStack = formatStackTrace(frames);
 * console.error(readableStack);
 * ```
 */
export function formatStackTrace(frames: StackFrame[]): string {
  return frames
    .map((frame) => {
      let funcName = frame.functionName || "<anonymous>";
      // Remove "async " prefix from function names
      if (funcName.startsWith("async ")) {
        funcName = funcName.slice(6);
      }
      const location =
        frame.fileName && frame.lineNumber !== null
          ? `${frame.fileName}:${frame.lineNumber}${
              frame.columnNumber !== null ? `:${frame.columnNumber}` : ""
            }`
          : "unknown";

      return `    at ${funcName} (${location})`;
    })
    .join("\n");
}

/**
 * Processes an error stack trace: parses, translates, filters, and formats.
 *
 * This is the main entry point for processing stack traces with sourcemaps.
 *
 * @param error - Error object with stack property
 * @param sourcemap - Optional sourcemap content for translation
 * @returns Processed stack trace string with only agent code
 *
 * @example
 * ```typescript
 * try {
 *   await agent.activate();
 * } catch (error) {
 *   const sourcemap = await getAgentSourcemap(agentId);
 *   const cleanStack = await processStackTrace(error, sourcemap);
 *   console.error(`Error: ${error.message}\n${cleanStack}`);
 * }
 * ```
 */
export async function processStackTrace(
  error: Error,
  sourcemap?: string
): Promise<string> {
  // Parse the stack trace
  let frames = parseStackTrace(error.stack);

  // Translate with sourcemap if available
  if (sourcemap) {
    frames = await translateStackTrace(frames, sourcemap);
  }

  // Remove the last frame (always the SDK wrapper calling into user code)
  if (frames.length > 0) {
    frames = frames.slice(0, -1);
  }

  // Format back to string
  return formatStackTrace(frames);
}
