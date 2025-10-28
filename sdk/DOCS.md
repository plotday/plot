# Plot SDK Documentation

This directory contains the TypeDoc-generated API documentation for the Plot Agent SDK.

## Published Documentation

The SDK documentation is automatically published to GitHub Pages whenever changes are pushed to the main branch:

**Live Documentation**: [https://plotday.github.io/plot/](https://plotday.github.io/plot/)

The documentation is automatically updated whenever changes to the SDK are merged into the main branch, ensuring developers always have access to the latest API reference.

## Generating Documentation

The documentation is automatically generated during the build process, but you can also generate it manually.

### Generate Documentation

```bash
# From the SDK directory
pnpm docs
```

This will create the documentation in `dist/docs/`

### Clean Documentation

```bash
# Remove the generated docs
pnpm docs:clean
```

## Viewing Documentation Locally

After generating the documentation, you can view it by opening the generated HTML files in your browser:

```bash
# Cross-platform way (recommended)
pnpm docs:open
```

This script automatically uses the correct command for your platform:
- `open` on macOS
- `xdg-open` on Linux
- `start` on Windows

You can also open it manually:

```bash
# macOS
open dist/docs/index.html

# Linux
xdg-open dist/docs/index.html

# Windows
start dist/docs/index.html
```

## Documentation Structure

The generated documentation includes:

- **Classes** - Agent, Tool, and built-in tool classes
- **Interfaces** - Activity, Priority, Contact, and other data types
- **Enums** - ActivityType, AuthorType, ActivityLinkType, etc.
- **Type Aliases** - NewActivity, NewPriority, and utility types
- **Modules** - Organized by functionality (tools, common, utils)

## Publishing Documentation

The documentation is automatically published in two ways:

### 1. GitHub Pages (Automatic)

When changes to the SDK are pushed to the main branch, a GitHub Action automatically:
- Builds the SDK and generates the documentation
- Deploys it to GitHub Pages at [https://plotday.github.io/plot/](https://plotday.github.io/plot/)

**Workflow Location**: `.github/workflows/deploy-sdk-docs.yml`

**Trigger**: Automatic on push to `main` when files in `public/sdk/**` change

### 2. npm Package (Manual)

The documentation is included when the package is built and published to npm. Users can access it by:

1. Viewing online at GitHub Pages (see above)
2. Exploring the `dist/docs/` directory in the published npm package
3. Using TypeScript language server features in their IDE for inline documentation

### GitHub Pages Setup

If you need to enable or configure GitHub Pages for this repository:

1. Go to Repository Settings → Pages
2. Under "Source", select: **GitHub Actions**
3. The workflow will automatically handle deployment

The `deploy-sdk-docs.yml` workflow includes all necessary permissions and configurations for GitHub Pages deployment.

## Configuration

The documentation generation is configured in `typedoc.json`. Key settings:

- **Entry Points**: Main SDK exports (agent, tool, plot, tools/*)
- **Output**: `dist/docs/`
- **Visibility**: Public APIs only (excludes private/protected/internal members)
- **Theme**: Default TypeDoc theme optimized for GitHub Pages
- **Source Links**: Links to source code on GitHub

## Customization

To modify the documentation output:

1. Edit `typedoc.json` to change TypeDoc settings
2. Adjust which files are documented by modifying the `entryPoints` array
3. Customize the theme, navigation, or sorting options

See the [TypeDoc documentation](https://typedoc.org/) for more configuration options.

## Contributing

When adding new public APIs:

1. Add comprehensive JSDoc comments to your code
2. Use `@param` tags for function parameters
3. Use `@returns` tag for return values
4. Use `@example` tags to show usage examples
5. Use `@see` tags to link to related APIs
6. Regenerate docs with `pnpm docs` to verify formatting

### JSDoc Example

```typescript
/**
 * Creates a new activity in the current priority.
 *
 * Activities are the core data type in Plot, representing tasks, events, and notes.
 * This method creates a new activity with the specified properties.
 *
 * @param activity - The activity data to create
 * @returns Promise resolving to the created activity with its generated ID
 *
 * @example
 * ```typescript
 * const activity = await this.tools.plot.createActivity({
 *   type: ActivityType.Task,
 *   title: "Review pull request",
 *   links: [{
 *     type: ActivityLinkType.external,
 *     title: "View PR",
 *     url: "https://github.com/org/repo/pull/123"
 *   }]
 * });
 * ```
 *
 * @see {@link Activity} for the full activity type definition
 * @see {@link ActivityType} for available activity types
 */
abstract createActivity(activity: NewActivity): Promise<Activity>;
```

## Support

For issues or questions about the documentation:

- Open an issue at https://github.com/plotday/plot/issues
- Tag it with the `documentation` label
