import { parseArgs } from "node:util";

export interface CliOptions {
  only: string | null;
  model: string | null;
  runs: number;
  concurrency: number;
  label: string | null;
  compare: string | null;
  keepOutput: boolean;
  list: boolean;
}

export function parseCliArgs(argv: string[]): CliOptions {
  // pnpm forwards a literal "--" token when invoked as
  // `pnpm --filter @plotday/api eval:twist-gen -- --flag` — strip it.
  const args = argv.filter((a) => a !== "--");
  const { values } = parseArgs({
    args,
    allowPositionals: false,
    options: {
      only: { type: "string" },
      model: { type: "string" },
      runs: { type: "string" },
      concurrency: { type: "string" },
      label: { type: "string" },
      compare: { type: "string" },
      "keep-output": { type: "boolean" },
      list: { type: "boolean" },
    },
  });
  const positiveInt = (value: string | undefined, dflt: number, name: string) => {
    if (value === undefined) return dflt;
    const n = Number.parseInt(value, 10);
    if (!Number.isFinite(n) || n < 1 || String(n) !== value.trim()) {
      throw new Error(`--${name} must be a positive integer`);
    }
    return n;
  };
  return {
    only: values.only ?? null,
    model: values.model ?? null,
    runs: positiveInt(values.runs, 1, "runs"),
    concurrency: positiveInt(values.concurrency, 3, "concurrency"),
    label: values.label ?? null,
    compare: values.compare ?? null,
    keepOutput: values["keep-output"] ?? false,
    list: values.list ?? false,
  };
}
