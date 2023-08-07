module.exports = {
  extends: ["@remix-run/eslint-config", "turbo", "prettier"],
  ignorePatterns: ["**/build/**", "**/dist/**", "**/node_modules/**"],
  rules: {
    "react-hooks/rules-of-hooks": "error",
    "react-hooks/exhaustive-deps": "warn",
    "no-useless-constructor": "off",
    "no-unused-vars": "off",
    "@typescript-eslint/no-unused-vars": [
      "warn",
      {
        argsIgnorePattern: "^_",
        varsIgnorePattern: "^_",
        caughtErrorsIgnorePattern: "^_",
      },
    ],
  },
};
