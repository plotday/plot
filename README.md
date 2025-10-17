# Plot

## Local setup

1. [Install asdf](https://asdf-vm.com/)
   1. `brew install asdf`
   1. For each plugin listed in `.tool-versions`, run `asdf plugin add PLUGIN_NAME` (e.g. `asdf plugin add python`)
   1. `asdf install`
1. [Install the 1Password CLI](https://developer.1password.com/docs/cli/get-started/): `brew install 1password-cli`
1. [Install pgFormatter](https://github.com/darold/pgFormatter): `brew install pgformatter`
1. `brew install postgresql`
1. `brew install cocoapods`
1. **Initialize the SDK submodule**
   1. Initialize and update submodules: `git submodule update --init --recursive`
   1. Build the SDK: `cd public/sdk && pnpm install && pnpm build && cd ../..`
   1. Note: The SDK repo is included as a git submodule in `public/` and linked as a workspace dependency in `pnpm-workspace.yaml`, allowing local development of SDK types before publishing
1. `pnpm install`
1. Add `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_KEY` from the `pnpm start` output to `.env.development.local`.
1. `pnpm run env`

## Local dev

`pnpm dev`

### Updating DB types

After making local changes to the DB, run `pnpm types`. This generates
`libs/db/src/types.ts`, which should be checked in with the changes.

### Generating a migration

Migrations are applied by GitHub Actions. Generate a migration using `pnpm
gen-migration MIGRATION_NAME` and include it with the relevant change.

### Working with SDK types

SDK type definitions (Activity, Priority, Agent, Tool interfaces, etc.) are maintained in the `public/sdk/src/` directory as the single source of truth. The API worker and agents in this repo use these types via workspace links.

**To modify SDK types:**

1. Edit files in `public/sdk/src/` (e.g., `agent.ts`, `plot.ts`, `tools/*.ts`)
2. Rebuild the SDK: `cd public/sdk && pnpm build && cd ../..`
3. Changes are immediately available to the API and agents in this repo
4. Test your changes locally before publishing

**To publish SDK changes:**

1. Update version in `public/sdk/package.json`
2. Build: `cd public/sdk && pnpm build`
3. Publish: `npm publish` (from the `public/sdk` directory)
4. Commit and push changes to the SDK submodule, then commit the submodule reference update in this repo

**Note:** The SDK repo is included as a git submodule in `public/` and linked in `pnpm-workspace.yaml`, allowing you to develop and test SDK changes locally without publishing to npm first.

## Accounts

- [GitHub](https://github.com/orgs/plotday/teams/development/members)
- [1Password](https://plotco.1password.com/vaults/details/opfjdkmleais6inytphoetcf3y)
- [Linear](https://linear.app/plotday/settings/members)
- [Supabase](https://supabase.com/dashboard/org/zjomdxrdnixcnkpqxcmg/team)
- [Cloudflare](https://dash.cloudflare.com/34ceb662899230b63c7e8114eaf9277c/members)

## Hosting setup

### Cloudflare

1. Create a new Pages application with the following settings:
   1. Build command: `pnpm run build:web`
   1. Build output directory: `/apps/web/public`
   1. Root directory: `/`

### Supabase

Create two projects, one for production and the other for staging.

### GitHub Actions

1. Add these organization or repo secrets
   1. `SUPABASE_ACCESS_TOKEN` ([generate](https://supabase.com/dashboard/account/tokens))
   2. `CLOUDFLARE_API_TOKEN` ([generate](https://dash.cloudflare.com/profile/api-tokens))
   3. `SENTRY_AUTH_TOKEN` ([generate](https://useplot.sentry.io/settings/account/api/auth-tokens/))
1. Create `staging` and `production` environments
1. Add environment secrets
   1. `SUPABASE_DB_PASSWORD`
1. Add environment variables
   1. `DEPLOY_ENV`
   2. `SUPABASE_PROJECT_ID`
