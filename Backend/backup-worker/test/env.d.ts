// Types for the Workers test runtime: `env` from "cloudflare:workers" is the Worker's Env plus the
// test-only migrations binding, and `exports` is the Worker's main module.

type BackupWorkerEnv = import("../src/env").Env;
type BackupWorkerMigration = import("cloudflare:test").D1Migration;

declare namespace Cloudflare {
  interface Env extends BackupWorkerEnv {
    TEST_MIGRATIONS: BackupWorkerMigration[];
  }
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
}
