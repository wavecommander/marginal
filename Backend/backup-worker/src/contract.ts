// The HTTP contract between the app and this service, as TypeScript types. README.md describes
// the same contract in prose; the two must agree. All bodies are JSON (UTF-8). Times are ISO 8601
// strings in UTC; byte counts are whole numbers. Base64 is standard base64 with padding.

import type { AccessMode } from "./tempCredentials";

// ---------------------------------------------------------------------------------------------
// Requests

/** `POST /v1/challenge`: no body (or `{}`). */
export type ChallengeRequest = Record<string, never>;

/** `POST /v1/attest`. */
export interface AttestRequest {
  /** The App Attest key identifier, as `generateKey` returned it (base64). */
  keyId: string;
  /** A challenge from `/v1/challenge`, exactly as received. */
  challenge: string;
  /**
   * The attestation object from `attestKey(keyId, clientDataHash:)` (base64), where
   * `clientDataHash` = SHA-256 of the challenge's base64-decoded bytes.
   */
  attestation: string;
}

/**
 * Every attested request (everything below except `/v1/apple/*`). The exact body bytes are the
 * App Attest `clientData`: the app signs SHA-256(body) with `generateAssertion(keyId,
 * clientDataHash:)` and sends the result in headers (see `AUTH_HEADERS`).
 */
export interface AttestedRequest {
  /** Must name the endpoint (see `ENDPOINT_ACTIONS`). */
  action: Action;
  /** A challenge from `/v1/challenge`, exactly as received. Single use. */
  challenge: string;
}

/** The `action` each attested endpoint requires. */
export const ENDPOINT_ACTIONS = {
  "/v1/auth/apple": "auth-apple",
  "/v1/auth/google": "auth-google",
  "/v1/auth/change": "auth-change",
  "/v1/auth/signout": "auth-signout",
  "/v1/auth/signout-all": "auth-signout-all",
  "/v1/account": "account",
  "/v1/account/delete": "account-delete",
  "/v1/session": "session",
  "/v1/delete-my-data": "delete-my-data",
} as const;

export type Action = (typeof ENDPOINT_ACTIONS)[keyof typeof ENDPOINT_ACTIONS];

/** Requests made while signed in carry the device session from sign-in. */
export interface SignedInRequest extends AttestedRequest {
  /** The `deviceSessionToken` sign-in returned (43 characters). */
  deviceSessionToken: string;
}

/**
 * `POST /v1/auth/apple` and `POST /v1/auth/google`. The ID token's `nonce` must be the
 * lower-case hex SHA-256 of the challenge's base64-decoded bytes.
 *
 * Every ID token field in this contract (`idToken`, `currentIdToken`, `newIdToken`) may instead
 * be a dev test issuer token (README, "The dev test issuer"), on the `dev` deployment only and
 * only when DEV_TEST_SIGNIN_SECRET is set. It stands in for the provider the endpoint names, in
 * an identity namespace of its own, so it never reaches an account made with a real sign-in.
 */
export interface SignInRequest extends AttestedRequest {
  action: "auth-apple" | "auth-google";
  /**
   * Apple: `ASAuthorizationAppleIDCredential.identityToken` (UTF-8). Google: the `id_token`.
   * `dev` with the test issuer on: or a dev test token.
   */
  idToken: string;
  /** Apple only, optional: `authorizationCode`. Accepted and not used at sign-in. */
  authorizationCode?: string;
  /** Optional: this device's name, encrypted by the app (base64, at most 1,024 characters). Opaque here. */
  deviceLabel?: string;
}

/**
 * `POST /v1/auth/change`: replaces the account's sign-in with another provider's. Both ID tokens
 * carry the same `nonce` (from this request's challenge).
 */
export interface ChangeSignInRequest extends SignedInRequest {
  action: "auth-change";
  /**
   * A fresh ID token from the account's current sign-in: the proof. For an account made with
   * dev test tokens, a dev test token for the same subject (a real token is `identity-mismatch`,
   * and the other way round).
   */
  currentIdToken: string;
  /** Required when the current sign-in is Apple: that sign-in's `authorizationCode`, to revoke it after the change. */
  currentAuthorizationCode?: string;
  /** The provider to change to; must differ from the current one. */
  newProvider: "apple" | "google";
  /** A fresh ID token from the new provider (`dev` with the test issuer on: or a dev test token). */
  newIdToken: string;
}

/** `POST /v1/auth/signout` (this device) and `POST /v1/auth/signout-all` (every device). */
export interface SignOutRequest extends SignedInRequest {
  action: "auth-signout" | "auth-signout-all";
}

/** `POST /v1/account`: the account screen's information. */
export interface AccountRequest extends SignedInRequest {
  action: "account";
  /** Optional: sets this device's encrypted name (base64, at most 1,024 characters). */
  deviceLabel?: string;
}

/**
 * `POST /v1/account/delete`. The first call needs a fresh ID token from the current sign-in
 * (and, for Apple, its authorization code); later calls, until `done`, need only the session.
 */
export interface DeleteAccountRequest extends SignedInRequest {
  action: "account-delete";
  /** The proof, as `ChangeSignInRequest.currentIdToken`. */
  idToken?: string;
  authorizationCode?: string;
}

/** `POST /v1/session`. */
export interface SessionRequest extends SignedInRequest {
  action: "session";
  /** Optional: the backup subscription's latest transaction (StoreKit `Transaction.jwsRepresentation`). */
  signedTransaction?: string;
  /** Optional, only with `signedTransaction`: its renewal info JWS. Lets billing-retry and grace periods count. */
  signedRenewalInfo?: string;
}

/** `POST /v1/delete-my-data`. */
export interface DeleteMyDataRequest extends SignedInRequest {
  action: "delete-my-data";
}

export const AUTH_HEADERS = {
  /** The attested key's identifier (base64). */
  keyId: "x-app-attest-key-id",
  /** The assertion object from `generateAssertion` (base64). */
  assertion: "x-app-attest-assertion",
  /** `dev` deployment only, for the simulator (which has no App Attest). Ignored by production. */
  bypass: "x-app-attest-bypass",
} as const;

/** `POST /v1/apple/notifications`: App Store Server Notifications V2. */
export interface AppleNotificationRequest {
  signedPayload: string;
}

/** `POST /v1/apple/signin-notifications`: Sign in with Apple server-to-server notifications. */
export interface AppleSignInNotificationRequest {
  payload: string;
}

// ---------------------------------------------------------------------------------------------
// Responses

export interface HealthResponse {
  ok: true;
  environment: "dev" | "production";
}

export interface ChallengeResponse {
  /** 32 random bytes, base64. */
  challenge: string;
  expiresAt: string;
}

export interface AttestResponse {
  keyId: string;
  /** Which App Attest environment the key belongs to. */
  environment: "production" | "development";
}

export type SubscriptionStateName =
  /** Paid and current. */
  | "active"
  /** Apple's billing grace period: renewal failed, access continues. */
  | "grace-period"
  /** Apple is retrying a failed renewal: access continues. */
  | "billing-retry"
  /** The subscription has ended (expired, or billing retry gave up, or it moved to another account). */
  | "ended"
  /** Apple refunded or revoked it. */
  | "revoked";

export interface SubscriptionInfo {
  state: SubscriptionStateName;
  /** `Production`, `Sandbox` or `Xcode`. Sandbox and Xcode data are kept apart from customers'. */
  environment: "Production" | "Sandbox" | "Xcode";
  productId: string;
  /** End of the paid period Apple last reported (null if unknown). */
  expiresAt: string | null;
  /** When access ended; null while the subscription is active. */
  endedAt: string | null;
  /** Last moment restore is possible; null while active. */
  readOnlyUntil: string | null;
  /** When the backups are deleted unless the user resubscribes; null while active. */
  deleteAfter: string | null;
}

export interface UsageInfo {
  /** Bytes stored under the account's folder at the last count. */
  bytes: number;
  allowanceBytes: number;
  /** True when `bytes` exceeds `allowanceBytes` (the mode is then `read-delete`). */
  overAllowance: boolean;
  countedAt: string;
}

/** One signed-in device of the account. */
export interface DeviceInfo {
  /** 32 hex digits; stable for the life of the session. */
  sessionId: string;
  createdAt: string;
  lastUsedAt: string;
  /** The encrypted name the app sent, as sent; null if none. */
  label: string | null;
  /** True for the device that made this request. */
  current: boolean;
}

/** `POST /v1/account`, 200; also inside sign-in and change responses. */
export interface AccountResponse {
  /** 32 hex digits. Random; names the account to the app (for example its Keychain item). */
  accountId: string;
  /** The account's one sign-in. Never the provider's user ID or email. */
  provider: "apple" | "google";
  /** Lower-case UUID. Pass to StoreKit as `Product.PurchaseOption.appAccountToken` on every purchase. */
  appAccountToken: string;
  createdAt: string;
  /** Oldest first. */
  devices: DeviceInfo[];
  /** The subscription paying for the account (as in a session); null if it has none. */
  subscription: SubscriptionInfo | null;
  /** Usage of that subscription's folder; null if it has none. */
  usage: UsageInfo | null;
}

/** `POST /v1/auth/apple`, `POST /v1/auth/google`, 200. */
export interface SignInResponse {
  /** The device session. Shown once: keep it in the Keychain, this device only. */
  deviceSessionToken: string;
  /** This session's ID in `account.devices`. */
  sessionId: string;
  /** True if this sign-in created the account. */
  newAccount: boolean;
  account: AccountResponse;
}

/** `POST /v1/auth/signout`, `POST /v1/auth/signout-all`, 200. */
export interface SignOutResponse {
  ok: true;
  /** How many device sessions ended (this one included). */
  endedSessions: number;
}

/** `POST /v1/session`, 200. */
export interface SessionResponse {
  mode: AccessMode;
  credentials: {
    accessKeyId: string;
    secretAccessKey: string;
    /** Send as `X-Amz-Security-Token` on every S3 request (and sign it). */
    sessionToken: string;
    expiresAt: string;
  };
  storage: {
    /** `https://<host>`, the S3 endpoint. */
    endpoint: string;
    host: string;
    /** Always `auto` for R2. */
    region: "auto";
    bucket: string;
    /** The only folder these credentials reach, e.g. `users/<64 hex>/`. Every key starts with it. */
    prefix: string;
  };
  subscription: SubscriptionInfo;
  usage: UsageInfo;
}

/** `POST /v1/delete-my-data` and `POST /v1/account/delete`, 200. Call again until `done` is true. */
export interface DeleteMyDataResponse {
  done: boolean;
  /** Objects deleted by this call. */
  deletedObjects: number;
}

export type DeleteAccountResponse = DeleteMyDataResponse;

/** `POST /v1/apple/notifications` and `POST /v1/apple/signin-notifications`, 200. */
export interface AppleNotificationResponse {
  ok: true;
}

// ---------------------------------------------------------------------------------------------
// Errors: every non-2xx response is `ErrorResponse`.

export const ERRORS = {
  "bad-request": { status: 400, message: "The request was not understood." },
  "not-found": { status: 404, message: "No such endpoint." },
  "method-not-allowed": { status: 405, message: "That method is not allowed here." },
  "body-too-large": { status: 413, message: "The request is too large." },
  "unsupported-media-type": { status: 415, message: "Send the request as JSON." },
  "challenge-invalid": { status: 401, message: "The request expired. Try again." },
  "attestation-invalid": { status: 401, message: "This copy of the app could not be verified." },
  "device-already-attested": { status: 409, message: "This device is already registered." },
  "device-unknown": { status: 401, message: "This device needs to be registered again." },
  "assertion-invalid": { status: 401, message: "This copy of the app could not be verified." },
  "id-token-invalid": { status: 401, message: "The sign-in could not be verified. Try again." },
  "provider-disabled": { status: 403, message: "This way of signing in is not available." },
  "provider-unreachable": { status: 503, message: "Apple or Google could not be reached. Try again later." },
  "session-invalid": { status: 401, message: "You have been signed out. Sign in again." },
  "identity-mismatch": { status: 403, message: "Confirm with the sign-in this account uses now." },
  "identity-in-use": { status: 409, message: "That sign-in already has an account of its own." },
  "account-deleting": { status: 409, message: "This account is being deleted." },
  "not-subscribed": { status: 403, message: "This account has no subscription to Tactile Texts Cloud." },
  "subscription-other-account": { status: 403, message: "This subscription was bought for another account." },
  "subscription-in-use": { status: 403, message: "This subscription is in use by another account." },
  "transaction-invalid": { status: 401, message: "The subscription could not be verified." },
  "product-unknown": { status: 403, message: "This purchase does not include cloud backup." },
  "environment-not-accepted": { status: 403, message: "Purchases from this environment are not accepted here." },
  "subscription-revoked": { status: 403, message: "This subscription was refunded or revoked." },
  "subscription-lapsed": { status: 403, message: "Your subscription has ended. Resubscribe to restore access to your backups before they are deleted." },
  "data-deleted": { status: 403, message: "Your subscription ended and its backups have been deleted." },
  "notification-invalid": { status: 401, message: "The notification could not be verified." },
  internal: { status: 500, message: "Something went wrong. Try again later." },
} as const satisfies Record<string, { status: number; message: string }>;

export type ErrorCode = keyof typeof ERRORS;

export interface ErrorResponse {
  error: {
    /** Stable; the app branches on this. */
    code: ErrorCode;
    /** A sentence for a person. */
    message: string;
  };
  /**
   * Present with `subscription-revoked`, `subscription-lapsed` and `data-deleted`, so the app
   * can show the dates.
   */
  subscription?: SubscriptionInfo;
}
