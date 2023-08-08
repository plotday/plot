import type { MantineThemeOverride } from "@mantine/core";
import { createTheme } from "@mantine/core";

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
});
