import { Box, Button, Container, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";

import classes from "./BenefitSection.module.css";

interface BenefitSectionProps {
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
  title,
  body,
  image,
  imageDark,
  imageAlt,
  fade = false,
  reverse = false,
  background = "white",
}: BenefitSectionProps) {
  return (
    <Box className={classes.section} data-bg={background} pt={80} pb={80}>
      <Container size="lg">
        <Box className={`${classes.grid} ${reverse ? classes.gridReverse : ""}`}>
          <Stack className={classes.text} gap="md">
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
              <source srcSet={imageDark} media="(prefers-color-scheme: dark)" />
              <img src={image} alt={imageAlt} className={classes.screenshot} loading="lazy" />
            </picture>
          </div>
        </Box>
      </Container>
    </Box>
  );
}
