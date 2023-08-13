import type { MantineThemeOverride } from "@mantine/core";
import { Button, createTheme } from "@mantine/core";

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
  primaryShade: { light: 5, dark: 6 },
  defaultGradient: {
    from: "secondary",
    to: "brand",
    deg: 45,
  },
  components: {
    Button: Button.extend({
      vars: (_theme, props) => {
        if (props.variant === "gradient") {
          return {
            root: {
              "--button-bg":
                "linear-gradient(45deg, var(--mantine-color-secondary-filled) 0%, var(--mantine-color-brand-filled) 50%, var(--mantine-color-secondary-filled) 100%)",
              "--button-hover":
                "linear-gradient(45deg, var(--mantine-color-brand-filled) 0%, var(--mantine-color-secondary-filled) 50%, var(--mantine-color-brand-filled) 100%)",
            },
          };
        } else {
          return { root: {} };
        }
      },
    }),
  },
});
