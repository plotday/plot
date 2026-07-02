// Repo-wide ESLint flat config. Packages run `eslint .` from their own
// directory; ESLint 9+ walks up from the CWD and finds this file, so the one
// config serves every workspace package (the eslintrc-era `root: true` files
// are gone).
import config from "@plotday/eslint-config-custom";

export default config;
