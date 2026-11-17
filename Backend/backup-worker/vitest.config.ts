import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Two kinds of test:
// - `unit`: plain Node, for the pure modules (Node has the same WebCrypto the Workers runtime has).
// - `worker`: inside the Workers runtime (workerd, through Miniflare) with a local D1 database and
//   R2 bucket, for the routes, the database and the cron. Nothing here touches Cloudflare.
export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "unit",
          include: ["test/unit/**/*.test.ts"],
          environment: "node",
        },
      },
      {
        plugins: [
          cloudflareTest(async () => ({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: {
              bindings: {
                TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")),
                // Made-up values: the tests mint credentials but never reach a real bucket.
                R2_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
                R2_S3_HOST: "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
                APPLE_TEAM_ID: "TEAMID1234",
                R2_PARENT_ACCESS_KEY_ID: "test-parent-access-key-id",
                R2_PARENT_SECRET_ACCESS_KEY: "test-parent-secret-access-key-not-real",
                IDENTITY_KEY_SECRET: "test-identity-key-secret-0123456789abcdef-not-real",
              },
            },
          })),
        ],
        test: {
          name: "worker",
          include: ["test/worker/**/*.test.ts"],
          setupFiles: ["./test/worker/applyMigrations.ts"],
          // A few tests write thousands of objects to the local bucket; give them room under load.
          testTimeout: 30_000,
        },
      },
    ],
  },
});
