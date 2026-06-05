BEGIN;
-- pgTAP lives in the `extensions` schema; put it on the search_path so
-- plan()/skip()/finish() resolve (matches the preamble in the other tests).
SET LOCAL search_path = public, extensions;

-- This file was a lint stub for public.upsert_event(), which has since been
-- removed from the schema (event/schedule creation now flows through
-- upsert_thread + schedule sync). There is nothing left to exercise here, so
-- the test is recorded as an explicit, documented skip rather than silently
-- emitting an empty (NOTESTS) plan.
SELECT plan(1);
SELECT skip('upsert_event() removed from schema; nothing left to lint', 1);
SELECT * FROM finish();
ROLLBACK;
