-- Users can read their own subscription
CREATE POLICY user_subscription_select_own ON "public"."user_subscription"
    FOR SELECT TO authenticated
    USING (auth.uid () = user_id);
