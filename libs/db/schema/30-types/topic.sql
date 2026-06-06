CREATE TYPE topic_join_policy AS ENUM (
    'open',   -- anyone can join or leave
    'admin'   -- only admins manage membership (reserved for team-scoped topics)
);
