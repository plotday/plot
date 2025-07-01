# Plot

## Local setup

1. [Install asdf](https://asdf-vm.com/)
   1. `brew install asdf`
   1. For each plugin listed in `.tool-versions`, run `asdf plugin add PLUGIN_NAME` (e.g. `asdf plugin add python`)
   1. `asdf install`
1. [Install the 1Password CLI](https://developer.1password.com/docs/cli/get-started/): `brew install 1password-cli`
1. [Install pgFormatter](https://github.com/darold/pgFormatter): `brew install pgformatter`
1. `brew install postgresql`
1. `pnpm install`
1. Add `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_KEY` from the `pnpm start` output to `.env.development.local`.
1. `brew install cocoapods`
1. `asdf install`
1. `dart pub global activate derry`
1. `derry env dev default`

## Local dev

`pnpm dev`

### Updating DB types

After making local changes to the DB, run `pnpm types`. This generates
`libs/db/src/types.ts`, which should be checked in with the changes.

### Generating a migration

Migrations are applied by GitHub Actions. Generate a migration using `pnpm
gen-migration MIGRATION_NAME` and include it with the relevant change.

## Accounts

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
