CREATE TYPE group_type AS ENUM (
    'public',
    'team',
    'private',
    'announce'
);

CREATE TYPE group_join_policy AS ENUM (
    'member',
    'open',
    'admin'
);

CREATE TYPE group_privacy AS ENUM (
    'open',      -- members see the roster and may address the group (add it to a thread/topic)
    'private'    -- only admins see the roster / address it; members merely receive
);
