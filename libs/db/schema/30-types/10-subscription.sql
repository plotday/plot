CREATE TYPE subscription_plan AS ENUM (
    'free',
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

CREATE TYPE organization_role AS ENUM (
    'admin',
    'member'
);

