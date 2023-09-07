import type {
  CSSVariablesResolver,
  MantineThemeOverride,
  VariantColorsResolver,
} from "@mantine/core";
import {
  Button,
  createTheme,
  defaultVariantColorsResolver,
  parseThemeColor,
} from "@mantine/core";

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
        "-background"
      )})`,
      hover: `var(${parsedColor.variable.replace("-filled", "-hover")})`,
      color: `var(${parsedColor.variable.replace(
        "-filled",
        "-filled-foreground"
      )})`,
    };
  }

  return defaultResolvedColors;
};

export const theme: MantineThemeOverride = createTheme({
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
    from: "secondary",
    to: "brand",
    deg: 45,
  },
  variantColorResolver,
  components: {
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
  },
});

export const resolver: CSSVariablesResolver = (theme) => ({
  variables: {},
  light: {
    "--mantine-color-brand-background": theme.colors.brand[0],
    "--mantine-color-brand-hover": theme.colors.brand[1],
    "--mantine-color-brand-filled-foreground": theme.colors.brand[9],
    "--mantine-color-brand-border": theme.colors.brand[2],
    "--mantine-color-secondary-background": theme.colors.secondary[1],
    "--mantine-color-secondary-hover": theme.colors.secondary[2],
    "--mantine-color-secondary-filled-foreground": theme.colors.secondary[9],
    "--mantine-color-secondary-border": theme.colors.secondary[2],
    "--mantine-color-gray-background": theme.colors.gray[1],
    "--mantine-color-gray-hover": theme.colors.gray[2],
    "--mantine-color-gray-filled-foreground": theme.colors.gray[9],
    "--mantine-color-background": theme.colors.gray[0],
  },
  dark: {
    "--mantine-color-brand-background": theme.colors.brand[8],
    "--mantine-color-brand-hover": theme.colors.brand[7],
    "--mantine-color-brand-filled-foreground": theme.white,
    "--mantine-color-brand-border": theme.colors.brand[9],
    "--mantine-color-secondary-background": theme.colors.secondary[8],
    "--mantine-color-secondary-hover": theme.colors.secondary[7],
    "--mantine-color-secondary-filled-foreground": theme.white,
    "--mantine-color-secondary-border": theme.colors.secondary[9],
    "--mantine-color-gray-background": theme.colors.gray[8],
    "--mantine-color-gray-hover": theme.colors.gray[7],
    "--mantine-color-gray-filled-foreground": theme.white,
    "--mantine-color-background": theme.colors.dark[7],
  },
});
