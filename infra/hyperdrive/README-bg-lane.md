# Creating the HYPERDRIVE_BG background-lane config

One-time, run by a human with Cloudflare + Cloud SQL access.

1. Create the config (same origin as plot-prod, limit 30). From `workers/api`:

       pnpm wrangler hyperdrive create plot-prod-bg \
         --connection-string="postgres://api:<PASSWORD>@34.130.85.92:5432/plot" \
         --origin-connection-limit=30

   Copy the printed config **id**.

2. Replace `REPLACE_WITH_HYPERDRIVE_BG_ID` with that id in:
   - `workers/api/wrangler.jsonc`
   - `workers/classify/wrangler.jsonc`
   - `scripts/deploy-hyperdrive` (BG_HYPERDRIVE_ID)

3. Lower the frontend pool to 50 and confirm the background pool at 30:

       pnpm --filter @plotday/api run deploy:hyperdrive   # or: bash scripts/deploy-hyperdrive

4. Import the new config into Terraform state (keeps `plan` at zero-diff):

       cd infra/hyperdrive
       terraform import cloudflare_hyperdrive_config.plot_prod_bg <account_id>/<config_id>
       terraform plan   # expect: No changes

5. Deploy api + classify (CI on merge, or manual) so both bind HYPERDRIVE_BG.

Verify: `wrangler hyperdrive get <FRONTEND_ID>` shows 50 and
`wrangler hyperdrive get <BG_ID>` shows 30; sum (80) ≤ ~97 usable origin conns.
