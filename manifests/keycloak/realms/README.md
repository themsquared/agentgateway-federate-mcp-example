# Company realms

One JSON file per consuming company. `setup.sh` turns this whole directory into
the `keycloak-realms` ConfigMap, and Keycloak imports every file in it at startup:

```bash
kubectl create configmap keycloak-realms \
  --namespace mcp-federation \
  --from-file=manifests/keycloak/realms/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Adding a company is adding a file here** — no existing file changes. That is the
point of the layout: `scripts/add-partner.sh` writes a new realm into this
directory, and nothing another company depends on is edited.

Every realm mints tokens carrying the two claims the gateway makes decisions on:

| claim     | used by                                     |
| --------- | ------------------------------------------- |
| `company` | tool entitlements, quota bucket, chargeback |
| `tier`    | quota tier, reporting                       |

Both are hardcoded claim mappers on the client, because in this demo the realm
*is* the company. In a real deployment they would come from directory attributes
or group membership — nothing downstream changes.

**`platform.json` is the exception — it is not a customer.** It is the platform
*operator* realm backing login to the Solo Enterprise UI (the agentgateway
dashboard): browser-login clients and a `Groups` claim instead of
`company`/`tier`. The UI maps `Groups` to roles (`admins` → `global.Admin`,
`readers` → `global.Reader`). Demo login: `operator` / `operator`. In production
this realm is your corporate IdP. Keycloak's importer rejects unknown JSON
fields, so notes like this live here rather than in the realm files.

A realm here is only a stand-in for the partner's real identity provider. See
[ONBOARDING.md](../../../ONBOARDING.md) for pointing the gateway at a partner's
own Okta, Entra, or Auth0 tenant instead, which is the usual production shape.
