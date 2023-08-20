ALTER TABLE "public"."label"
    ADD COLUMN "description" text;

INSERT INTO label (name, description)
    VALUES ('meeting', 'All meetings'),
    ('recruiting', 'Hiring-related meetings'),
    ('internal', 'Only contacts inside your company are invited'),
    ('external', 'Contacts outside your company are invited'),
    ('recurring', 'Multiple occurrences'),
    ('initiated', 'Meetings you created'),
    ('short-notice', 'Created less than 18 hours before starting'),
    ('1:1', '2 invitess'),
    ('sm', '3-4 invitess'),
    ('md', '5-7 invitess'),
    ('lg', '8-15 invitess'),
    ('xl', '16-29 invitess'),
    ('xxl', '30+ invitess'),
    ('¼h', '≤20 minutes'),
    ('½h', '20-39 minutes'),
    ('¾h', '40-49 minutes'),
    ('1h', '50-74 minutes'),
    ('1½h', '75-100 minutes'),
    ('2h', '101-130 minutes'),
    ('2½h', '131-160 minutes'),
    ('3h', '161-180 minutes'),
    ('½d', '3-5 hours'),
    ('¾d', '>5, <7 hours'),
    ('all-day', '7+ hours'),
    ('speedy', '10-15 minutes less than a 30-minute multiple, or less than 30 minutes in total')
ON CONFLICT (name, user_id)
    DO UPDATE SET
        description = EXCLUDED.description;

