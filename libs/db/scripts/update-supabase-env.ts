#!/usr/bin/env tsx

import { execSync } from "child_process";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { join } from "path";

/**
 * Extracts Supabase credentials from `supabase status` and writes them
 * to .env.development.local in the project root.
 */

const projectRoot = join(__dirname, "../../..");
const envFile = join(projectRoot, ".env.development.local");

try {
  // Get Supabase status
  const statusOutput = execSync("supabase status", {
    encoding: "utf-8",
    cwd: join(__dirname, ".."),
  });

  // Parse the output to extract credentials
  const lines = statusOutput.split("\n");
  let apiUrl = "";
  let anonKey = "";
  let serviceKey = "";

  for (const line of lines) {
    const trimmed = line.trim();

    // New format: │ Project URL    │ http://127.0.0.1:54321 │
    if (trimmed.includes("Project URL")) {
      const parts = trimmed.split("│").map(p => p.trim()).filter(Boolean);
      if (parts.length >= 2) {
        apiUrl = parts[1];
      }
    }
    // New format: │ Publishable │ sb_publishable_... │
    else if (trimmed.includes("Publishable")) {
      const parts = trimmed.split("│").map(p => p.trim()).filter(Boolean);
      if (parts.length >= 2) {
        anonKey = parts[1];
      }
    }
    // New format: │ Secret │ sb_secret_... │
    else if (trimmed.includes("Secret") && !trimmed.includes("Access Key") && !trimmed.includes("Secret Key")) {
      const parts = trimmed.split("│").map(p => p.trim()).filter(Boolean);
      if (parts.length >= 2) {
        serviceKey = parts[1];
      }
    }
    // Old format fallback
    else if (trimmed.startsWith("API URL:")) {
      apiUrl = trimmed.split("API URL:")[1]?.trim() || "";
    } else if (trimmed.startsWith("anon key:")) {
      anonKey = trimmed.split("anon key:")[1]?.trim() || "";
    } else if (trimmed.startsWith("service_role key:")) {
      serviceKey = trimmed.split("service_role key:")[1]?.trim() || "";
    }
  }

  if (!apiUrl || !anonKey || !serviceKey) {
    console.error("Failed to extract Supabase credentials from status output");
    console.error(`  API URL: ${apiUrl || "(not found)"}`);
    console.error(`  Anon Key: ${anonKey || "(not found)"}`);
    console.error(`  Service Key: ${serviceKey || "(not found)"}`);
    process.exit(1);
  }

  // Read existing .env.development.local or create empty string
  let envContent = "";
  if (existsSync(envFile)) {
    envContent = readFileSync(envFile, "utf-8");
  }

  // Parse existing env vars
  const envVars = new Map<string, string>();
  const lines2 = envContent.split("\n");
  const otherLines: string[] = [];

  for (const line of lines2) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#") || !trimmed.includes("=")) {
      // Comment or empty line - preserve as-is
      otherLines.push(line);
    } else {
      const [key, ...valueParts] = trimmed.split("=");
      const value = valueParts.join("=");
      envVars.set(key.trim(), value.trim());
    }
  }

  // Update Supabase credentials
  envVars.set("SUPABASE_URL", apiUrl);
  envVars.set("SUPABASE_ANON_KEY", anonKey);
  envVars.set("SUPABASE_SERVICE_ROLE_KEY", serviceKey);

  // Build new content
  const newLines: string[] = [];

  // Add non-env lines (comments, empty lines) from the beginning
  for (const line of otherLines) {
    if (line.trim() === "" || line.trim().startsWith("#")) {
      newLines.push(line);
    } else {
      break;
    }
  }

  // Add all env vars
  for (const [key, value] of envVars.entries()) {
    newLines.push(`${key}=${value}`);
  }

  // Write back to file
  writeFileSync(envFile, newLines.join("\n") + "\n", "utf-8");

  console.log(`✓ Updated Supabase credentials in .env.development.local`);
  console.log(`  SUPABASE_URL=${apiUrl}`);
  console.log(`  SUPABASE_ANON_KEY=${anonKey.substring(0, 20)}...`);
  console.log(`  SUPABASE_SERVICE_ROLE_KEY=${serviceKey.substring(0, 20)}...`);
} catch (error) {
  console.error("Error updating Supabase environment variables:", error);
  process.exit(1);
}
