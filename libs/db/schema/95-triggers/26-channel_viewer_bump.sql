-- Keep shared-channel rows reachable through the incremental sync cursor.
--
-- The user.channel view exposes channel rows to any user with a
-- thread_priority row on a thread whose links reference the channel. The
-- Flutter client pulls channel updates ordered by channel.updated_at; for a
-- viewer to receive a channel they just gained access to, that channel's
-- updated_at must be at or after their cursor position.
--
-- Two triggers bump channel.updated_at to cover both admission orders:
--   1. thread_priority INSERT — a user gains access to a thread that already
--      has links with channel_id.
--   2. link INSERT — a link with channel_id is added to a thread that already
--      has non-owner viewers.
--
-- Both guards are "< NOW()" to avoid redundant rewrites within the same
-- transaction. Only bumps channels belonging to twist_instances owned by a
-- different user than the one gaining access, so owners don't re-pull their
-- own rows needlessly.
CREATE OR REPLACE FUNCTION public.bump_channel_updated_at_on_thread_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
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

CREATE OR REPLACE TRIGGER bump_channel_on_thread_priority_insert
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.bump_channel_updated_at_on_thread_priority ();

CREATE OR REPLACE FUNCTION public.bump_channel_updated_at_on_link ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
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

CREATE OR REPLACE TRIGGER bump_channel_on_link_insert
    AFTER INSERT ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.bump_channel_updated_at_on_link ();
