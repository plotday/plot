CREATE TYPE topic_type AS ENUM (
    'public',
    'team',
    'private',
    'announce'
);

CREATE TYPE topic_join_policy AS ENUM (
    'member',
    'open',
    'admin'
);
