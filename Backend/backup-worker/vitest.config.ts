import { defineConfig } from "vitest/config";

// Plain Node tests for the pure modules (Node has the same WebCrypto the Workers runtime does).
// Tests that need the Workers runtime, D1 or R2 bindings are added with the Workers test pool.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
