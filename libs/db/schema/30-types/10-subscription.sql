CREATE TYPE subscription_plan AS ENUM (
    'free',
    'core',
    'pro',
    'team'
);

CREATE TYPE subscription_status AS ENUM (
    'active',
    'canceled',
    'past_due',
    'trialing',
    'incomplete',
    'incomplete_expired',
    'unpaid'
);

CREATE TYPE team_role AS ENUM (
    'admin',
    'member'
);

