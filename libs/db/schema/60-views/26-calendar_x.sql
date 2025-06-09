CREATE OR REPLACE VIEW public.calendar_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    calendar.*,
    account.user_id
FROM
    public.calendar
    INNER JOIN public.account ON calendar.account_id = account.id;


