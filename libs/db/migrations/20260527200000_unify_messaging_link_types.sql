-- Collapse compose-only / DM-specific link types so the filter UI collapses
-- to one chip per user-perceived thread type. See:
--   public/twister/src/tools/integrations.ts (new LinkTypeConfig.compose shape)
--   public/connectors/{gmail,slack,google-chat,ms-teams}/src (collapsed linkTypes)

-- Data migration only — no schema delta.
UPDATE link SET type = 'email'  WHERE type = 'gmail-email';
UPDATE link SET type = 'thread' WHERE type IN ('message', 'slack-channel', 'google-chat-space', 'teams-channel');
UPDATE link SET type = 'dm'     WHERE type IN ('slack-dm', 'google-chat-dm', 'teams-dm');

-- thread.icon encodes "connector:<twistId>:<type>" for compose-created links —
-- recompute it from the new link.type so the filter chips collapse on the
-- first read after deploy without waiting for a sync touch.
UPDATE thread t SET icon = 'connector:' || l.twist_id::text || ':email'
  FROM link l WHERE l.thread_id = t.id AND t.icon LIKE 'connector:%:gmail-email';

UPDATE thread t SET icon = 'connector:' || l.twist_id::text || ':thread'
  FROM link l WHERE l.thread_id = t.id
    AND t.icon ~ 'connector:.*:(message|slack-channel|google-chat-space|teams-channel)$';

UPDATE thread t SET icon = 'connector:' || l.twist_id::text || ':dm'
  FROM link l WHERE l.thread_id = t.id
    AND t.icon ~ 'connector:.*:(slack-dm|google-chat-dm|teams-dm)$';

-- Caveat: today's `type='message'` rows include both channel posts AND DMs
-- (sync emitted the same type for both). The UPDATE above retypes them all
-- to `thread`. DM-flagged rows self-heal to `dm` on the next sync touch
-- (graph-api's transformDmThread / equivalent now emits `dm`). Filter UI
-- shows them under "Slack thread" / "Google Chat thread" / "Teams thread"
-- in the interim — bounded by the next sync interval per thread.
