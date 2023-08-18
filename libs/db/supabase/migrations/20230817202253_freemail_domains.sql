ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_domain_unique" UNIQUE (DOMAIN);

INSERT INTO "public"."domain" ("domain")
    VALUES ('icloud.com'),
    ('proton.me')
ON CONFLICT ("domain")
    DO UPDATE SET
        organization_id = NULL;

