import { PostgresMeta } from "@supabase/postgres-meta";
import { getGeneratorMetadata } from "@supabase/postgres-meta/dist/lib/generators.js";
import { readFileSync, writeFileSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const DB_URL =
  process.env.DATABASE_URL ??
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

const SCHEMAS = ["public", "user"];
const OUT_PATH = resolve(__dirname, "../src/types.ts");
const isCheck = process.argv.includes("--check");

async function main() {
  const pgMeta = new PostgresMeta({
    connectionString: DB_URL,
  });

  const { data, error } = await getGeneratorMetadata(pgMeta, {
    includedSchemas: SCHEMAS,
  });

  if (error) {
    console.error("Failed to get metadata:", error);
    process.exit(1);
  }

  // Import the template dynamically to avoid tsx/esbuild issues
  // with top-level await in @supabase/postgres-meta's server constants
  const { apply } = await import(
    "@supabase/postgres-meta/dist/server/templates/typescript.js"
  );

  const output: string = await apply({
    ...data,
    detectOneToOneRelationships: false,
  });

  if (isCheck) {
    const existing = readFileSync(OUT_PATH, "utf-8");
    if (existing !== output) {
      console.error(
        "❌ Type definitions are out of date. Run `pnpm types` and commit."
      );
      process.exit(1);
    }
    console.log("Types are up to date.");
  } else {
    writeFileSync(OUT_PATH, output);
    console.log(`Types written to ${OUT_PATH}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
