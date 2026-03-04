-- Drop "source_channel" view
DROP VIEW "user"."source_channel";
-- Modify "source_channel" table
ALTER TABLE "public"."source_channel" ADD COLUMN "create_threads" boolean NOT NULL DEFAULT true;
-- Modify "link" table (must come before trigger that references priority_id)
ALTER TABLE "public"."link" ALTER COLUMN "thread_id" DROP NOT NULL, ADD COLUMN "priority_id" uuid NULL, ADD CONSTRAINT "link_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Create index "idx_link_priority_id" to table: "link"
CREATE INDEX "idx_link_priority_id" ON "public"."link" ("priority_id") WHERE (priority_id IS NOT NULL);
-- Modify "set_link_source_priority_root_trigger" trigger
CREATE OR REPLACE TRIGGER "set_link_source_priority_root_trigger" BEFORE INSERT OR UPDATE OF "priority_id", "source", "thread_id" ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."set_link_source_priority_root"();
-- Modify "ensure_link_assignee_priority_contact" function
CREATE OR REPLACE FUNCTION "public"."ensure_link_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the priority_id from the thread or direct link priority
    IF NEW.thread_id IS NOT NULL THEN
        SELECT
            t.priority_id INTO v_priority_id
        FROM
            thread t
        WHERE
            t.id = NEW.thread_id;
    ELSE
        v_priority_id := NEW.priority_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a priority_twist)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "set_link_source_priority_root" function
CREATE OR REPLACE FUNCTION "public"."set_link_source_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path via the thread or direct priority
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = COALESCE(
                (SELECT t.priority_id FROM public.thread t WHERE t.id = NEW.thread_id),
                NEW.priority_id
            );
        -- Extract the root element (first segment) of the priority path
        IF priority_path IS NOT NULL THEN
            NEW.source_priority_root := subpath (priority_path, 0, 1);
        END IF;
    ELSE
        -- Clear source_priority_root when source is null
        NEW.source_priority_root := NULL;
    END IF;
    RETURN NEW;
END;
$$;
-- Create "source_channel" view
CREATE VIEW "user"."source_channel" (
  "user_id",
  "id",
  "priority_twist_id",
  "channel_id",
  "title",
  "priority_id",
  "enabled",
  "create_threads",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.priority_twist_id,
    sc.channel_id,
    sc.title,
    sc.priority_id,
    sc.enabled,
    sc.create_threads,
    sc.created_at,
    sc.updated_at
   FROM public.source_channel sc
     JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id;
-- Modify "link_x" view
CREATE OR REPLACE VIEW "public"."link_x" (
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "source_priority_root",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "embedding",
  "match",
  "priority_id",
  "priority_path"
) AS SELECT l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.embedding,
    l.match,
    COALESCE(l.priority_id, t.priority_id) AS priority_id,
    COALESCE(pp.path, tp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.thread t ON t.id = l.thread_id
     LEFT JOIN public.priority tp ON tp.id = t.priority_id
     LEFT JOIN public.priority pp ON pp.id = l.priority_id;
