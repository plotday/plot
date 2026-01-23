-- Allow users with priority access to manage invitations
CREATE POLICY "Users can manage invitations for their priorities" ON public.priority_invitation
    FOR ALL TO authenticated
        USING (public.user_has_priority_access (auth.uid (), priority_id));

-- Allow invitees to view their own invitations (via their contact record)
CREATE POLICY "Invitees can view their invitations" ON public.priority_invitation
    FOR SELECT TO authenticated
        USING (
            contact_id IN (
                SELECT
                    id
                FROM
                    public.contact
                WHERE
                    user_id = auth.uid ()
                    AND archived_at IS NULL));

