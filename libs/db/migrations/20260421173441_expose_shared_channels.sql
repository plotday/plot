-- Create "bump_channel_updated_at_on_link" function
CREATE FUNCTION "public"."bump_channel_updated_at_on_link" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.channel_id IS NULL OR NEW.created_by IS NULL THEN
        RETURN NEW;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM thread_priority tp
            JOIN twist_instance pt ON pt.id = NEW.created_by
        WHERE tp.thread_id = NEW.thread_id
          AND tp.user_id <> pt.owner_id
    ) THEN
        UPDATE channel
        SET updated_at = NOW()
        WHERE twist_instance_id = NEW.created_by
          AND channel_id = NEW.channel_id
          AND updated_at < NOW();
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "bump_channel_on_link_insert"
CREATE TRIGGER "bump_channel_on_link_insert" AFTER INSERT ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."bump_channel_updated_at_on_link"();
-- Create "bump_channel_updated_at_on_thread_priority" function
CREATE FUNCTION "public"."bump_channel_updated_at_on_thread_priority" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE channel sc
    SET updated_at = NOW()
    FROM link l
        JOIN twist_instance pt ON pt.id = l.created_by
    WHERE l.thread_id = NEW.thread_id
      AND sc.channel_id = l.channel_id
      AND sc.twist_instance_id = l.created_by
      AND NEW.user_id <> pt.owner_id
      AND sc.updated_at < NOW();
    RETURN NEW;
END;
$$;
-- Create trigger "bump_channel_on_thread_priority_insert"
CREATE TRIGGER "bump_channel_on_thread_priority_insert" AFTER INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."bump_channel_updated_at_on_thread_priority"();
-- Modify "channel" view
CREATE OR REPLACE VIEW "user"."channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "enabled",
  "link_types",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.created_at,
    sc.updated_at
   FROM public.channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
UNION
 SELECT DISTINCT tp.user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.created_at,
    sc.updated_at
   FROM public.channel sc
     JOIN public.link l ON l.channel_id = sc.channel_id AND l.created_by = sc.twist_instance_id
     JOIN public.thread_priority tp ON tp.thread_id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
  WHERE tp.user_id <> pt.owner_id;
