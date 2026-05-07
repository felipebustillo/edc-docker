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

### 1.2 From the dataspace operator

The default preset targets [Hanka](https://hanka.ai). Sign up there to get a participant context provisioned. If you target a different Tractus-X dataspace, the procedure is the same — replace the operator endpoints in `.env`.

When you onboard with the operator, they will need from **you**:

- The **DSP URL** you plan to expose: `https://<your-public-host>/api/v1/dsp`.
- The **public data-plane URL**: `https://<your-public-host>/api/public`.
- The **public half** of your token-signer key (an Ed25519 JWK with the `d` field stripped). Generate it with the recipe below before contacting them.

They will give **you** back:

- [ ] **BPN** — your Business Partner Number, e.g. `BPNL00000003XXXX`.
- [ ] **DID** — typically `did:web:<their-host>:<your-BPN>`. They host the `did.json`.
- [ ] **STS client secret** — the OAuth secret your connector uses to talk to their STS.
- [ ] **Trusted-issuer DID** — the DID of their credential issuer (you'll set it as `TRUSTED_ISSUER_DID`).
- [ ] **Confirmation** that they've published your token-signer public key in your DID document.

For Hanka, the operator endpoints are already filled in `presets/hanka.env.example`. For other dataspaces, ask the operator for them explicitly.

### 1.3 Generate the token-signer keypair

The data-plane signs proxy tokens with this key. The **private** half goes into vault. The **public** half goes into your DID document hosted by the operator.

Run on the host:

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
print("PRIVATE:", json.dumps(priv))
print("PUBLIC :", json.dumps(pub))
PY
'
```

Take note of:

- The **PRIVATE** JWK — you'll paste it in `.env` as `TOKEN_SIGNER_KEY_JWK`.
- The **PUBLIC** JWK — you'll send it to the operator. Once they confirm it's in your DID document, proceed.

Once you've sent the public JWK, **delete `signer.pem`**:

```bash
shred -u signer.pem
```

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

Edit `.env` and fill in **every empty value**. Use the table from §1.2.

```bash
$EDITOR .env
```

If `CREDENTIAL_SERVICE_URL` in your preset contains the placeholder `<BASE64_BPN>`, replace it with the base64 (no padding) of your BPN:

```bash
echo -n "$(grep EDC_BPN .env | cut -d= -f2)" | base64 | tr -d '='
```

Also fill in:

```bash
# These are public URLs Caddy will serve:
EDC_DSP_CALLBACK_ADDRESS=https://<your-public-host>/api/v1/dsp
EDC_DATAPLANE_PUBLIC_URL=https://<your-public-host>/api/public
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

After §2.3, ask the Hanka operator to do a catalog request against your connector:

```bash
# from a Hanka-side connector:
curl -X POST <hanka-edc>/management/v3/catalog/request -d '{
    "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
    "counterPartyAddress": "https://<your-public-host>/api/v1/dsp",
    "counterPartyId": "<your-DID>",
    "protocol": "dataspace-protocol-http"
}'
```

You should see a JSON catalog response (initially empty, since you haven't published any assets yet). If the request fails:

1. Check `docker compose logs controlplane` for IATP errors.
2. Verify your DID document is reachable: `curl https://<their-host>/<your-BPN>/did.json`.
3. See [`LIMITATIONS.md`](LIMITATIONS.md) for known issues.
