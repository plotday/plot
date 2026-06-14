# Publishing New Packages to npm

The public repo uses
[npm trusted publishing](https://docs.npmjs.com/generating-provenance-statements#publishing-packages-with-provenance-via-github-actions)
via GitHub Actions OIDC. This means no npm tokens are stored as secrets — authentication happens
automatically via the release workflow.

New packages require a one-time manual first publish followed by trusted publisher configuration on
npmjs.com.

## Steps

### 1. First publish manually

Trusted publishing can only be configured on packages that already exist on npm. Publish the initial
version manually:

```bash
cd public/tools/<name>
pnpm build
npm publish --access public
```

You must be logged in to npm as a member of the `@plotday` org with publish permissions.

### 2. Configure trusted publishing on npmjs.com

1. Go to <https://www.npmjs.com/package/@plotday/tool-{name}/access>
2. Under **Publishing access**, click **Add trusted publisher**
3. Fill in:
   - **Registry**: `GitHub Actions`
   - **Repository owner**: `plotday`
   - **Repository name**: `plot`
   - **Workflow filename**: `release.yml`
   - **Environment**: leave blank
4. Save

### 3. Verify

After setup, the release workflow (`.github/workflows/release.yml`) handles all future publishes
automatically via changesets. Merge a PR with a changeset for the new package and confirm the
release workflow succeeds.

## Troubleshooting

### `npm error 404 Not Found - PUT` on publish

The package either doesn't exist on npm yet (do step 1) or doesn't have trusted publishing
configured (do step 2). You can check the current publisher with:

```bash
npm view @plotday/tool-<name> --json | jq '._npmUser'
```

- `"GitHub Actions"` with `trustedPublisher` = correctly configured
- A username like `happenator` = manually published, needs trusted publisher setup

### Git ref lock error (`cannot lock ref`)

Transient race condition when multiple PRs merge to main simultaneously. The next run self-heals. No
action needed.
