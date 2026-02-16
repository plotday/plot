CREATE TYPE subscription_plan AS ENUM (
    'free'
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

