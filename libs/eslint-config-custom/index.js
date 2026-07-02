import js from "@eslint/js";
import prettier from "eslint-config-prettier";
import jsxA11y from "eslint-plugin-jsx-a11y";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

// Shared flat config for all TypeScript packages in the monorepo (workers,
// libs, apps/site). Successor to the eslintrc-era config that extended
// @remix-run/eslint-config, which never migrated to flat config and is
// incompatible with ESLint 9+.
export default [
  {
    // Flat config does not auto-ignore dot-directories the way eslintrc did,
    // so generated/tooling output must be ignored explicitly.
    ignores: [
      "**/build/**",
      "**/dist/**",
      "**/node_modules/**",
      "**/.wrangler/**",
      "**/.nx/**",
      "**/.claude/**",
      "**/.react-router/**",
      "**/coverage/**",
      "public/**",
      "apps/plot/**",
      "**/worker-configuration.d.ts",
      // Former .eslintignore entries (flat config no longer reads that file).
      "workers/api/containers/**",
      "libs/crypto/**/*.js",
    ],
  },
  {
    // Plain-JS files (root config files, node scripts). TypeScript files
    // don't need globals because typescript-eslint disables no-undef for
    // them — the compiler already checks identifiers.
    files: ["**/*.{js,mjs,cjs}"],
    languageOptions: {
      globals: {
        ...globals.node,
      },
    },
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    plugins: {
      "jsx-a11y": jsxA11y,
      "react-hooks": reactHooks,
    },
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
      // The eslintrc-era config (via @remix-run/eslint-config's pinned
      // typescript-eslint v5) treated these as warnings; the modern
      // recommended preset raised them to errors. Keep them non-fatal —
      // the codebase intentionally uses `any` and `@ts-ignore` (see
      // AGENTS.md on TS2589).
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/ban-ts-comment": "off",
      // Rules that eslint:recommended / typescript-eslint's recommended set
      // added (or promoted to error) after the eslintrc-era config was
      // written. The codebase predates them; keep them visible as warnings
      // rather than blocking the dependency upgrade on a repo-wide cleanup.
      "prefer-const": "warn",
      "no-useless-assignment": "warn",
      "no-useless-catch": "warn",
      "preserve-caught-error": "warn",
      "@typescript-eslint/no-unsafe-function-type": "warn",
      "@typescript-eslint/no-empty-object-type": "warn",
      // Intentional in emoji-handling regexes (thread-helpers) and unicode
      // test fixtures.
      "no-misleading-character-class": "warn",
      "no-irregular-whitespace": "warn",
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
  },
  prettier,
];
