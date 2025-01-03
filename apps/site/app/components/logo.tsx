import { Image } from "@mantine/core";

import classes from "./logo.module.css";

export default function Logo() {
  return (
    <Image
      h={24}
      w="auto"
      fit="contain"
      src="/assets/plot.svg"
      alt="Plot"
      className={classes.logo}
    />
  );
}
