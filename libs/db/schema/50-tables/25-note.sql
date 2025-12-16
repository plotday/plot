CREATE TABLE "public"."note" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL DEFAULT auth.uid(),
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "content" text, -- markdown
    "links" jsonb,
    "mentions" uuid[]
);

COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by twists on behalf of contacts or users, this is the contact/user. For notes created directly by users or twists, this is the user/twist ID.';

COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or priority_twist_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of actor IDs (user_id, contact_id, or priority_twist_id) that are mentioned in this note via @-mentions.';

-- Index for FK lookups
CREATE INDEX idx_note_activity_id ON "public"."note" ("activity_id");

-- Index for ordering by created_at within an activity
CREATE INDEX idx_note_created_at ON "public"."note" ("activity_id", "created_at");

-- Composite index for common join + filter pattern in user_activity_unread and other views
CREATE INDEX idx_note_activity_archived ON "public"."note" ("activity_id", "archived_at");

-- Support unread calculation filters (n.author_id <> c.id with n.archived_at IS NULL)
CREATE INDEX idx_note_author_activity ON "public"."note" ("activity_id", "author_id")
WHERE
    archived_at IS NULL;

-- Support mention array queries in user_activity view (mentions @> ARRAY[user_id])
CREATE INDEX idx_note_mentions ON "public"."note" USING gin ("mentions")
WHERE
    mentions IS NOT NULL
    AND archived_at IS NULL;

-- Ensure only one draft note per user per activity (excluding archived drafts)
CREATE UNIQUE INDEX idx_note_unique_draft_per_user_activity ON "public"."note" ("created_by", "activity_id")
WHERE
    draft = TRUE
    AND archived_at IS NULL;

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_note_updated_at
    BEFORE UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_note_author_and_created_by
    BEFORE INSERT ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER note_change_api_call
    AFTER INSERT OR UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_internal_api_for_note ();

