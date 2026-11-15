/** Bindings, settings and secrets of the Worker (see wrangler.jsonc and .dev.vars.example). */
export interface Env {
  DB: D1Database;
  BUCKET: R2Bucket;

  ENVIRONMENT: "dev" | "production";
  R2_ACCOUNT_ID: string;
  R2_S3_HOST: string;
  R2_BUCKET_NAME: string;
  APP_BUNDLE_ID: string;
  CREDENTIAL_TTL_SECONDS: string;
  READ_ONLY_DAYS: string;
  DELETE_AFTER_DAYS: string;
  /** JSON object: product ID to storage allowance in bytes. */
  PRODUCT_ALLOWANCES: string;

  // Secrets.
  R2_PARENT_ACCESS_KEY_ID: string;
  R2_PARENT_SECRET_ACCESS_KEY: string;
  USER_KEY_SECRET: string;
}

/** Settings parsed and checked once per request; throws a plain message naming what is wrong. */
export interface Settings {
  environment: "dev" | "production";
  credentialTTLSeconds: number;
  readOnlyDays: number;
  deleteAfterDays: number;
  /** Product ID to allowance in bytes. */
  allowances: Map<string, number>;
}

export function readSettings(env: Env): Settings {
  const credentialTTLSeconds = wholeNumber(env.CREDENTIAL_TTL_SECONDS, "CREDENTIAL_TTL_SECONDS");
  const readOnlyDays = wholeNumber(env.READ_ONLY_DAYS, "READ_ONLY_DAYS");
  const deleteAfterDays = wholeNumber(env.DELETE_AFTER_DAYS, "DELETE_AFTER_DAYS");
  if (deleteAfterDays < readOnlyDays) {
    throw new Error("DELETE_AFTER_DAYS must not be less than READ_ONLY_DAYS");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(env.PRODUCT_ALLOWANCES);
  } catch {
    throw new Error("PRODUCT_ALLOWANCES is not JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("PRODUCT_ALLOWANCES must be an object of product ID to bytes");
  }
  const allowances = new Map<string, number>();
  for (const [productId, bytes] of Object.entries(parsed)) {
    if (typeof bytes !== "number" || !Number.isSafeInteger(bytes) || bytes <= 0) {
      throw new Error(`PRODUCT_ALLOWANCES: ${productId} must be a positive whole number of bytes`);
    }
    allowances.set(productId, bytes);
  }
  if (allowances.size === 0) throw new Error("PRODUCT_ALLOWANCES names no product");
  if (env.ENVIRONMENT !== "dev" && env.ENVIRONMENT !== "production") {
    throw new Error("ENVIRONMENT must be dev or production");
  }
  return { environment: env.ENVIRONMENT, credentialTTLSeconds, readOnlyDays, deleteAfterDays, allowances };
}

function wholeNumber(value: string, name: string): number {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error(`${name} must be a whole number`);
  return number;
}
