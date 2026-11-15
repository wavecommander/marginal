// Fake App Store payloads, shaped like Apple's JWSTransactionDecodedPayload,
// JWSRenewalInfoDecodedPayload and responseBodyV2DecodedPayload.

import { APP_APPLE_ID, BUNDLE_ID, PRODUCT } from "./settings";
import { signWithChain, type AppleChain } from "./pki";

export const DAY = 24 * 60 * 60 * 1000;

export function transactionPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const signedDate = (overrides.signedDate as number | undefined) ?? Date.parse("2026-11-01T00:00:00Z");
  return {
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    webOrderLineItemId: "2000000000000002",
    bundleId: BUNDLE_ID,
    productId: PRODUCT,
    subscriptionGroupIdentifier: "21000000",
    purchaseDate: signedDate,
    originalPurchaseDate: signedDate,
    expiresDate: signedDate + 30 * DAY,
    quantity: 1,
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    signedDate,
    environment: "Production",
    transactionReason: "PURCHASE",
    storefront: "GBR",
    storefrontId: "143444",
    ...overrides,
  };
}

export function renewalPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    originalTransactionId: "2000000000000001",
    autoRenewProductId: PRODUCT,
    productId: PRODUCT,
    autoRenewStatus: 1,
    isInBillingRetryPeriod: false,
    signedDate: Date.parse("2026-11-01T00:00:00Z"),
    environment: "Production",
    ...overrides,
  };
}

export function notificationPayload(
  notificationType: string,
  subtype: string | undefined,
  data: Record<string, unknown>,
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    notificationType,
    ...(subtype ? { subtype } : {}),
    notificationUUID: crypto.randomUUID(),
    version: "2.0",
    signedDate: Date.parse("2026-11-01T00:00:00Z"),
    data: { appAppleId: APP_APPLE_ID, bundleId: BUNDLE_ID, bundleVersion: "1", environment: "Production", status: 1, ...data },
    ...overrides,
  };
}

export async function signedNotification(
  chain: AppleChain,
  notificationType: string,
  subtype: string | undefined,
  transaction: Record<string, unknown> | undefined,
  renewal: Record<string, unknown> | undefined,
  overrides: Record<string, unknown> = {},
): Promise<string> {
  const data: Record<string, unknown> = {};
  if (transaction) {
    data.signedTransactionInfo = await signWithChain(transaction, chain);
    data.environment = transaction.environment;
  }
  if (renewal) data.signedRenewalInfo = await signWithChain(renewal, chain);
  const signedDate = Math.max((transaction?.signedDate as number) ?? 0, (renewal?.signedDate as number) ?? 0, Date.parse("2026-11-01T00:00:00Z"));
  return signWithChain(notificationPayload(notificationType, subtype, data, { signedDate, ...overrides }), chain);
}
