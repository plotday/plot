-- Clean up orphaned cursor rows from entity name mismatch bug.
-- TwistSync was writing entity='activity' instead of entity='thread',
-- creating rows that never got read back, causing infinite sync loops.
DELETE FROM priority_twist_sync WHERE entity = 'activity';
