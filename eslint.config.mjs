import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/dist/**",
      "**/node_modules/**",
      "**/.wrangler/**",
      "**/.dart_tool/**",
      "**/build/**",
      "**/.astro/**",
      "**/.development/**",
      "_to_delete/**",
      "**/worker-configuration.d.ts",
    ],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      "no-unused-vars": "off",
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
    },
  },
  {
    files: [
      "apps/cloud/scripts/**/*.mjs",
      "apps/site/scripts/**/*.mjs",
      "scripts/**/*.mjs",
      "*.mjs",
    ],
    languageOptions: {
      globals: {
        Buffer: "readonly",
        URL: "readonly",
        console: "readonly",
        fetch: "readonly",
        process: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        ReadableStream: "readonly",
      },
    },
  },
  {
    languageOptions: {
      globals: {
        AbortController: "readonly",
        AbortSignal: "readonly",
        Buffer: "readonly",
        Headers: "readonly",
        Response: "readonly",
        URL: "readonly",
        clearTimeout: "readonly",
        console: "readonly",
        fetch: "readonly",
        process: "readonly",
        setTimeout: "readonly",
      },
    },
  },
  {
    files: ["apps/site/public/scripts/**/*.js"],
    languageOptions: {
      globals: {
        document: "readonly",
        fetch: "readonly",
        IntersectionObserver: "readonly",
        navigator: "readonly",
        setTimeout: "readonly",
        window: "readonly",
      },
    },
  },
);
