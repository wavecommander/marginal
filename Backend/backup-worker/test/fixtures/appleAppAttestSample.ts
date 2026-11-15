// From the sample in Apple's "Attestation Object Validation Guide" (DeviceCheck documentation): a
// real App Attest credential certificate and intermediate, which chain to Apple's App Attestation
// Root CA, and the authenticator data they vouch for. The credential certificate was valid
// 2026-04-20T18:13:12Z to 2026-04-23T18:13:12Z.
//
// Two quirks of Apple's sample, which the tests account for: Apple's sample app passed the raw
// challenge "example_server_challenge" as clientDataHash (not its SHA-256), and its validation
// category is 1. The sample's receipt is not reproduced (this service does not read receipts);
// tests rebuild the attestation object around these parts with a placeholder receipt.
export const APPLE_SAMPLE = {
  appId: "1234567890.com.example.myapp",
  challenge: "example_server_challenge",
  keyId: "zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0=",
  credentialCertificate:
    "MIIEHTCCA6OgAwIBAgIGAZ2xPwtOMAoGCCqGSM49BAMCME8xIzAhBgNVBAMMGkFwcGxlIEFwcCBBdHRlc3RhdGlvbiBDQSAx" +
    "MRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMB4XDTI2MDQyMDE4MTMxMloXDTI2MDQyMzE4MTMx" +
    "MlowgZExSTBHBgNVBAMMQGNlMDQ5OGY1ODQ4M2ZiYjRkYTBkN2IyYzYzYTVhNTM4ZjU1MmQ0YWRjYjlhNGZhOTE2MTk1YzQ5" +
    "NjEzZTY1NWQxGjAYBgNVBAsMEUFBQSBDZXJ0aWZpY2F0aW9uMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxp" +
    "Zm9ybmlhMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQzJUSs8yPbd0RDyq8zn1bn6VxyT6wsFCWfNl4kRWULK1+yhbz1Sb" +
    "y2BZRBLnaCokJ+6tqftS3+0LGrF+0J+pvaOCAiYwggIiMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgTwMBQGA1UdJQQN" +
    "MAsGCSqGSIb3Y2QEGDB6BgkqhkiG92NkCAUEbTBrpAMCAQq/iTADAgEAv4kxAwIBAL+JMgMCAQC/iTMDAgEAv4k0HgQcMTIz" +
    "NDU2Nzg5MC5jb20uZXhhbXBsZS5teWFwcL+JNgMCAQS/iTcDAgEAv4k5AwIBAL+JOgMCAQC/iTsDAgEAqgMCAQAwgeAGCSqG" +
    "SIb3Y2QIBwSB0jCBz7+KeAYEBDI3LjC/iFADAgECv4p5CQQHMS4wLjIxNr+KewkEBzI0QTMyNWK/inwGBAQyNy4wv4p9BgQE" +
    "MjcuML+KfgMCAQC/in8DAgEAv4sAAwIBAL+LAQMCAQC/iwIDAgEAv4sDAwIBAL+LBAMCAQG/iwUDAgEAv4sKEAQOMjQuMS4z" +
    "MjUuMC4yLDC/iwsQBA4yNC4xLjMyNS4wLjIsML+LDBAEDjI0LjEuMzI1LjAuMiwwv4gCCgQIaXBob25lb3O/iAUKBAhJbnRl" +
    "cm5hbDAzBgkqhkiG92NkCAIEJjAkoSIEIIe30G2TpClORvAR5mtsxADwurIHKZdsYZWAtCrmC/9uMFgGCSqGSIb3Y2QIBgRL" +
    "MEmjRwRFMEMMAjExMD0wCgwDb2tkoQMBAf8wCQwCb2GhAwEB/zALDARvc2duoQMBAf8wCwwEb2RlbKEDAQH/MAoMA29ja6ED" +
    "AQH/MAoGCCqGSM49BAMCA2gAMGUCMCG8x2j20SnJtrGuCbw1sk1+NMs/VNm8sRcU4aPhyDNB3mMBdxy8gNza6r91g8v1HQIx" +
    "AKTqMS+83kFdMob2rD3t9fnNWWLhA8RFOqw64XhXFTEWXqb1ddPoRcYCFlTEqULtPQ==",
  intermediate:
    "MIICQzCCAcigAwIBAgIQCbrF4bxAGtnUU5W8OBoIVDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0" +
    "YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODM5NTVa" +
    "Fw0zMDAzMTMwMDAwMDBaME8xIzAhBgNVBAMMGkFwcGxlIEFwcCBBdHRlc3RhdGlvbiBDQSAxMRMwEQYDVQQKDApBcHBsZSBJ" +
    "bmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAErls3oHdNebI1j0Dn0fImJvHCX+8XgC3q" +
    "s4JqWYdP+NKtFSV4mqJmBBkSSLY8uWcGnpjTY71eNw+/oI4ynoBzqYXndG6jWaL2bynbMq9FXiEWWNVnr54mfrJhTcIaZs6Z" +
    "o2YwZDASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFKyREFMzvb5oQf+nDKnl+url5YqhMB0GA1UdDgQWBBQ+410c" +
    "BBmpybQx+IR01uHhV3LjmzAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaQAwZgIxALu+iI1zjQUCz7z9Zm0JV1A1vNaH" +
    "LD+EMEkmKe3R+RToeZkcmui1rvjTqFQz97YNBgIxAKs47dDMge0ApFLDukT5k2NlU/7MKX8utN+fXr5aSsq2mVxLgg35BDhv" +
    "eAe7WJQ5tw==",
  authData:
    "9EZtaPketsEGIMt+Y8coMkRoXuHWRntUFg51MXIFfwNAAAAAAGFwcGF0dGVzdAAAAAAAAAAAIM4EmPWEg/u02g17LGOlpTj1" +
    "UtSty5pPqRYZXElhPmVdpQECAyYgASFYIEMyVErPMj23dEQ8qvM59W5+lcck+sLBQlnzZeJEVlCyIlggtfsoW89Um8tgWUQS" +
    "52gqJCfuran7Ut/tCxqxftCfqb2id2FwcGxlX2J1bmRsZV92ZXJzaW9uXzAxYTF4HGFwcGxlX3ZhbGlkYXRpb25fY2F0ZWdv" +
    "cnlfMDFEAQAAAA==",
};
