import { describe, expect, it } from "vitest";
import ts from "typescript";

import TwistEntrypoint from "./entrypoint";

describe("twist entrypoint MODULE template", () => {
  it("is syntactically valid ESM (no unescaped backticks / template typos)", () => {
    // The MODULE is a template literal consumed verbatim as the loader
    // worker's index.js. A raw backtick or syntax slip only surfaces at
    // connector deploy time ("Expected \";\" but found ..."), so parse it
    // here with the TypeScript parser and fail fast on any diagnostic.
    const source = ts.createSourceFile(
      "module.js",
      TwistEntrypoint.Module,
      ts.ScriptTarget.ES2022,
      /* setParentNodes */ false,
      ts.ScriptKind.JS
    );
    const diagnostics = (
      source as unknown as { parseDiagnostics: ts.Diagnostic[] }
    ).parseDiagnostics;

    expect(
      diagnostics.map((d) =>
        typeof d.messageText === "string"
          ? `${d.start}: ${d.messageText}`
          : `${d.start}: ${d.messageText.messageText}`
      )
    ).toEqual([]);
  });

  it("wraps built-in tools with the tool-call metrics instrumentation", () => {
    // Smoke-check the load-bearing pieces are present in the template.
    expect(TwistEntrypoint.Module).toContain("instrumentToolStub");
    expect(TwistEntrypoint.Module).toContain("reportToolMetricsToHost");
    expect(TwistEntrypoint.Module).toContain("TIMED_TOOL_METHODS");
  });
});

/**
 * Lift a top-level declaration out of the MODULE template text by name,
 * balancing `open`/`close` while skipping string and comment spans so
 * delimiters inside them don't throw off the count. The MODULE is injected
 * verbatim as the connector loader's `index.js`, so its runtime helpers can't
 * be imported directly — this reconstructs the real `instrumentToolStub` (and
 * its deps) so the tests below exercise the code that actually ships.
 */
function sliceDecl(
  source: string,
  anchor: string,
  open: string,
  close: string
): string {
  const start = source.indexOf(anchor);
  if (start === -1) throw new Error(`anchor not found: ${anchor}`);
  const openIdx = source.indexOf(open, start);
  if (openIdx === -1) throw new Error(`open "${open}" not found after ${anchor}`);
  const n = source.length;
  let depth = 0;
  let i = openIdx;
  while (i < n) {
    const two = source.slice(i, i + 2);
    if (two === "//") {
      const eol = source.indexOf("\n", i);
      i = eol === -1 ? n : eol;
      continue;
    }
    if (two === "/*") {
      const end = source.indexOf("*/", i + 2);
      i = end === -1 ? n : end + 2;
      continue;
    }
    const ch = source[i];
    if (ch === '"' || ch === "'" || ch === "`") {
      i++;
      while (i < n && source[i] !== ch) {
        if (source[i] === "\\") i++;
        i++;
      }
      i++;
      continue;
    }
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
    i++;
  }
  throw new Error(`unbalanced ${open}${close} for ${anchor}`);
}

/**
 * Reconstruct the real `instrumentToolStub` from the shipped MODULE text, with
 * its `TIMED_TOOL_METHODS` allowlist and `recordToolCall` helper in scope.
 */
function loadInstrumentToolStub(): (
  stub: unknown,
  toolId: string,
  metrics: Record<string, { n: number; ms: number; max: number }>
) => any {
  const mod = TwistEntrypoint.Module;
  const timed = sliceDecl(mod, "const TIMED_TOOL_METHODS", "(", ")") + ";";
  const record = sliceDecl(mod, "function recordToolCall", "{", "}");
  const instrument = sliceDecl(mod, "function instrumentToolStub", "{", "}");
  return new Function(
    `${timed}\n${record}\n${instrument}\nreturn instrumentToolStub;`
  )();
}

function rpcMethodError(name: string): Error {
  return new Error(`The RPC receiver does not implement the method "${name}".`);
}

/**
 * Stand-in for a Cloudflare cross-worker RPC stub, reproducing the two
 * behaviours that matter for the metrics wrapper:
 *   - reading a method name returns a callable "method stub"; invoking it
 *     performs the RPC and resolves to the method's result (always async).
 *   - reading ANY string property off that method stub (`.call`, `.apply`,
 *     `.bind`, …) is NOT the JS builtin — it is a nested lookup for a *remote
 *     method of that name*, which the receiver does not implement, so invoking
 *     it throws. This is the exact footgun that made `value.call(target, …)`
 *     drop every timed tool call with "The RPC receiver does not implement the
 *     method \"call\".".
 *
 * `onMethodPropRead` fires whenever the wrapper reads a property off a method
 * stub instead of just calling it — the tests use it to assert the wrapper
 * never touches `.call`/`.apply`/`.bind`.
 */
function makeRpcStub(
  impl: Record<string, (...a: any[]) => any>,
  onMethodPropRead?: (prop: string) => void
) {
  const methodStub = (name: string) =>
    new Proxy(
      function (...args: any[]) {
        if (typeof impl[name] !== "function") {
          return Promise.reject(rpcMethodError(name));
        }
        return Promise.resolve(impl[name](...args));
      },
      {
        get(_t, sub) {
          if (typeof sub === "symbol") return undefined;
          onMethodPropRead?.(String(sub));
          return () => {
            throw rpcMethodError(String(sub));
          };
        },
      }
    );
  return new Proxy(
    {},
    {
      get(_t, prop) {
        if (typeof prop === "symbol") return undefined;
        return methodStub(String(prop));
      },
    }
  );
}

describe("instrumentToolStub (tool-call metrics wrapper) over RPC stubs", () => {
  it("invokes a timed method through the stub and records metrics", async () => {
    const instrumentToolStub = loadInstrumentToolStub();
    const metrics: Record<string, { n: number; ms: number; max: number }> = {};
    const stub = makeRpcStub({ saveNotes: (x: number) => ({ saved: x }) });

    const wrapped = instrumentToolStub(stub, "Integrations", metrics);

    // Against the old `value.call(target, ...)` this rejects/throws with
    // "...does not implement the method \"call\"." — the production symptom.
    await expect(wrapped.saveNotes(7)).resolves.toEqual({ saved: 7 });
    expect(metrics["Integrations.saveNotes"]?.n).toBe(1);
  });

  it("never reads .call/.apply/.bind off the RPC method stub", async () => {
    const instrumentToolStub = loadInstrumentToolStub();
    const touched: string[] = [];
    const stub = makeRpcStub(
      { saveNotes: (...a: number[]) => a },
      (prop) => touched.push(prop)
    );

    const wrapped = instrumentToolStub(stub, "Integrations", {});
    await wrapped.saveNotes(1, 2);

    // The wrapper must call the method stub directly. Reading ANY property off
    // it (as `value.call(...)` did) is the RPC footgun this guards against.
    expect(touched).toEqual([]);
  });

  it("records metrics and propagates when the RPC rejects", async () => {
    const instrumentToolStub = loadInstrumentToolStub();
    const metrics: Record<string, { n: number; ms: number; max: number }> = {};
    const stub = makeRpcStub({
      saveNotes: () => Promise.reject(new Error("boom")),
    });

    const wrapped = instrumentToolStub(stub, "Integrations", metrics);

    await expect(wrapped.saveNotes()).rejects.toThrow("boom");
    expect(metrics["Integrations.saveNotes"]?.n).toBe(1);
  });

  it("passes non-timed methods through without instrumenting them", async () => {
    const instrumentToolStub = loadInstrumentToolStub();
    const metrics: Record<string, { n: number; ms: number; max: number }> = {};
    const stub = makeRpcStub({
      definitelyNotATimedMethod: () => "ok",
    });

    const wrapped = instrumentToolStub(stub, "Store", metrics);

    await expect(wrapped.definitelyNotATimedMethod()).resolves.toBe("ok");
    expect(Object.keys(metrics)).toEqual([]);
  });
});
