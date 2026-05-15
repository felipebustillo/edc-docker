# Onboarding Guide

This is the step-by-step procedure to bring up a production-grade EDC connector and onboard it with a dataspace operator. The walkthrough uses [**Hanka**](https://hanka.ai) as the default operator — that's the path the default preset and `setup.sh` are wired for. The same procedure works against any Tractus-X-compatible dataspace; replace the operator-specific URLs in `.env` accordingly.

Follow the steps top-to-bottom. Don't skip.

---

## 0. What you (the developer) own vs what the repo owns

| Owned by **you** | Owned by **this repo** |
|---|---|
| A Linux host with Docker + Compose v2.24+ | The Docker Compose stack (control-plane, data-plane, postgres, vault, Caddy) |
| A public DNS name pointing at that host | TLS certificate issuance (Caddy + Let's Encrypt) |
| Inbound `:80` and `:443` reachable from the public Internet | Reverse-proxy routing of `/api/v1/dsp` and `/api/public` |
| Outbound HTTPS from the host to the operator endpoints listed in your preset | Vault initialisation, unsealing, scoped EDC token, secret seeding |
| Onboarding with the dataspace operator (BPN, DID, STS secret, public key registration) | Postgres persistence, EDC startup wiring, automatic restart |
| Off-host backup of `vault-init.json` and `.env` | Storage of unseal keys and the EDC token on the host volume |

So **your only operational job** before turning on the stack is to expose two HTTPS endpoints:

```
https://<your-public-host>/api/v1/dsp     <- DSP protocol (catalog / negotiation / transfer)
https://<your-public-host>/api/public     <- public data plane (the actual data transfer)
```

Caddy in this stack will issue the certificate for `<your-public-host>` automatically as long as port `:80` is reachable from the Internet (Let's Encrypt HTTP-01).

---

## 1. Pre-flight — what to gather before running anything

### 1.1 From your network/infrastructure

- [ ] A public DNS A (or AAAA) record pointing `<your-public-host>` at the host's public IP.
- [ ] Inbound TCP `:80` and `:443` open from the Internet to the host.
- [ ] Outbound HTTPS from the host to:
  - the operator endpoints listed in your `.env` (`STS_TOKEN_URL`, `CREDENTIAL_SERVICE_URL`, `BDRS_URL`)
  - peer EDCs you want to talk to (DSP)
- [ ] At least 4 GiB of free RAM and 10 GiB of disk on the host.

### 1.2 Generate the data-plane signer keypair

The data-plane signs proxy tokens with this key. The **private** half stays
on this host (in vault, populated from `.env`). The **public** half goes
into your DID document at the operator. Generate both halves locally —
the private key never leaves the host:

```bash
# 1. Ed25519 private key in PEM
openssl genpkey -algorithm ed25519 -out signer.pem

# 2. Convert to JWK (private + public)
docker run --rm -v "$PWD:/work" -w /work python:3.12-slim sh -c '
    pip install -q jwcrypto >/dev/null
    python3 - <<PY
import json
from jwcrypto import jwk
k = jwk.JWK.from_pem(open("signer.pem","rb").read())
priv = json.loads(k.export(private_key=True))
pub  = json.loads(k.export(private_key=False))
# Force a kid so the operator can wire the verificationMethod predictably.
# Use any stable label; "#data-plane" is the convention used by Hanka.
print("PRIVATE:", json.dumps(priv))
print("PUBLIC :", json.dumps(pub))
PY
'
```

Take note of:

- The **PRIVATE** JWK — you'll paste it in `.env` as `TOKEN_SIGNER_KEY_JWK`.
- The **PUBLIC** JWK — you'll paste it into the operator's portal.

When pasting the public JWK make sure it has a `kid` field. If the recipe
above didn't set one, add it manually using the convention
`<your-DID>#data-plane` (you'll know your DID after registering; for the
first registration you can use `<your-host>#data-plane` as a placeholder
and edit the `kid` to match once Hanka has assigned your DID).

After you've captured both halves, shred the PEM:

```bash
shred -u signer.pem
```

### 1.3 Register your connector with the dataspace operator

The default preset targets [Hanka](https://hanka.ai), which provides a
self-service registration flow. Other Tractus-X operators (Cofinity-X,
custom installs) still use the manual exchange described in §1.3.b.

#### 1.3.a Hanka (self-service)

1. Sign in to the Hanka portal and open **Services → EDC → Connectors**
   (or the empty-state choice screen on first use).
2. Pick **Company-managed**.
3. Fill the form:
   - **Name** — anything readable (e.g. `edc-docker (Tailscale)`).
   - **Public host** — the hostname only, no scheme, no path. Hanka
     derives the DSP and data-plane URLs from it.
   - **Location** — optional label (e.g. `DE / on-prem`).
   - **Data-plane signer public JWK** — paste the PUBLIC JWK from §1.2.
4. Submit. Hanka returns a one-time bundle with everything your `.env`
   needs and synchronously publishes the public JWK in your DID document.
   The `STS_CLIENT_SECRET` is shown only here — copy it now.

Each row in the post-registration table maps 1:1 to an `.env` key, and
the right-hand pane gives you the same content as a paste-ready
`.env` block.

| Value (portal label) | `.env` key | Notes |
|---|---|---|
| BPN | `EDC_BPN` | Your Business Partner Number, e.g. `BPNL00000003XXXX`. |
| DID | `EDC_DID` | `did:web:identityhub.hanka.ai:<your-BPN>`. Hanka hosts the `did.json`. |
| Public host | `EDC_PUBLIC_HOST` | The hostname you typed in the form. |
| DSP callback | `EDC_DSP_CALLBACK_ADDRESS` | `https://<host>/api/v1/dsp`. |
| Data-plane public URL | `EDC_DATAPLANE_PUBLIC_URL` | `https://<host>/api/public`. |
| STS token URL | `STS_TOKEN_URL` | `https://identityhub.hanka.ai/api/sts/token`. |
| STS client_id | `EDC_IAM_STS_OAUTH_CLIENT_ID` | **Your DID**, not your BPN. Mismatch shows up later as IH `401 invalid_client`. |
| STS client_secret | `STS_CLIENT_SECRET` | The OAuth secret. Shown once; persist it now. |
| Credential service URL | `CREDENTIAL_SERVICE_URL` | `https://identityhub.hanka.ai/api/credentials/v1/participants/<base64 BPN, no padding>`. |
| BDRS directory URL | `BDRS_URL` | `https://bdrs.hanka.ai/api/directory`. |
| Trusted-issuer DID | `TRUSTED_ISSUER_DID` | `did:web:identityhub.hanka.ai:BPNL00000003CRHK`. |

Verify your data-plane key is published in the DID document before
bringing up the stack:

```bash
curl -sS https://identityhub.hanka.ai/<your-BPN>/did.json \
    | jq '.verificationMethod[] | .id'
# Expect at least two entries: <DID>#key-1 (Hanka-managed STS key)
# and the kid from the JWK you pasted (e.g. <DID>#data-plane).
```

Hanka also automatically issues a `MembershipCredential`, `BpnCredential`
and `DataExchangeGovernanceCredential` to your holder as part of the
onboarding pipeline — no manual step required.

#### 1.3.b Other operators (manual flow)

If you target a Tractus-X operator without a self-service portal you
follow the old exchange:

- Send the operator your DSP URL (`https://<your-public-host>/api/v1/dsp`),
  data-plane URL (`https://<your-public-host>/api/public`) and the PUBLIC
  JWK from §1.2.
- The operator replies with the eight values from the table above (minus
  the three derived URLs you already know).
- The operator must also confirm two things before the connector will work:
  1. Your token-signer public key is published in your DID document.
     Check with `curl https://<their-host>/<your-BPN>/did.json | jq`.
  2. A `MembershipCredential` (and ideally a
     `DataExchangeGovernanceCredential`) has been issued to your holder.

For Hanka, the operator endpoints are already filled in
`presets/hanka.env.example`. For other dataspaces, ask the operator for
them explicitly.

---

## 2. First-time deployment

### 2.1 Clone and configure

```bash
git clone https://github.com/felipebustillo/edc-docker.git
cd edc-docker

# Generate .env from the right preset. This:
#   - copies presets/<name>.env.example to .env
#   - generates strong random POSTGRES_PASSWORD and EDC_API_KEY
#   - generates a fresh UUID for EDC_PARTICIPANT_CONTEXT_ID
./scripts/setup.sh hanka          # or:  ./scripts/setup.sh cofinity
```

Edit `.env` and fill in **every empty value**. Use the table from §1.3.a
(Hanka self-service) or §1.3.b (manual flow).

```bash
$EDITOR .env
```

For the Hanka flow, paste the `env_block` returned by the portal — every
value including `EDC_DSP_CALLBACK_ADDRESS`, `EDC_DATAPLANE_PUBLIC_URL` and
the base64-encoded `CREDENTIAL_SERVICE_URL` is already filled in.

For the manual flow, the operator gives you the eight wallet values and
you fill the derived URLs yourself:

```bash
# These are public URLs Caddy will serve:
EDC_DSP_CALLBACK_ADDRESS=https://<your-public-host>/api/v1/dsp
EDC_DATAPLANE_PUBLIC_URL=https://<your-public-host>/api/public
```

If `CREDENTIAL_SERVICE_URL` in your preset contains the placeholder
`<BASE64_BPN>`, replace it with the base64 (no padding) of your BPN:

```bash
echo -n "$(grep EDC_BPN .env | cut -d= -f2)" | base64 | tr -d '='
```

### 2.2 Bootstrap vault (one time only)

```bash
docker compose up -d --wait vault
docker compose run --rm vault-init
```

`vault-init` will print a clearly-marked block instructing you to back up the unseal keys + root token. Do it now:

```bash
docker compose cp vault-init:/vault/state/init.json ./vault-init.json
cat vault-init.json
# 1. paste the JSON into a password manager (1Password / Bitwarden / Vaultwarden)
# 2. delete the local copy:
shred -u vault-init.json
```

If you skip this step and you ever lose the host volume, the data in vault is **unrecoverable**.

### 2.3 Bring up the stack

```bash
./scripts/up.sh
```

> **Don't use plain `docker compose up -d` for the first start.** Compose reads `env_file` once at start, before any container runs; on a cold start `runtime/edc-vault.env` is empty, so the EDC services would launch with no token. `up.sh` does it in two phases — vault-init first (which writes the file), then the rest.

Watch the boot:

```bash
docker compose logs -f controlplane
```

When you see `Started Hashicorp Vault Token authentication extension` and a steady stream of `org.eclipse.edc.boot.system.runtime.BaseRuntime - edc-controlplane ready`, you're done.

### 2.4 Smoke-test

From the host:

```bash
# Management API (localhost only, returns the catalog of your own assets — empty at first)
curl -sS \
    -H "X-Api-Key: $(grep EDC_API_KEY .env | cut -d= -f2)" \
    -H "Content-Type: application/json" \
    http://127.0.0.1:29181/management/v3/assets/request -d '{}' | jq
```

From the public Internet:

```bash
# DSP version endpoint (your peers will hit this)
curl -sS https://<your-public-host>/api/v1/dsp/.well-known/dspace-version
```

If both return JSON (an empty array `[]` and a version document, respectively), the connector is ready to interact with the dataspace.

---

## 3. Day-to-day

```bash
./scripts/up.sh                  # always safe; idempotent
docker compose ps                # what's running
docker compose logs -f           # follow all logs
docker compose down              # stop, keep state
```

### 3.1 Updating

```bash
git pull
./scripts/up.sh                  # picks up image-tag changes from .env
```

### 3.2 Rotating the EDC vault token

The token has a 30-day period and the EDC auto-renews while running. If the EDC has been off longer than that, the next `./scripts/up.sh` mints a fresh one — no manual action needed.

To force a rotation (e.g., suspected compromise):

```bash
docker compose stop controlplane dataplane
rm runtime/edc-vault.env
./scripts/up.sh
```

### 3.3 Backups

Three things must be backed up off-host:

| What | Where | When |
|---|---|---|
| `vault-init.json` (unseal keys + root) | password manager | once, after §2.2 |
| `.env` | password manager / encrypted file | whenever it changes |
| Postgres data | snapshot script (below) | daily / weekly |

```bash
# Postgres backup
docker run --rm \
    -v edc-docker_postgres-data:/data:ro \
    -v "$PWD":/backup \
    alpine tar czf /backup/postgres-$(date +%F).tgz -C /data .
```

### 3.4 Restoring after a host loss

1. Reinstall the host. Install Docker + Compose v2.24.
2. Clone the repo and copy `.env` from your backup.
3. Restore the postgres tar onto a new volume:
   ```bash
   docker volume create edc-docker_postgres-data
   docker run --rm -v edc-docker_postgres-data:/data -v "$PWD":/backup \
       alpine sh -c "cd /data && tar xzf /backup/postgres-<DATE>.tgz"
   ```
4. Restore vault state from `vault-init.json` is **not possible** in this stack — vault keeps its raft state on the host. After a host loss you have to:
   - bring up an empty vault (`docker compose up -d vault`),
   - re-run `docker compose run --rm vault-init` (initialises a NEW vault, prints NEW unseal keys),
   - hand the dataspace operator a NEW token-signer public key (the new vault generates a new one), and
   - have the operator update your DID document with the new key.

This is the single most painful failure mode. Mitigation: snapshot the `vault-data` volume regularly the same way you snapshot postgres.

```bash
docker run --rm \
    -v edc-docker_vault-data:/data:ro \
    -v edc-docker_vault-state:/state:ro \
    -v "$PWD":/backup \
    alpine tar czf /backup/vault-$(date +%F).tgz -C / data state
```

---

## 4. Operating behind your existing reverse proxy

If you already terminate TLS at your edge (Cloudflare Tunnel, an upstream Caddy / Traefik / nginx, etc.), drop the bundled Caddy and let your edge route to the EDC ports directly:

```bash
docker compose stop caddy
docker compose rm -f caddy
```

Then expose the relevant container ports on a private host port (e.g. `127.0.0.1:8084` for DSP, `127.0.0.1:8081` for public data plane) by editing the compose file, and configure your edge to forward `/api/v1/dsp/*` → `:8084` and `/api/public/*` → `:8081`.

In that mode, your edge needs:

- A valid certificate for `EDC_PUBLIC_HOST`.
- HTTP/1.1 keep-alive enabled (DSP transfers can be long-lived).
- `proxy_read_timeout` / `proxy_send_timeout` of ~5 minutes.

---

## 5. Verifying compatibility with Hanka

After §2.3, two checks isolate the most common failure modes before
they bite during a real catalog request.

### 5.1 STS smoke-test (does your connector authenticate?)

Mint a token by hand and confirm the inner `token` claim is present.
Replace `<peer DID>` with any peer you'd talk to (e.g. Hanka's
provider DID `did:web:identityhub.hanka.ai:BPNL00000003AYRE`):

```bash
RESP=$(curl -sX POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "audience=<peer DID>\
&grant_type=client_credentials\
&client_id=$(grep ^EDC_DID .env | cut -d= -f2)\
&client_secret=$(grep ^STS_CLIENT_SECRET .env | cut -d= -f2)\
&bearer_access_scope=org.eclipse.tractusx.vc.type:MembershipCredential:read" \
    "$(grep ^STS_TOKEN_URL .env | cut -d= -f2)")

echo "$RESP" | python3 -c '
import sys, json, base64
out = json.load(sys.stdin)
def dec(s): s += "="*(-len(s)%4); return json.loads(base64.urlsafe_b64decode(s))
outer = dec(out["access_token"].split(".")[1])
print("outer claims :", sorted(outer.keys()))
if "token" not in outer:
    print("FAIL — no inner token. Scopes not configured?")
    sys.exit(1)
inner = dec(outer["token"].split(".")[1])
print("inner scope  :", inner.get("scope"))
print("OK")
'
```

Expected output ends with `OK`. If `FAIL — no inner token`, your
connector isn't sending `bearer_access_scope` to STS — see §6.3.

### 5.2 Operator-side catalog request

Ask the Hanka operator to do a catalog request against your connector:

```bash
# from a Hanka-side connector:
curl -X POST <hanka-edc>/management/v3/catalog/request -d '{
    "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
    "counterPartyAddress": "https://<your-public-host>/api/v1/dsp",
    "counterPartyId": "<your-DID>",
    "protocol": "dataspace-protocol-http"
}'
```

You should see a JSON catalog response (initially empty, since you haven't published any assets yet).

---

## 6. Troubleshooting

Three failure modes you'll see on first contact with the dataspace.
Each one has a deterministic fingerprint in the logs.

### 6.1 `PKIX path building failed` — TLS chain not trusted

```
java.security.cert.CertPathBuilderException:
  unable to find valid certification path to requested target
```

Your JVM truststore doesn't trust the certificate the operator's
Credential Service presents. Causes:

- **The operator's cert is signed by a private/self-signed CA.** Ask
  the operator for the CA root PEM and place it in `config/cacerts/`,
  then add to the controlplane volumes block in `docker-compose.yaml`:
  `- ./config/cacerts:/etc/ssl/certs/custom:ro` and an initContainer
  that imports them. The Hanka preset doesn't currently need this —
  Hanka's public endpoints use Let's Encrypt, which is in the default
  JDK truststore.
- **The cert hostname doesn't match.** Some operators issue
  internal-only certs for in-cluster traffic but valid LE for external.
  External operators like you should always see the public cert.

### 6.2 `Name does not resolve` for the operator's DID host

```
java.net.UnknownHostException: identity-hub.hanka.ai: Name does not resolve
```

The DID in your `.env` references a hostname that doesn't exist (or
has been renamed). Re-check `EDC_DID` and `CREDENTIAL_SERVICE_URL`
against §1.3 — the operator may have changed their public hostname.
For Hanka the canonical host is `identityhub.hanka.ai` (no dash).

### 6.3 `403 Invalid query: requested Credentials outside of scope`

```
Unauthorized: Presentation Query failed: HTTP 403,
  message: "Invalid query: requested Credentials outside of scope."
```

The IH says: "the token you sent me does not authorize the bearer to
read these credential types." 99% of the time the cause is the same:
your connector is not actually applying its DCP `default-scopes`
config.

Root cause: the EDC environment-variable translator converts `_` →
`.`, so `TX_EDC_IAM_IATP_DEFAULT_SCOPES_MEMBERSHIP_TYPE` becomes
`tx.edc.iam.iatp.default.scopes.membership.type` (dotted). The real
config key is `tx.edc.iam.iatp.default-scopes.membership.type` (with
a **hyphen** in `default-scopes`), which env vars cannot represent.
The DCP extension never sees the scopes and mints tokens without a
nested `bearer_access_scope`.

This repo's `docker-compose.yaml` already mounts
`config/edc-config.properties` at `/app/configuration.properties` and
points the EDC at it via `EDC_FS_CONFIG`. If you've forked the
stack, verify both lines are present in the `controlplane` service
block. The §5.1 smoke-test catches this directly: when scopes are
configured, the inner token is non-null.

### 6.4 Catalog comes back but is empty

The credential types the peer requests must match what the operator
has actually issued into your holder. For Hanka the issued set is
`MembershipCredential` + `BpnCredential` + `DataExchangeGovernanceCredential`,
issued automatically by the onboarding pipeline; confirm they are present
in your holder with:

```bash
curl -sS https://identityhub.hanka.ai/api/credentials/v1/participants/<base64-BPN>/credentials \
    | jq '.[].type'
```

The `config/edc-config.properties` here defines exactly the
`MembershipCredential` + `DataExchangeGovernanceCredential` pair — if the
operator issues more (or differently named) credential types, extend the
file accordingly. **Never** request a credential type the operator does
not issue: the IH returns "more credentials requested than returned" and
the catalog fails outright.

See also [`LIMITATIONS.md`](LIMITATIONS.md) for known issues that this
single-node stack will never fix.
