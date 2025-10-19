const { getInfo } = require("@changesets/get-github-info");

/**
 * Custom changelog formatter for Plot project
 * Follows "Keep a Changelog" standard with categories:
 * Added, Changed, Deprecated, Removed, Fixed, Security
 *
 * Expects changeset summaries to be prefixed with category, e.g.:
 * "Added: new feature"
 * "Fixed: bug description"
 */

const CATEGORIES = [
  "Added",
  "Changed",
  "Deprecated",
  "Removed",
  "Fixed",
  "Security"
];

const CATEGORY_PATTERN = new RegExp(`^(${CATEGORIES.join("|")}):\\s*`, "i");

/**
 * Parse a changeset summary to extract category and content
 */
function parseChangeset(summary) {
  const match = summary.match(CATEGORY_PATTERN);

  if (match) {
    const category = match[1].charAt(0).toUpperCase() + match[1].slice(1).toLowerCase();
    const content = summary.slice(match[0].length);
    return { category, content };
  }

  // Default to "Changed" if no category prefix found
  return { category: "Changed", content: summary };
}

/**
 * Format a single release line for a changeset
 */
async function getReleaseLine(changeset, type, options) {
  if (!options || !options.repo) {
    throw new Error("Must provide options.repo for changelog-formatter");
  }

  const { summary } = changeset;
  const { category, content } = parseChangeset(summary);

  let links = "";

  try {
    const info = await getInfo({
      repo: options.repo,
      commit: changeset.commit,
    });

    // Format: [#PR](link) [`hash`](link)
    const prLink = info.pull ? `[#${info.pull}](${info.links.pull})` : null;
    const commitLink = info.commit ? `[\`${info.commit.slice(0, 7)}\`](${info.links.commit})` : null;

    const linkParts = [prLink, commitLink].filter(Boolean);
    if (linkParts.length > 0) {
      links = ` (${linkParts.join(" ")})`;
    }
  } catch (error) {
    // If we can't get GitHub info, just continue without links
    console.warn("Could not get GitHub info for changeset:", error.message);
  }

  // Include category as HTML comment for post-processing
  return `<!-- CATEGORY:${category} -->${content}${links}`;
}

/**
 * Format dependency update lines
 */
async function getDependencyReleaseLine(changesets, dependenciesUpdated, options) {
  if (changesets.length === 0) return "";

  const updatedDependencies = dependenciesUpdated.map(
    (dependency) => `  - ${dependency.name}@${dependency.newVersion}`
  );

  return ["<!-- CATEGORY:Changed -->Updated dependencies:", ...updatedDependencies].join("\n");
}

module.exports = {
  getReleaseLine,
  getDependencyReleaseLine,
};
