# Known Limitations

This stack is sized as a **single-node, minimum-viable production EDC**. It is honest about what it doesn't do. If any of the limits below would block your use case, you'll need to extend the stack or move to a different deployment topology.

## Versions in use

| Component | Image / Tag | Latest available | Why this version |
|---|---|---|---|
| Tractus-X EDC control-plane | `tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0` | `0.13.0-rc1` | `0.12.0` is the latest **stable** release. `0.13.0` is still RC. |
| Tractus-X EDC data-plane | `tractusx/edc-dataplane-hashicorp-vault:0.12.0` | `0.13.0-rc1` | same |
| HashiCorp Vault | `hashicorp/vault:1.21.4` | `2.0.0` | `2.0.0` is the new IBM-lifecycle release (April 2026, 23 days old at the time of writing), with breaking changes to Azure auth and SCIM. The `1.21.x` line is the proven production track. Upgrade to `2.x` is non-destructive (raft snapshot first) but should wait until it's seen a few patch releases. |
| PostgreSQL | `postgres:17.9-alpine` | `17.9` | latest in the 17 series |
| Caddy | `caddy:2.11.2-alpine` | `2.11.2` | latest |

## Architectural limits

### High availability — none

There is exactly one of every component. Any of them dying takes the whole stack down.

- No replication of postgres → no read replicas, no failover.
- Single vault node → if the vault container dies mid-write to its raft log, you might need to recover from snapshot.
- One control-plane and one data-plane → no horizontal scaling.

For HA, move to Kubernetes with the upstream [`eclipse-tractusx/tractusx-edc` Helm chart](https://github.com/eclipse-tractusx/tractusx-edc/tree/main/charts/tractusx-connector).

### Vault unseal keys live on the host

`vault-init` writes the unseal keys + root token to `/vault/state/init.json` inside the `vault-state` named volume, then auto-unseals on every restart by reading that file. The trade-off:

- ✅ The vault recovers automatically across host reboots.
- ❌ Anyone with read access to the host's docker volumes can unseal the vault.

This is a common trade-off for self-hosted single-node vault deployments. For higher security you would need either:

- A KMS-backed auto-unseal (AWS KMS, GCP KMS, Azure Key Vault, Transit) — requires a cloud account.
- Manual unseal on every restart by an operator entering the keys interactively.

### Vault uses raft storage

Single-node raft is functional but is HashiCorp's "integrated storage" intended for multi-node deployments. For pure single-node, `file` storage would also work; we picked raft because expanding to multi-node later is easier.

### EDC vault token is periodic, not AppRole

The Tractus-X EDC HashiCorp Vault extension at 0.12.0 only supports token authentication, not AppRole. We mitigate this by:

- Generating a **non-root, periodic, policy-scoped** token (`edc` policy, read-only access to two specific paths).
- Auto-rotating it via `vault-init` when it expires.

If the token is leaked, an attacker can read `secret/sts-oauth-client-secret` and `secret/token-signer-key` — that is, they can impersonate this EDC against the dataspace. They cannot escalate inside vault.

A vault-agent sidecar pattern (AppRole + token renewal in a separate container) would be slightly stronger but requires a custom EDC entrypoint and isn't worth the complexity for a single-tenant connector.

### env_file timing — must use `scripts/up.sh`

Docker Compose reads `env_file` once at the start of `up`, before any container runs. The EDC vault token is delivered through `runtime/edc-vault.env`, which `vault-init` populates. On a cold start that file is empty, so a plain `docker compose up -d` would launch the EDC services with no token. `scripts/up.sh` does it in two phases.

After the first `up`, the file is persisted on the host, so subsequent `docker compose up -d` *would* work — but `scripts/up.sh` is the only command that's safe in **all** states (cold start, after long stop, after `down -v`, etc.). Use it everywhere.

### TLS handled by Caddy → port 80 must be reachable

Caddy uses Let's Encrypt's HTTP-01 challenge by default, which requires port 80 reachable from the public Internet. If your network blocks 80:

- Use the DNS-01 challenge with a Caddy DNS provider plugin (requires a custom Caddy build with the right module).
- Or terminate TLS upstream and disable the bundled Caddy (see `ONBOARDING.md` §4).

### Public data-plane is the bottleneck for transfers

All data transferred to peers goes through `dataplane:8081` → Caddy → public Internet. Caddy is fast but a single instance. For high-throughput transfers (e.g., large file or stream pulls), the EDC's pluggable data-plane architecture supports offloading to S3, Azure Blob, etc. — that's a custom data-plane image, not in scope here.

## Operational limits

### No backup automation

`postgres-data`, `vault-data`, and `vault-state` are persistent docker volumes. There is no scheduled backup. The `ONBOARDING.md` document includes manual `tar czf` recipes — wire them into a cron job on the host.

### No metrics or observability

No Prometheus exporter, no log shipping, no distributed tracing. The EDC writes structured logs to stdout that are visible via `docker compose logs`. To wire them into your observability stack:

- Ship `docker compose logs` to Loki / ELK / Datadog using a docker-driver log plugin.
- Add a Prometheus exporter sidecar — the EDC has a `tractusx-edc-prometheus` extension you can build into a custom controlplane image.

### No secret rotation automation

`STS_CLIENT_SECRET` and `TOKEN_SIGNER_KEY_JWK` live in `.env`. Rotating them means:

1. Get a new STS secret from the operator (or generate a new keypair).
2. Edit `.env`.
3. `./scripts/up.sh` (this re-runs `vault-init` which re-writes the secrets in vault).
4. For the token-signer keypair: send the new public JWK to the operator and wait for them to update your DID document **before** restarting the EDC.

### No CI / no tests

The repo ships with no CI pipeline, no integration tests, no health probes beyond container-level health checks. Interop with each target dataspace must be verified manually after deployment (see `ONBOARDING.md` §5).

## Functional limits

### Single tenant only

EDC 0.12.0 introduced participant context IDs in preparation for multi-tenancy, but a single connector still serves one BPN / DID. Multi-tenant configuration is not exposed here.

### No DID self-registration

`TX_EDC_DID_SERVICE_SELF_REGISTRATION_ENABLED=false`. The dataspace operator is responsible for hosting your `did.json`. EDC 0.12.0 supports self-registration to systems like SAP DIV, but enabling it requires extra configuration and operator coordination — out of scope.

### Trusted issuers — one per stack

Only `EDC_IAM_TRUSTED-ISSUER_0-*` is configured. To support multiple issuers (e.g., to talk to two unrelated dataspaces simultaneously), add `EDC_IAM_TRUSTED-ISSUER_1-*`, `_2-*`, etc. directly in the compose file.

### Single DSP version

EDC 0.12.0 dropped DSP version `2024/1`. It supports `2025/1` and the in-progress `0.8`. Peers still on 0.10.x or earlier may be unable to negotiate — verify the DSP version with each target operator before assuming.

### No Postgres connection pooling

Direct JDBC, no PgBouncer. Fine for low-to-moderate transfer rates; revisit if you saturate connections.

### Resource limits not set

The compose file does not set `cpu_limit` / `memory_limit`. The JVM gets `-Xmx512m` by default (`JAVA_TOOL_OPTIONS` in `.env`); raise it if your catalog or transfer rate grows. Set host-level limits via systemd / cgroups if multi-tenanting the host.

## Compliance / data-sovereignty caveats

- Caddy's Let's Encrypt account is created with the email in `ACME_EMAIL`. That email is shared with Let's Encrypt and ISRG. If your compliance regime forbids that, use an internal CA + your own reverse proxy.
- Vault's raft log and Postgres data are unencrypted at rest at the docker-volume level. If the host's disk is not full-disk-encrypted, anyone with raw disk access can read both.
- The connector logs (default `INFO` + `FINE` for `org.eclipse.edc` and `org.eclipse.tractusx`) may contain BPNs, DIDs, contract identifiers, and asset metadata. Review your log retention policy.

## What this stack is **not** suitable for

- Public-facing connectors handling regulated data (HIPAA, PCI, GDPR-strict). The single-node footprint and lack of formal audit trail make this a poor fit.
- Multi-region or geo-redundant deployments.
- Production dataspaces with explicit HA / SLA requirements — single-node Compose cannot meet them.
- Connectors that need to scale beyond ~50-100 simultaneous transfers.

For any of those, take this repo as a reference and reimplement on Kubernetes with the upstream Helm chart at [`eclipse-tractusx/tractusx-edc`](https://github.com/eclipse-tractusx/tractusx-edc/tree/main/charts/tractusx-connector).
