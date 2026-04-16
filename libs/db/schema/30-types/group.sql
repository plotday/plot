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
