import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import * as ts from "typescript";

/**
 * Every published connector must declare `kind` on every link type it
 * exposes. Plot groups connectors by `kind` and uses it to decide which
 * channels a workspace can enable — a link type with no kind silently falls
 * back to `team-task`, which is wrong for calendars and personal task
 * managers.
 *
 * Static check: for each connector source file, find every object literal
 * that declares own `type` and `label` properties (the shape unique to
 * `LinkTypeConfig`) and assert a `kind` property is declared there too.
 */
const CONNECTORS_DIR = join(import.meta.dirname, "..", "connectors");

function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (d: string) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (["node_modules", "dist", "build"].includes(e.name)) continue;
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".ts") && !e.name.includes(".test.")) out.push(p);
    }
  };
  walk(dir);
  return out;
}

/**
 * `OptionDef` entries from the `Options` tool schema (`{ type: "text" |
 * "number" | "boolean" | "select", label: ..., default: ... }`, see
 * `twister/src/options.ts`) share the `type`+`label` shape with
 * `LinkTypeConfig` by coincidence: those four strings are a real closed
 * union reserved for option-field kinds and never occur as a connector's
 * own link `type`.
 */
const OPTION_DEF_TYPES = new Set(["text", "number", "boolean", "select"]);

/** The string literal value of an expression, unwrapping a trailing `as const`/`as T`. */
function stringLiteralValue(node: ts.Expression): string | undefined {
  const expr = ts.isAsExpression(node) ? node.expression : node;
  return ts.isStringLiteralLike(expr) ? expr.text : undefined;
}

function propertyName(prop: ts.ObjectLiteralElementLike): string | undefined {
  if (!ts.isPropertyAssignment(prop)) return undefined;
  if (ts.isIdentifier(prop.name) || ts.isStringLiteral(prop.name)) return prop.name.text;
  return undefined;
}

/**
 * Find every `LinkTypeConfig`-shaped object literal in `src` — one with its
 * own `type` and `label` properties, at any nesting depth inside the file —
 * and report those missing a sibling `kind` property.
 *
 * Uses the TypeScript compiler API (rather than a regex over the source
 * text) specifically so that nesting inside the object — an inline
 * `statuses: [...]`, `contactRoles: [...]`, or `compose: {...}` — can never
 * hide it from the check. Each object literal's own properties are read
 * from the AST directly, independent of how deeply anything else in the
 * object nests.
 */
function undeclaredLinkTypes(file: string, src: string): string[] {
  const sourceFile = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true);
  const undeclared: string[] = [];

  const visit = (node: ts.Node) => {
    if (ts.isObjectLiteralExpression(node)) {
      let hasLabel = false;
      let hasKind = false;
      let typeValue: string | undefined;
      let sawType = false;
      for (const prop of node.properties) {
        const name = propertyName(prop);
        if (name === "type" && ts.isPropertyAssignment(prop)) {
          sawType = true;
          typeValue = stringLiteralValue(prop.initializer);
        } else if (name === "label") {
          hasLabel = true;
        } else if (name === "kind") {
          hasKind = true;
        }
      }
      const isOptionDef = typeValue !== undefined && OPTION_DEF_TYPES.has(typeValue);
      if (sawType && hasLabel && !isOptionDef && !hasKind) {
        const text = node.getText(sourceFile).replace(/\s+/g, " ");
        undeclared.push(`${file}: ${text.slice(0, 80)}`);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return undeclared;
}

describe("public connectors declare a kind on every link type", () => {
  const names = readdirSync(CONNECTORS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(CONNECTORS_DIR, e.name, "src")))
    .map((e) => e.name);

  it.each(names)("%s", (name) => {
    const undeclared: string[] = [];
    for (const file of sourceFiles(join(CONNECTORS_DIR, name, "src"))) {
      undeclared.push(...undeclaredLinkTypes(file, readFileSync(file, "utf8")));
    }
    expect(undeclared, `link types missing kind in ${name}`).toEqual([]);
  });
});
