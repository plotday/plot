# Plot

## Stack

Based on [Resupaflare](https://github.com/PlotTech/resupaflare).

To pull the latest changes from that repo:

```bash
git pull resupaflare main
git push origin main
```

## Local setup

1. [Install pnpm](https://pnpm.io/installation)
1. [Install pgFormatter](https://github.com/darold/pgFormatter) (on MacOS: `brew install pgformatter`)
1. `pnpm install`
1. Create `.env.development.local` and add the required variables from
   `.env.development`
1. `pnpm dlx supabase link --project-ref PROJECT_ID`

## Local dev

`pnpm dev`

### Updating DB types

After making local changes to the DB, run `pnpm gen-types`. This generates
`libs/db/src/types.ts`, which should be checked in with the changes.

### Generating a migration

Migrations are applied by GitHub Actions. Generate a migration using `pnpm
gen-migration MIGRATION_NAME` and include it with the relevant change.

## Updating Remix

Remix is patched to fix the sourcemap path escaping for Cloudflare functions.

To update the patch for a new Remix version:

1. `pnpm patch @remix-run/dev@[VERSION]`
1. Edit `[TMP_PATH]/dist/compiler/server/write.js` (see the previous diff for the change).
1. `pnpm patch-commit [TMP_PATH]`

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
