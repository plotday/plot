import chalk from "chalk";

// Plot brand colors
export const colors = {
  // Brand green from logo
  brand: (text: string) => chalk.hex("#2B9F7A")(text),
  // Semantic colors
  success: (text: string) => chalk.hex("#2B9F7A")(text),
  error: (text: string) => chalk.red(text),
  warning: (text: string) => chalk.yellow(text),
  info: (text: string) => chalk.cyan(text),
  // Style helpers
  dim: (text: string) => chalk.dim(text),
  bold: (text: string) => chalk.bold(text),
  underline: (text: string) => chalk.underline(text),
};

/**
 * Print a success message with checkmark
 */
export function success(message: string, details?: string[]) {
  console.log(colors.success("✓") + " " + message);
  if (details) {
    details.forEach((detail) => console.log("  " + colors.dim(detail)));
  }
}

/**
 * Print an error message with X mark
 */
export function error(message: string, details?: string) {
  console.log(colors.error("✗") + " " + message);
  if (details) {
    console.log("  " + colors.dim(details));
  }
}

/**
 * Print an info message
 */
export function info(message: string, details?: string[]) {
  console.log(colors.info("ℹ") + " " + message);
  if (details) {
    details.forEach((detail) => console.log("  " + colors.dim(detail)));
  }
}

/**
 * Print a warning message
 */
export function warning(message: string, details?: string[]) {
  console.log(colors.warning("⚠") + " " + message);
  if (details) {
    details.forEach((detail) => console.log("  " + colors.dim(detail)));
  }
}

/**
 * Print a section header
 */
export function section(title: string) {
  console.log("\n" + colors.bold(title));
}

/**
 * Print a progress message
 */
export function progress(message: string) {
  console.log(colors.brand("●") + " " + message);
}

/**
 * Print a list item
 */
export function listItem(item: string) {
  console.log("  " + colors.dim("•") + " " + item);
}

/**
 * Print a key-value pair
 */
export function keyValue(key: string, value: string) {
  console.log("  " + colors.dim(key + ":") + " " + value);
}

/**
 * Print next steps section
 */
export function nextSteps(steps: string[]) {
  section("Next steps");
  steps.forEach((step) => {
    console.log("  " + colors.brand("›") + " " + step);
  });
}

/**
 * Print a subtle branded header
 */
export function header(text: string) {
  console.log("\n" + colors.brand("━".repeat(50)));
  console.log(colors.bold("  " + text));
  console.log(colors.brand("━".repeat(50)) + "\n");
}

/**
 * Print a simple message without formatting
 */
export function plain(message: string) {
  console.log(message);
}

/**
 * Print a blank line
 */
export function blank() {
  console.log();
}

/**
 * Print the CLI header with version
 */
export function cliHeader(version: string) {
  const title = "Plot";
  const subtitle = `Agent Builder v${version}`;
  const underline = colors.brand(
    "─".repeat(title.length + subtitle.length + 1)
  );
  console.log(`\n${title} ${colors.dim(subtitle)}\n${underline}`);
}
