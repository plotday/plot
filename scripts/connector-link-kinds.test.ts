import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Every published connector must declare `kind` on every link type it
 * exposes. Plot maps kinds to entitlement; a link type with no kind silently
 * falls back to `team-task`, which is wrong for calendars and personal task
 * managers and would gate them behind a paid plan.
 *
 * Static check: for each connector source file, find every object literal
 * that pairs `type:` with `label:` (the shape unique to LinkTypeConfig) and
 * assert a `kind:` appears within the same object.
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
 * Link-type object literals: `type:` and `label:` belonging to the same
 * object, tolerating up to one level of brace nesting inside it. A plain
 * "no intervening brace" match would miss most real `LinkTypeConfig`
 * objects in this repo, which almost always carry an inline `statuses:
 * [...]`, `contactRoles: [...]`, or `compose: {...}` — each exactly one
 * level deep — between `type:`/`label:` and the object's own closing `}`.
 *
 * Excludes `OptionDef` entries from the `Options` tool schema (`{ type:
 * "text" | "number" | "boolean" | "select", label: ..., default: ... }`),
 * which share this shape by coincidence — those four strings are reserved
 * for option-field kinds and never appear as a connector's own link `type`.
 * Unlike `LinkTypeConfig.type`, which is contextually typed against the
 * `Connector.linkTypes` declaration, `OptionDef.type` is inferred through a
 * generic and so is written with `as const`, which is how these are told
 * apart here.
 */
function linkTypeBlocks(src: string): string[] {
  const nestable = String.raw`(?:[^{}]|\{[^{}]*\})*`;
  const pattern = new RegExp(
    `\\{${nestable}\\btype:\\s*[^,]+,${nestable}\\blabel:\\s*"[^"]*"${nestable}\\}`,
    "gs"
  );
  return [...src.matchAll(pattern)]
    .map((m) => m[0])
    .filter((block) => !/\btype:\s*"(?:text|number|boolean|select)"\s+as\s+const,/.test(block));
}

describe("public connectors declare a kind on every link type", () => {
  const names = readdirSync(CONNECTORS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(CONNECTORS_DIR, e.name, "src")))
    .map((e) => e.name);

  it.each(names)("%s", (name) => {
    const undeclared: string[] = [];
    for (const file of sourceFiles(join(CONNECTORS_DIR, name, "src"))) {
      for (const block of linkTypeBlocks(readFileSync(file, "utf8"))) {
        if (!/\bkind:\s*"(calendar|task|team-task|message)"/.test(block)) {
          undeclared.push(`${file}: ${block.slice(0, 80).replace(/\s+/g, " ")}`);
        }
      }
    }
    expect(undeclared, `link types missing kind in ${name}`).toEqual([]);
  });
});
