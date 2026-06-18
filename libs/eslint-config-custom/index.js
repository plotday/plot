module.exports = {
  extends: ["@remix-run/eslint-config", "prettier"],
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
    "jsx-a11y/anchor-has-content": [
      2,
      {
        components: ["Anchor"],
      },
    ],
    // Storing a bare reference to a `this`-sensitive global (e.g.
    // `const f = globalThis.fetch`) and later calling it as a method
    // (`obj.f(...)`) rebinds `this` to the wrong object, which the Cloudflare
    // Workers runtime rejects with "Illegal invocation". Flag the reference;
    // it's fine when immediately called, `.bind`/`.call`/`.apply`-ed, or
    // wrapped in an arrow `(...args) => fetch(...args)`.
    "no-restricted-syntax": [
      "error",
      {
        selector:
          "MemberExpression[object.name='globalThis'][property.name=/^(fetch|setTimeout|clearTimeout|setInterval|setImmediate|queueMicrotask|atob|btoa|structuredClone|reportError)$/]" +
          ":not(CallExpression > MemberExpression)" +
          ":not(MemberExpression[property.name=/^(bind|call|apply)$/] > MemberExpression)",
        message:
          "Don't store a bare reference to a `this`-sensitive global like `globalThis.fetch` — calling it as a method rebinds `this` and the Workers runtime throws 'Illegal invocation'. Wrap it in an arrow `(...args) => fetch(...args)` or use `.bind(globalThis)`.",
      },
    ],
  },
  settings: {
    react: {
      version: "18.2",
    },
  },
};
