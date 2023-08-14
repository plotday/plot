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
1. [Install Tusker](https://github.com/bikeshedder/tusker)
1. [Install pgFormatter](https://github.com/darold/pgFormatter) (`brew install pgformatter`)
1. [Instal Airplane](https://docs.airplane.dev/platform/airplane-cli) (`brew install airplanedev/tap/airplane`)
1. `pnpm install`
1. Create `.env` files:
   1. `.env.local`
      1. `SENTRY_AUTH_TOKEN`
      1. `CLOUDFLARE_API_TOKEN`
   1. `.env.local.development`
      1. `SUPABASE_ANON_KEY`
      1. `SUPABASE_SERVICE_KEY`
      1. `GOOGLE_CLIENT_ID`
      1. `GOOGLE_OAUTH_SECRET`
      1. `MICROSOFT_CLIENT_ID`
      1. `MICROSOFT_OAUTH_SECRET`
      1. `SENTRY_DSN`
      1. `TEST_GOOGLE_ACCOUNT_ACCESS_TOKEN`
      1. `TEST_GOOGLE_ACCOUNT_REFRESH_TOKEN`
      1. `TEST_OUTLOOK_ACCOUNT_ACCESS_TOKEN`
      1. `TEST_OUTLOOK_ACCOUNT_REFRESH_TOKEN`
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
