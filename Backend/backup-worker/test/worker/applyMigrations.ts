import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Storage is isolated per test file; apply the schema to each file's fresh database.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
