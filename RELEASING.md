# Releasing Packages

This repository uses [Changesets](https://github.com/changesets/changesets) to manage versioning and publishing of the Twist Creator SDK (`@plotday/twister`) to npm.

## Package Versioning Strategy

Only `@plotday/twister` is published to npm via changesets. Everything else (`@plotday/connector-*`, `@plotday/twist-*`) is listed under `ignore` in `.changeset/config.json`:

- **Twist Creator** (`@plotday/twister`): Published to npm; versioned via changesets
- **Connectors** (`@plotday/connector-*`): Ignored by changesets — deployed via `plot deploy`, not npm
- **Twists** (`@plotday/twist-*`): Ignored by changesets — deployed via `plot deploy`, not npm

**Only create changesets for changes to `twister/`.** A changeset that targets only ignored packages will never resolve: `changeset version` leaves the file in place, so every subsequent run of the release workflow treats it as a pending release, produces an empty diff, and fails to open a release PR (`No commits between main and changeset-release/main`). The `pnpm validate-changesets` CI check rejects these up front.

Changes to connectors or twists do **not** need a changeset — the PR-level changeset check (`changeset-check.yml`) only requires one when files under `twister/` are modified.

## How to Add a Changeset

When you make changes under `twister/`, you need to add a changeset before merging your PR.

### 1. Create a Changeset

```bash
pnpm changeset
```

This will prompt you with:

1. **Which packages would you like to include?**

   - Select `@plotday/twister` (use space to select, enter to confirm)
   - Do **not** select any `@plotday/connector-*` or `@plotday/twist-*` package — they are ignored and will block the release workflow

2. **What kind of change is this?**

   - `major`: Breaking changes (e.g., removing or changing public APIs)
   - `minor`: New features (backward compatible)
   - `patch`: Bug fixes and minor improvements

3. **Summary of changes**
   - Write a clear description of what changed
   - This will appear in the CHANGELOG
   - Use imperative mood (e.g., "Add new feature" not "Added new feature")

### 2. Commit the Changeset

```bash
git add .changeset/*.md
git commit -m "Add changeset for [brief description]"
```

The changeset file will be created in `.changeset/` with a random name like `.changeset/brave-lions-dance.md`.

## Release Process

### Automated Release Workflow

1. **Developer makes changes**

   - Make your changes to builder or tools packages
   - Run `pnpm changeset` to add a changeset
   - Commit the changeset file along with your changes
   - Open a PR to `main`

2. **PR validation**

   - GitHub Actions will check if builder/tools were modified
   - If modified, it ensures a changeset file exists
   - PR cannot be merged without a changeset (or admin override)

3. **After PR merge to main**

   - GitHub Actions automatically runs the release workflow
   - Creates or updates a "Version Packages" PR
   - This PR:
     - Bumps versions in `package.json` files
     - Updates `CHANGELOG.md` files
     - Removes consumed changeset files

4. **Publishing**
   - When the "Version Packages" PR is merged
   - GitHub Actions automatically:
     - Builds all packages
     - Publishes changed packages to npm
     - Creates GitHub releases with changelogs
     - Tags each release (e.g., `twister@0.9.1`, `tool-google-calendar@0.1.0`)

## GitHub Releases

When packages are published, GitHub releases are automatically created with the following details:

### Release Tags

The Twist Creator release gets a tag of the form `twister@<version>` (e.g. `twister@0.45.0`).

This tagging convention allows you to:

- Track releases independently from submodule commits
- Clone or checkout a specific published version

### Release Notes

Each GitHub release includes:

- **Title**: Package name and version (e.g., `@plotday/twister@0.9.1`)
- **Release Notes**: Automatically extracted from the package's CHANGELOG.md for that version
- **Assets**: None (packages are distributed via npm)

### Finding Releases

View all releases at: `https://github.com/plotday/plot/releases`

### Manual GitHub Release

If you need to create a GitHub release manually after publishing:

```bash
gh release create twister@0.45.0 --title "@plotday/twister@0.45.0" --notes "Release notes here"
```

## Changeset Best Practices

### Writing Good Changeset Summaries

**Good examples:**

```
- Fix calendar sync race condition causing duplicate events
- Add support for recurring events in Google Calendar integration
- BREAKING: Remove deprecated `createTwist()` function
```

**Bad examples:**

```
- Fixed bug
- Updates
- Changed some code
```

### When to Use Each Version Type

**Major (Breaking Changes)**

- Removing public APIs
- Changing function signatures
- Changing behavior in backward-incompatible ways

**Minor (New Features)**

- Adding new functions or methods
- Adding new optional parameters
- New capabilities that don't break existing code

**Patch (Bug Fixes & Improvements)**

- Fixing bugs
- Performance improvements
- Documentation updates
- Refactoring without API changes

### Multiple Changesets

You can create multiple changesets for a single PR if:

- Changes affect multiple packages independently
- Different changes have different version bump types
- You want to separate concerns in the changelog

Just run `pnpm changeset` multiple times.

## Manual Release (Emergency)

If you need to manually publish a package:

```bash
# 1. Update versions and changelogs
pnpm version-packages

# 2. Review the changes
git diff

# 3. Commit version changes
git add .
git commit -m "chore: version packages"
git push

# 4. Build and publish
pnpm release

# 5. (Optional) Create GitHub release manually
gh release create twister@0.9.1 --title "@plotday/twister@0.9.1" --notes "Release notes"
```

⚠️ This should only be done in emergencies. The automated workflow is preferred.

## Troubleshooting

### "No changeset found" error in PR

**Solution:** Run `pnpm changeset` and commit the generated file.

### Changeset not detecting my package

**Problem:** You modified a connector or twist package.
**Solution:** Connectors (`@plotday/connector-*`) and twists (`@plotday/twist-*`) are ignored by changesets — only `@plotday/twister` is published to npm. No changeset is needed for connector/twist-only changes.

### Release workflow fails with "No commits between main and changeset-release/main"

**Cause:** One or more pending changesets target only packages in the `.changeset/config.json` ignore list. `changeset version` consumes them without producing any file changes, so the release PR has an empty diff.
**Solution:** Delete the offending changesets from `.changeset/` on `main`. The `validate-changesets` CI check should catch these at PR time — if one slipped through, it was likely added before that check existed.

### Version Packages PR has conflicts

**Solution:** Merge `main` into the Version Packages PR branch to resolve conflicts.

### Publishing failed

**Possible causes:**

- NPM_TOKEN is invalid or expired → Regenerate and update in GitHub secrets
- Version already exists on npm → Check if package was already published
- Build failed → Check build logs in GitHub Actions

### GitHub release creation failed

**Possible causes:**

- Tag already exists → Release may have been created previously
- GITHUB_TOKEN lacks permissions → Check repository settings
- Invalid tag name → Verify package directory structure matches expectation

**Solution:** Check the GitHub Actions logs for the specific error. You can manually create the release using the `gh` CLI if needed.

## Resources

- [Changesets documentation](https://github.com/changesets/changesets)
- [Semantic Versioning (semver)](https://semver.org/)
- [Plot repository](https://github.com/plotday/plot)
