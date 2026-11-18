-- Whether an account's sign-in is an identity from the `dev` deployment's test issuer (its hash
-- is in a `dev-test:` namespace, see src/identity.ts) rather than a real Apple or Google one.
-- The hash alone cannot say so, and the dev test entitlement (src/devEntitlement.ts) must apply
-- only to such accounts. Set when the account is made and whenever its sign-in changes, in the
-- same statement as the identity. Always 0 in production, which refuses dev test tokens.
--
-- Additive: older code ignores the column. Every existing row counts as a real identity's (0),
-- so a dev test account made before this column existed gets no dev test entitlement.
ALTER TABLE accounts ADD COLUMN identity_dev_test INTEGER NOT NULL DEFAULT 0 CHECK (identity_dev_test IN (0, 1));
