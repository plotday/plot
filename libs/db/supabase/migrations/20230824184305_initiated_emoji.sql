INSERT INTO label (id, "order", tag, name, description)
    VALUES (1, 10, '💼', 'All meetings', NULL),
    (2, 100, '👥', '1:1', '2 invitees'),
    (3, 110, '👥', 'Small', '3-4 invitees'),
    (4, 120, '👥', 'Medium', '5-7 invitees'),
    (5, 130, '👥', 'Large', '8-15 invitees'),
    (6, 140, '👥', 'XL', '16-29 invitees'),
    (7, 150, '👥', 'XXL', '30+ invitees'),
    (8, 200, '🏢', 'Internal', 'Only invitees from your company'),
    (9, 210, '🤝', 'External', 'Includes invitees from outside your company'),
    (10, 300, '⏳', '¼ hr', '≤20 minutes'),
    (11, 310, '⏳', '½ hr', '20-39 minutes'),
    (12, 320, '⏳', '¾ hr', '40-49 minutes'),
    (13, 330, '⏳', '1 hr', '50-74 minutes'),
    (14, 340, '⏳', '1½ hr', '75-100 minutes'),
    (15, 350, '⏳', '2 hr', '101-130 minutes'),
    (16, 360, '⏳', '2½ hr', '131-160 minutes'),
    (17, 370, '⏳', '3 hr', '161-180 minutes'),
    (18, 380, '⏳', '½ day', '3-5 hours (inclusive)'),
    (19, 390, '⏳', '¾ day', '5-7 hours (exclusive)'),
    (20, 400, '⏳', 'All day', '7+ hours'),
    (21, 500, '🔁', 'Recurring', NULL),
    (22, 530, '🚨', 'Short notice', 'Created less than 18 hours before starting'),
    (23, 560, '💨', 'Speedy', 'Shortened by 5-15 minutes from a 30-minute interval'),
    (24, 600, '✋', 'Initiated', 'Meetings you organize')
ON CONFLICT (id)
    DO UPDATE SET
        name = EXCLUDED.name, tag = EXCLUDED.tag, "order" = EXCLUDED.order, description = EXCLUDED.description;

