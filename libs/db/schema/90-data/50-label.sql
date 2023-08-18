-- Synchronize this list with src/event.ts
--
-- Write a manual migration:
-- INSERT INTO label (name)
-- VALUES ('new-label'), ('new-label2');
INSERT INTO label (name)
    VALUES ('meeting'),
    ('project'),
    ('team'),
    ('recruiting'),
    ('internal'),
    ('external'),
    ('social'),
    ('recurring'),
    ('initiated'),
    ('short-notice'),
    ('xs'),
    ('sm'),
    ('md'),
    ('lg'),
    ('xl'),
    ('xxl');

