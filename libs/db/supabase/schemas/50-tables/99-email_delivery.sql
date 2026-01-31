-- Email delivery tracking table
-- Tracks every email sent through the system with full lifecycle and retry state

CREATE TABLE email_delivery (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key TEXT NOT NULL UNIQUE,

  -- Email metadata
  template TEXT NOT NULL,  -- 'priority-invitation', 'password-reset', etc.
  to_addresses TEXT[] NOT NULL,
  subject TEXT NOT NULL,
  template_props JSONB,

  -- Delivery state
  status TEXT NOT NULL CHECK (status IN ('pending', 'sent', 'failed', 'expired')),
  retry_count INT NOT NULL DEFAULT 0,
  max_retries INT NOT NULL DEFAULT 10,

  -- Timing
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ,
  last_attempt_at TIMESTAMPTZ,  -- Track when last retry was attempted

  -- Error tracking
  last_error TEXT,
  resend_id TEXT  -- Resend's email ID for lookup
);

-- Indexes
CREATE INDEX email_delivery_created_at_idx ON email_delivery(created_at);
CREATE INDEX email_delivery_status_idx ON email_delivery(status) WHERE status IN ('pending', 'failed');
CREATE INDEX email_delivery_idempotency_key_idx ON email_delivery(idempotency_key);

-- Enable RLS
ALTER TABLE email_delivery ENABLE ROW LEVEL SECURITY;

-- No direct access - only via service role and SECURITY DEFINER functions
-- (emails contain sensitive data and should only be accessed via API functions)
CREATE POLICY email_delivery_no_access ON email_delivery
  FOR ALL
  USING (false);
