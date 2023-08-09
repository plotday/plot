import { Box, Image } from "@mantine/core";

import { APP_NAME } from "../config";
import classes from "./logo.module.css";

export default function Logo() {
  return (
    <Image
      h={24}
      w="auto"
      fit="contain"
      src="/assets/plot.svg"
      alt={APP_NAME}
      className={classes.logo}
    />
  );
}
