# Releasing Packages

This repository uses [Changesets](https://github.com/changesets/changesets) to manage versioning and publishing of packages. This guide explains how to create releases for builder and tools packages.

## Package Versioning Strategy

- **Twist Creator** (`@plotday/twister`): Independent versioning
- **Tools** (`@plotday/tool-*`): Independent versioning
- **Twists** (`@plotday/twist-*`): Not published, excluded from releases

Each package maintains its own version and can be released independently.

## How to Add a Changeset

When you make changes to the builder or any tools package, you need to add a changeset before merging your PR.

### 1. Create a Changeset

```bash
pnpm changeset
```

This will prompt you with:

1. **Which packages would you like to include?**

   - Select the packages you've modified (use space to select, enter to confirm)
   - Only builder and tools packages can be selected (twists are excluded)

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

Each package gets its own tag based on its directory structure:

- **Twist Creator**: `twister@0.9.1`
- **Tools**: `tool-google-calendar@0.1.0`, `tool-outlook-calendar@0.1.0`, etc.

This tagging convention allows you to:

- Track releases for each package independently
- Easily identify which package a release belongs to
- Clone or checkout specific package versions

### Release Notes

Each GitHub release includes:

- **Title**: Package name and version (e.g., `@plotday/twister@0.9.1`)
- **Release Notes**: Automatically extracted from the package's CHANGELOG.md for that version
- **Assets**: None (packages are distributed via npm)

### Finding Releases

View all releases at: `https://github.com/plotday/plot/releases`

Or filter by package:

- Builder releases: Search for tags starting with `twister@`
- Tool releases: Search for tags starting with `tool-`

### Manual GitHub Release

If you need to create a GitHub release manually after publishing:

```bash
# For Twist Creator
gh release create twister@0.9.1 --title "@plotday/twister@0.9.1" --notes "Release notes here"

# For a tool
gh release create tool-google-calendar@0.1.0 --title "@plotday/tool-google-calendar@0.1.0" --notes "Release notes here"
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

**Problem:** You modified a twist package.
**Solution:** Twists are excluded from releases. No changeset needed for twist-only changes.

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
