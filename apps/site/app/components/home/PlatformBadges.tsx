import { Flex, Text } from "@mantine/core";

import {
  IconBrandAndroid,
  IconBrandApple,
  IconBrandWindows,
  IconWorld,
} from "@tabler/icons-react";

import classes from "./PlatformBadges.module.css";

const PLATFORMS = [
  { label: "Mac", icon: IconBrandApple },
  { label: "Windows", icon: IconBrandWindows },
  { label: "iOS", icon: IconBrandApple },
  { label: "Android", icon: IconBrandAndroid },
  { label: "Web", icon: IconWorld },
];

/**
 * A compact, understated row of the platforms Plot runs on. Used as an
 * "available everywhere" signal next to the conversion CTAs.
 * - `tone="muted"` for light backgrounds (hero)
 * - `tone="onDark"` for the brand-colored closing CTA
 */
export function PlatformBadges({
  tone = "muted",
}: {
  tone?: "muted" | "onDark";
}) {
  return (
    <Flex
      gap="lg"
      rowGap="xs"
      wrap="wrap"
      justify="center"
      className={tone === "onDark" ? classes.onDark : classes.muted}
    >
      {PLATFORMS.map(({ label, icon: Icon }) => (
        <Flex key={label} align="center" gap={6} className={classes.item}>
          <Icon size={16} stroke={1.6} />
          <Text span className={classes.label}>
            {label}
          </Text>
        </Flex>
      ))}
    </Flex>
  );
}
