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
              Try Plot →
            </Button>
          </Stack>
          <div className={`${classes.imageWrap} ${fade ? classes.fade : ""}`}>
            <picture>
              <source
                srcSet={imageDark}
                media="(prefers-color-scheme: dark)"
              />
              <img
                src={image}
                alt={imageAlt}
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
