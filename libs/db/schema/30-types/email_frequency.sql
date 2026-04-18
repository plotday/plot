-- Email notification frequency preference. Controls how often the
-- EmailNotify Durable Object is allowed to send notification digest
-- emails to a user. NULL = default behavior (daily).
CREATE TYPE email_frequency AS ENUM ('daily', 'weekly', 'never');
