import { existsSync } from "node:fs";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import { runAssertions, runChecks, runUniversalChecks, typecheckSource } from "../lib/checks";
import { parseSpecFile } from "../lib/corpus";
import { TWISTER_DIST } from "../lib/paths";
import type { TwistSource } from "../../src/twist/types";

function source(files: Record<string, string>, deps: Record<string, string> = {}): TwistSource {
  return { displayName: "T", files, dependencies: { "@plotday/twister": "latest", ...deps } };
}

const VALID_INDEX = `import { Twist, type ToolBuilder } from "@plotday/twister";

export default class EvalSample extends Twist<EvalSample> {
  build(_build: ToolBuilder) {
    return {};
  }
}
`;

const SPEC = parseSpecFile(
  `---
id: t
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\\s+Connector'
    why: no connectors
allowDeps: []
---
Body long enough to satisfy the loader checks for this fixture file.
`,
  "fixture.md"
);

describe("runUniversalChecks", () => {
  it("passes a default-exported Twist subclass", () => {
    expect(runUniversalChecks(source({ "index.ts": VALID_INDEX }))).toEqual([]);
  });

  it("fails when index.ts does not default-export a Twist subclass", () => {
    const failures = runUniversalChecks(
      source({ "index.ts": "export class NotDefault {}" })
    );
    expect(failures).toHaveLength(1);
    expect(failures[0]).toMatch(/default-export/);
  });
});

describe("runAssertions", () => {
  it("reports missing matches and forbidden patterns", () => {
    const failures = runAssertions(
      SPEC,
      source({ "index.ts": "export default class X extends Connector {}" })
    );
    expect(failures.some((f) => f.includes("createThread"))).toBe(true);
    expect(failures.some((f) => f.includes("no connectors"))).toBe(true);
  });

  it("passes when all assertions hold", () => {
    const failures = runAssertions(
      SPEC,
      source({ "index.ts": "plot.createThread({}) // extends Twist" })
    );
    expect(failures).toEqual([]);
  });
});

// Real tsc against the built twister types — needs public/twister/dist.
describe.skipIf(!existsSync(join(TWISTER_DIST, "index.d.ts")))(
  "typecheckSource",
  () => {
    it("accepts a well-typed twist", async () => {
      const result = await typecheckSource(source({ "index.ts": VALID_INDEX }));
      expect(result.errors).toEqual([]);
      expect(result.ok).toBe(true);
    }, 60_000);

    it("rejects a type error with diagnostics", async () => {
      const bad = VALID_INDEX + `\nconst n: number = "not a number";\n`;
      const result = await typecheckSource(source({ "index.ts": bad }));
      expect(result.ok).toBe(false);
      expect(result.errors.join("\n")).toMatch(/TS2322|not assignable/);
    }, 60_000);

    it("typechecks sources with nested file paths", async () => {
      const result = await typecheckSource(
        source({
          "index.ts": VALID_INDEX.replace(
            "export default class",
            'import { two } from "./lib/util";\nexport default class'
          ).replace("return {};", "return {}; // two() "),
          "lib/util.ts": "export function two(): number { return 2; }",
        })
      );
      expect(result.errors).toEqual([]);
      expect(result.ok).toBe(true);
    }, 60_000);
  }
);

describe("runChecks", () => {
  it("returns assertion_failed without typechecking when assertions fail", async () => {
    const outcome = await runChecks(
      SPEC,
      source({ "index.ts": "export default class X extends Connector {}" })
    );
    expect(outcome.status).toBe("assertion_failed");
    expect(outcome.assertionFailures.length).toBeGreaterThan(0);
    expect(outcome.typecheckErrors).toEqual([]);
  });
});

// Real tsc against the built twister types — needs public/twister/dist.
describe.skipIf(!existsSync(join(TWISTER_DIST, "index.d.ts")))(
  "runChecks (typecheck)",
  () => {
    it("returns pass for a valid, assertion-satisfying source", async () => {
      const validWithAssertion = VALID_INDEX.replace(
        "return {};",
        "return {}; // createThread"
      );
      const outcome = await runChecks(SPEC, source({ "index.ts": validWithAssertion }));
      expect(outcome.status).toBe("pass");
    }, 60_000);
  }
);
