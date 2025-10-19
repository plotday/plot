#!/usr/bin/env node

/**
 * Post-processing script to reorganize CHANGELOG.md files
 * Converts changesets' default grouping (Major/Minor/Patch Changes)
 * into "Keep a Changelog" format (Added/Changed/Fixed/etc.)
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

/**
 * Process a single CHANGELOG.md file
 */
function processChangelog(filePath) {
  const content = fs.readFileSync(filePath, "utf-8");
  const lines = content.split("\n");

  let result = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Check if this is a version header (e.g., "## 1.0.0")
    if (line.match(/^##\s+\d+\.\d+\.\d+/)) {
      result.push(line);
      i++;

      // Skip empty lines after version header
      while (i < lines.length && lines[i].trim() === "") {
        i++;
      }

      // Check if we have change type sections (Minor Changes, Patch Changes, etc.)
      const sectionStart = i;
      const changes = [];

      // Collect all changes in this version
      let currentCategory = null;

      while (i < lines.length && !lines[i].match(/^##\s+\d+\.\d+\.\d+/)) {
        const currentLine = lines[i];

        // Check for "Keep a Changelog" category headers (already formatted)
        const keepAChangelogMatch = currentLine.match(/^###\s+(Added|Changed|Deprecated|Removed|Fixed|Security)$/);
        if (keepAChangelogMatch) {
          currentCategory = keepAChangelogMatch[1];
          i++;
          continue;
        }

        // Skip the old "### Minor Changes", "### Patch Changes" headers
        if (currentLine.match(/^###\s+(Major|Minor|Patch)\s+Changes/)) {
          currentCategory = null; // Reset category for old format
          i++;
          continue;
        }

        // Check for category markers in the content (from changelog formatter)
        const categoryMatch = currentLine.match(/<!--\s*CATEGORY:(\w+)\s*-->(.*)/);
        if (categoryMatch) {
          const category = categoryMatch[1];
          const content = categoryMatch[2];
          changes.push({ category, content: `- ${content}` });
          i++;
        } else if (currentLine.trim() !== "" && currentLine.match(/^-\s+/)) {
          // If we have a current category (from Keep a Changelog format), use it
          // Otherwise, treat as "Changed" (legacy/old format)
          const category = currentCategory || "Changed";
          const contentLines = [currentLine];
          i++;

          // Collect any indented continuation lines (e.g., for dependency lists)
          while (i < lines.length && lines[i].match(/^  /)) {
            contentLines.push(lines[i]);
            i++;
          }

          changes.push({ category, content: contentLines.join("\n") });
        } else {
          i++;
        }
      }

      // Group changes by category and output in "Keep a Changelog" order
      if (changes.length > 0) {
        result.push(""); // Empty line after version header

        for (const category of CATEGORIES) {
          const categoryChanges = changes.filter(c => c.category === category);
          if (categoryChanges.length > 0) {
            result.push(`### ${category}`);
            result.push("");
            categoryChanges.forEach(change => {
              result.push(change.content);
            });
            result.push("");
          }
        }
      }
    } else {
      // Keep non-version lines as-is (like the package name header)
      result.push(line);
      i++;
    }
  }

  // Write the reorganized content back
  fs.writeFileSync(filePath, result.join("\n"));
  console.log(`Reorganized: ${filePath}`);
}

/**
 * Recursively find CHANGELOG.md files
 */
function findChangelogFiles(dir, fileList = []) {
  const files = fs.readdirSync(dir);

  files.forEach(file => {
    const filePath = path.join(dir, file);
    const stat = fs.statSync(filePath);

    if (stat.isDirectory()) {
      // Skip node_modules and hidden directories
      if (file !== "node_modules" && !file.startsWith(".")) {
        findChangelogFiles(filePath, fileList);
      }
    } else if (file === "CHANGELOG.md") {
      fileList.push(filePath);
    }
  });

  return fileList;
}

/**
 * Find and process all CHANGELOG.md files
 */
function main() {
  const rootDir = path.join(__dirname, "..");
  const changelogFiles = findChangelogFiles(rootDir);

  console.log(`Found ${changelogFiles.length} changelog files`);

  changelogFiles.forEach(processChangelog);

  console.log("Done reorganizing changelogs!");
}

main();
