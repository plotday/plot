-- Title normalizer for "Archive threads like this" similarity matching.
--
-- Strips conversational/threading prefixes (Re:/Fwd:/Fw:, any nesting and any
-- case), trailing counter suffixes (e.g. "(3)", "[12]", "#4"), and collapses
-- whitespace. Returns NULL for NULL/empty/whitespace-only input so callers
-- can treat "no title" as a non-match without extra guards.
--
-- Used by user.find_auto_archive_candidates to compute a comparable canonical
-- form of two threads' titles so a newsletter whose subject varies only by
-- issue number ("Weekly Digest (47)" vs "Weekly Digest (48)") still matches.
CREATE OR REPLACE FUNCTION public.normalize_title (t text)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
DECLARE
    v text;
BEGIN
    IF t IS NULL THEN
        RETURN NULL;
    END IF;
    v := lower(t);
    -- Strip leading Re:/Fwd:/Fw: prefixes repeatedly (with optional brackets
    -- like "Re[2]:"). Loop until nothing more to strip.
    LOOP
        v := regexp_replace(v, '^\s*(re|fwd|fw)\s*(\[\d+\])?\s*:\s*', '', 'i');
        EXIT WHEN v = lower(t) OR v !~* '^\s*(re|fwd|fw)\s*(\[\d+\])?\s*:';
    END LOOP;
    -- Strip trailing counter suffixes: "(N)", "[N]", "#N", "- N", " N" where
    -- N is a run of digits (with optional commas/decimals/dates won't strip).
    v := regexp_replace(v, '\s*([\(\[]\s*\d+\s*[\)\]]|#\s*\d+|\s-\s*\d+)\s*$', '', 'g');
    -- Collapse whitespace.
    v := regexp_replace(v, '\s+', ' ', 'g');
    v := btrim(v);
    IF v = '' THEN
        RETURN NULL;
    END IF;
    RETURN v;
END;
$$;

COMMENT ON FUNCTION public.normalize_title (text) IS
    'Canonicalize a thread title for similarity matching. Lowercases, strips Re:/Fwd:/Fw: prefixes and trailing (N)/[N]/#N counters, collapses whitespace. Returns NULL on empty input.';
