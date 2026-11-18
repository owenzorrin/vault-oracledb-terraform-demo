# Copyright IBM Corp. 2017, 2026
#
# Vault server configuration for AWS deployment.
# Rendered by Terraform's templatefile() — ${vault_api_addr} is replaced with
# the Elastic IP before being written to /etc/vault.d/vault.hcl on the EC2 instance.

listener "tcp" {
    address         = "0.0.0.0:8200"
    cluster_address = "0.0.0.0:8201"
    tls_disable     = 1
}

storage "raft" {
    path    = "/opt/vault/data"
    node_id = "vault-1"
}

api_addr     = "http://${vault_api_addr}:8200"
cluster_addr = "http://${vault_api_addr}:8201"
cluster_name = "vault-cluster"
ui           = true
log_level    = "trace"
raw_storage_endpoint        = true
disable_performance_standby = false
plugin_directory            = "/vault/plugin"
disable_mlock               = true
