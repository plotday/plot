INSERT INTO label (id, "order", tag, name, description)
    VALUES (0, 0, '🎯', 'Focus', NULL)
ON CONFLICT (id)
    DO UPDATE SET
        name = EXCLUDED.name, tag = EXCLUDED.tag, "order" = EXCLUDED.order, description = EXCLUDED.description;

