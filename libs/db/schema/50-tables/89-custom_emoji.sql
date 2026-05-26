-- Cache of workspace-custom emoji discovered on chat platforms
-- (Slack workspace emojis, Google Chat custom emojis).
--
-- Reaction rows in note_reaction / thread_reaction refer to custom
-- emoji via the `id` column here, formatted as
-- '<provider>:<workspace_id>/<name>'. Storing the image_url here lets
-- clients render the emoji without per-request token-bound calls to
-- the source platform; the API serves the image via a proxy route
-- that re-signs the upstream URL when needed.
--
-- `alias_of` follows the source platform's alias mechanism (Slack
-- exposes aliased emojis as `alias:<canonical_name>`). Clients should
-- render the alias target's image where set.
CREATE TABLE "public"."custom_emoji" (
    "id" text PRIMARY KEY,
    "provider" text NOT NULL,
    "workspace_id" text NOT NULL,
    "name" text NOT NULL,
    "image_url" text NOT NULL,
    "alias_of" text REFERENCES "public"."custom_emoji" ("id") ON DELETE SET NULL,
    "archived_at" timestamp with time zone,
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

CREATE INDEX idx_custom_emoji_provider_workspace ON "public"."custom_emoji" (provider, workspace_id)
WHERE
    archived_at IS NULL;

CREATE INDEX idx_custom_emoji_seq ON "public"."custom_emoji" ("seq");

CREATE TRIGGER set_custom_emoji_updated_at
    BEFORE INSERT OR UPDATE ON "public"."custom_emoji"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();
