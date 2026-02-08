SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.update_note_tags(p_note_id uuid, p_actor_id uuid, p_client_id integer, p_tag_updates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Validate computed tags for notes
            -- Notes can have 'now' (1), 'done' (3), and 'someday' (7) tags for per-user assignment/completion
            -- But not 'later' (2), 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3, 7) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3, 7 (now, done, someday)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3, 7)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'now' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

-- Update RLS policies for note_tag to allow cross-user assignment for tags 1 (now) and 3 (done)
ALTER POLICY "Users can insert note_tag for notes in their accessible priorit" ON public.note_tag WITH CHECK ((((actor_id = public.user_contact_id()) OR (tag_id = ANY (ARRAY[1, 3]))) AND (EXISTS ( SELECT 1
   FROM (public.note n
     JOIN public.activity a ON ((a.id = n.activity_id)))
  WHERE ((n.id = note_tag.note_id) AND public.user_has_priority_access(( SELECT auth.uid() AS uid), a.priority_id))))));

ALTER POLICY "Users can update note_tag for notes in their accessible priorit" ON public.note_tag USING (((actor_id = public.user_contact_id()) OR (tag_id = ANY (ARRAY[1, 3])) OR (EXISTS ( SELECT 1
   FROM (public.note n
     JOIN public.activity a ON ((a.id = n.activity_id)))
  WHERE ((n.id = note_tag.note_id) AND public.user_has_priority_access(( SELECT auth.uid() AS uid), a.priority_id) AND (public.get_tag_type(note_tag.tag_id) = 'toggle'::public.tag_type))))));

ALTER POLICY "Users can update note_tag for notes in their accessible priorit" ON public.note_tag WITH CHECK (((actor_id = public.user_contact_id()) OR (tag_id = ANY (ARRAY[1, 3]))));
