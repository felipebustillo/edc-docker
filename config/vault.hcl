# Vault production configuration.
#
# Single-node raft storage. The data dir is backed by a named docker volume
# so secrets and the raft log survive container restarts.
#
# TLS is intentionally disabled at this layer because vault is only reachable
# from inside the docker network. External traffic goes through Caddy (HTTPS).

storage "raft" {
    path    = "/vault/data"
    node_id = "node1"
}

listener "tcp" {
    address     = "0.0.0.0:8200"
    tls_disable = "true"
}

api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8201"

ui            = false
disable_mlock = false
