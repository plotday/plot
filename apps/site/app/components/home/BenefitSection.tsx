import { Box, Button, Container, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";

import { useScrollReveal } from "~/hooks/useScrollReveal";
import classes from "./BenefitSection.module.css";

interface BenefitSectionProps {
  label?: string;
  title: string;
  body: string;
  image: string;
  imageDark: string;
  imageAlt: string;
  /** Optional WebP source for light mode (preferred when supported). */
  imageWebp?: string;
  /** Optional WebP source for dark mode (preferred when supported). */
  imageDarkWebp?: string;
  /** Intrinsic image width/height — set both to reserve space and avoid layout shift. */
  imageWidth?: number;
  imageHeight?: number;
  cta?: string;
  fade?: boolean;
  reverse?: boolean;
  background?: "white" | "gray";
}

export function BenefitSection({
  label,
  title,
  body,
  image,
  imageDark,
  imageAlt,
  imageWebp,
  imageDarkWebp,
  imageWidth,
  imageHeight,
  cta = "Try Plot →",
  fade = false,
  reverse = false,
  background = "white",
}: BenefitSectionProps) {
  const revealRef = useScrollReveal<HTMLDivElement>();

  return (
    <Box
      className={`${classes.section} reveal`}
      data-bg={background}
      pt={80}
      pb={80}
      ref={revealRef}
    >
      <Container size="lg">
        <Box
          className={`${classes.grid} ${reverse ? classes.gridReverse : ""}`}
        >
          <Stack className={classes.text} gap="md">
            {label && <Text className={classes.label}>{label}</Text>}
            <Title order={2} size="h2" className={classes.sectionTitle}>
              {title}
            </Title>
            <Text className={classes.sectionBody}>{body}</Text>
            <Button
              className={classes.cta}
              variant="subtle"
              component={Link}
              to="/start"
            >
              {cta}
            </Button>
          </Stack>
          <div className={`${classes.imageWrap} ${fade ? classes.fade : ""}`}>
            <picture>
              {imageDarkWebp && (
                <source
                  srcSet={imageDarkWebp}
                  type="image/webp"
                  media="(prefers-color-scheme: dark)"
                />
              )}
              <source
                srcSet={imageDark}
                media="(prefers-color-scheme: dark)"
              />
              {imageWebp && (
                <source srcSet={imageWebp} type="image/webp" />
              )}
              <img
                src={image}
                alt={imageAlt}
                width={imageWidth}
                height={imageHeight}
                className={classes.screenshot}
                loading="lazy"
              />
            </picture>
          </div>
        </Box>
      </Container>
    </Box>
  );
}
