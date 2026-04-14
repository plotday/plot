#!/usr/bin/env node

/**
 * Validates that all changeset files follow the required format
 * with category prefixes: Added, Changed, Deprecated, Removed, Fixed, Security
 */

const fs = require("fs");
const path = require("path");

const CATEGORIES = [
  "Added",
  "Changed",
  "Deprecated",
  "Removed",
  "Fixed",
  "Security"
];

const CATEGORY_PATTERN = new RegExp(`^(${CATEGORIES.join("|")}):\\s+`, "i");

// Load the changeset config to check the ignore list. A changeset that
// targets only ignored packages never triggers a version bump, so it stays
// pending forever and breaks the release workflow (the changesets action
// detects it, runs `changeset version` with no diff, then tries to open an
// empty release PR). Reject these at validation time.
const configPath = path.join(__dirname, "config.json");
const config = JSON.parse(fs.readFileSync(configPath, "utf-8"));
const IGNORE_PATTERNS = (config.ignore || []).map(glob => {
  // Convert simple glob ("@plotday/connector-*") to a RegExp.
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`);
});

function isIgnored(packageName) {
  return IGNORE_PATTERNS.some(re => re.test(packageName));
}

function parsePackages(lines) {
  const packages = [];
  let inFrontmatter = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "---") {
      if (!inFrontmatter) {
        inFrontmatter = true;
        continue;
      }
      break;
    }
    if (!inFrontmatter) continue;
    const match = trimmed.match(/^"?([^"]+)"?\s*:\s*(major|minor|patch)\s*$/);
    if (match) packages.push(match[1]);
  }
  return packages;
}

/**
 * Validate a single changeset file
 */
function validateChangeset(filePath) {
  const content = fs.readFileSync(filePath, "utf-8");
  const lines = content.split("\n");

  const packages = parsePackages(lines);
  if (packages.length > 0 && packages.every(isIgnored)) {
    return {
      valid: false,
      error: `All target packages are in the .changeset/config.json ignore list (${packages.join(", ")}). Only @plotday/twister is published via changesets; connectors and twists are deployed separately and do not take changesets.`
    };
  }

  // Find the summary line (first non-empty line after the frontmatter)
  let inFrontmatter = false;
  let frontmatterClosed = false;
  let summary = null;

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed === "---") {
      if (!inFrontmatter) {
        inFrontmatter = true;
      } else {
        frontmatterClosed = true;
      }
      continue;
    }

    if (frontmatterClosed && trimmed !== "") {
      summary = trimmed;
      break;
    }
  }

  if (!summary) {
    return {
      valid: false,
      error: "No summary found in changeset"
    };
  }

  // Check if summary has a valid category prefix
  const match = summary.match(CATEGORY_PATTERN);

  if (!match) {
    return {
      valid: false,
      error: `Summary must start with a category prefix (${CATEGORIES.join(", ")})`,
      summary,
      suggestion: `Example: "Added: ${summary}"`
    };
  }

  // Check if the category is properly capitalized
  const category = match[1];
  const properCategory = category.charAt(0).toUpperCase() + category.slice(1).toLowerCase();

  if (category !== properCategory) {
    return {
      valid: false,
      error: `Category "${category}" should be capitalized as "${properCategory}"`,
      summary,
      suggestion: summary.replace(match[0], `${properCategory}: `)
    };
  }

  return { valid: true };
}

/**
 * Get all changeset files
 */
function getChangesetFiles() {
  const changesetDir = path.join(__dirname);
  const files = fs.readdirSync(changesetDir);

  return files
    .filter(file => file.endsWith(".md") && file !== "README.md")
    .map(file => path.join(changesetDir, file));
}

/**
 * Main validation
 */
function main() {
  const changesetFiles = getChangesetFiles();

  if (changesetFiles.length === 0) {
    console.log("✓ No changesets to validate");
    process.exit(0);
  }

  console.log(`Validating ${changesetFiles.length} changeset(s)...\n`);

  let hasErrors = false;

  for (const file of changesetFiles) {
    const fileName = path.basename(file);
    const result = validateChangeset(file);

    if (!result.valid) {
      hasErrors = true;
      console.error(`✗ ${fileName}`);
      console.error(`  ${result.error}`);
      if (result.summary) {
        console.error(`  Current: "${result.summary}"`);
      }
      if (result.suggestion) {
        console.error(`  Fix: "${result.suggestion}"`);
      }
      console.error("");
    } else {
      console.log(`✓ ${fileName}`);
    }
  }

  if (hasErrors) {
    console.error("\nValidation failed!");
    console.error("\nChangeset summaries must start with one of these categories:");
    console.error(CATEGORIES.map(c => `  - ${c}: description`).join("\n"));
    console.error("\nExamples:");
    console.error("  - Added: new authentication feature");
    console.error("  - Fixed: memory leak in worker process");
    console.error("  - Changed: improved error messages");
    process.exit(1);
  }

  console.log("\n✓ All changesets are valid!");
  process.exit(0);
}

main();
