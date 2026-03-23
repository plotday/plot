import type {
  CSSVariablesResolver,
  MantineThemeOverride,
  VariantColorsResolver,
} from "@mantine/core";
import {
  Anchor,
  Button,
  Chip,
  createTheme,
  defaultVariantColorsResolver,
  parseThemeColor,
  rgba,
} from "@mantine/core";

import classes from "./theme.module.css";

const variantColorResolver: VariantColorsResolver = (input) => {
  const defaultResolvedColors = defaultVariantColorsResolver(input);
  const parsedColor = parseThemeColor({
    color: input.color || input.theme.primaryColor,
    theme: input.theme,
  });

  if (input.variant === "filled" && parsedColor.variable) {
    return {
      ...defaultResolvedColors,
      background: `var(${parsedColor.variable.replace(
        "-filled",
        "-background",
      )})`,
      hover: `var(${parsedColor.variable.replace("-filled", "-hover")})`,
      color: `var(${parsedColor.variable.replace(
        "-filled",
        "-filled-foreground",
      )})`,
    };
  }

  return defaultResolvedColors;
};

export const theme: MantineThemeOverride = createTheme({
  fontFamily: "'Instrument Sans', sans-serif",
  colors: {
    brand: [
      "#bdffe3",
      "#96edc7",
      "#7ed7b1",
      "#66c29c",
      "#4ab088",
      "#239870",
      "#01845e",
      "#016e4e",
      "#00593f",
      "#00452a",
    ],
    secondary: [
      "#f9edf8",
      "#e7d6e5",
      "#d9bdd6",
      "#cca4c9",
      "#bf8abb",
      "#ab74a7",
      "#946390",
      "#7b5278",
      "#654262",
      "#4f334d",
    ],
  },
  primaryColor: "brand",
  primaryShade: { light: 6, dark: 4 },
  defaultGradient: {
    from: "brand",
    to: "secondary",
    deg: 45,
  },
  variantColorResolver,
  components: {
    Anchor: Anchor.extend({ classNames: classes }),
    Button: Button.extend({
      vars: (_theme, props) => {
        if (props.variant === "gradient") {
          return {
            root: {
              "--button-bg":
                "linear-gradient(45deg, var(--mantine-color-secondary-background) 0%, var(--mantine-color-brand-background) 50%, var(--mantine-color-secondary-background) 100%)",
              "--button-hover":
                "linear-gradient(45deg, var(--mantine-color-secondary-hover) 0%, var(--mantine-color-brand-hover) 50%, var(--mantine-color-secondary-hover) 100%)",
              "--button-color": "var(--mantine-color-brand-filled-foreground)",
            },
          };
        } else {
          return { root: {} };
        }
      },
    }),
    Chip: Chip.extend({
      classNames: (_theme, props) => {
        if (props.variant === "light") {
          return {
            label: classes.lightBg,
          };
        } else {
          return {};
        }
      },
      styles: (_theme, props) => {
        if (props.variant === "light") {
          return {
            label: {
              color: props.checked
                ? "var(--mantine-color-brand-light-color)"
                : "var(--mantine-color-gray-light-color)",
              fontSize: "var(--mantine-font-size-sm)",
              fontWeight: 600,
            },
          };
        } else {
          return {};
        }
      },
    }),
  },
});

// Shared Clerk appearance variables (brand colors). The dark base theme
// is layered on top at runtime in root.tsx based on the computed color scheme.
export const clerkAppearance = {
  variables: {
    colorPrimary: "#01845e",
    fontFamily: "'Instrument Sans', sans-serif",
  },
} as const;

export const clerkDarkAppearance = {
  variables: {
    colorPrimary: "#01845e",
    colorBackground: "#030f0a",
    fontFamily: "'Instrument Sans', sans-serif",
  },
} as const;

export const resolver: CSSVariablesResolver = (theme) => ({
  variables: {},
  light: {
    "--shadow-sm":
      "0 1px 2px rgba(0, 0, 0, 0.06), 0 1px 3px rgba(0, 0, 0, 0.1)",
    "--shadow-md":
      "0 2px 4px rgba(0, 0, 0, 0.06), 0 4px 16px rgba(0, 0, 0, 0.12)",
    "--shadow-lg":
      "0 2px 4px rgba(0, 0, 0, 0.04), 0 8px 24px rgba(0, 0, 0, 0.12), 0 24px 48px rgba(0, 0, 0, 0.16)",
    "--mantine-color-brand-background": theme.colors.brand[0],
    "--mantine-color-brand-hover": theme.colors.brand[1],
    "--mantine-color-brand-light-hover": rgba(theme.colors.brand[6], 0.16),
    "--mantine-color-brand-filled-foreground": theme.colors.brand[9],
    "--mantine-color-brand-border": theme.colors.brand[2],
    "--mantine-color-brand-dimmed": theme.colors.brand[3],
    "--mantine-color-secondary-background": theme.colors.secondary[1],
    "--mantine-color-secondary-hover": theme.colors.secondary[2],
    "--mantine-color-secondary-light-hover": rgba(
      theme.colors.secondary[6],
      0.16,
    ),
    "--mantine-color-secondary-filled-foreground": theme.colors.secondary[9],
    "--mantine-color-secondary-border": theme.colors.secondary[2],
    "--mantine-color-secondary-dimmed": theme.colors.secondary[3],
    "--mantine-color-gray-background": theme.colors.gray[1],
    "--mantine-color-gray-hover": theme.colors.gray[2],
    "--mantine-color-gray-light-hover": rgba(theme.colors.gray[6], 0.16),
    "--mantine-color-gray-filled-foreground": theme.colors.gray[9],
    "--mantine-color-background": theme.colors.gray[0],
    "--mantine-color-neutral": theme.colors.gray[5],
    "--mantine-color-track": theme.colors.gray[1],
    "--mantine-color-text-bold": theme.colors.brand[9],
    "--mantine-color-anchor": theme.colors.brand[7],
    "--mantine-color-brand-outline": theme.colors.brand[7],
  },
  dark: {
    "--shadow-sm":
      "0 1px 2px rgba(0, 0, 0, 0.15), 0 1px 3px rgba(0, 0, 0, 0.2)",
    "--shadow-md":
      "0 2px 4px rgba(0, 0, 0, 0.15), 0 4px 16px rgba(0, 0, 0, 0.25)",
    "--shadow-lg":
      "0 2px 4px rgba(0, 0, 0, 0.1), 0 8px 24px rgba(0, 0, 0, 0.25), 0 24px 48px rgba(0, 0, 0, 0.35)",
    "--mantine-color-brand-background": theme.colors.brand[8],
    "--mantine-color-brand-hover": theme.colors.brand[7],
    "--mantine-color-brand-filled": theme.colors.brand[5],
    "--mantine-color-brand-filled-hover": theme.colors.brand[6],
    "--mantine-color-anchor": theme.colors.brand[1],
    "--mantine-color-brand-outline": theme.colors.brand[1],
    "--mantine-color-brand-filled-foreground": theme.white,
    "--mantine-color-brand-border": theme.colors.brand[9],
    "--mantine-color-brand-dimmed": theme.colors.brand[6],
    "--mantine-color-secondary-background": theme.colors.secondary[8],
    "--mantine-color-secondary-hover": theme.colors.secondary[7],
    "--mantine-color-secondary-filled-foreground": theme.white,
    "--mantine-color-secondary-border": theme.colors.secondary[9],
    "--mantine-color-secondary-dimmed": theme.colors.secondary[6],
    "--mantine-color-gray-background": theme.colors.gray[8],
    "--mantine-color-gray-hover": theme.colors.gray[7],
    "--mantine-color-gray-filled-foreground": theme.white,
    "--mantine-color-background": theme.colors.dark[7],
    "--mantine-color-neutral": theme.colors.gray[6],
    "--mantine-color-track": theme.colors.dark[4],
    "--mantine-color-text-bold": theme.white,
  },
});
