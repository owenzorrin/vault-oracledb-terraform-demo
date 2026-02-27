# Vault Oracle Database Secrets Engine Demo (Terraform)

Quick setup for testing the Oracle database plugin for Vault on an M series Mac with Docker using Terraform.

## Prerequisites

- M series Mac with Docker installed
- [Colima](https://github.com/abiosoft/colima#installation) installed (`brew install colima`)
- Colima dependencies: `brew install lima-additional-guestagents qemu`
- Terraform installed (`brew install terraform`)
- `jq` installed (`brew install jq`)
- Vault CLI installed (`brew install vault`)
- Vault Enterprise license exported as `VAULT_LICENSE`

## Project Structure

```
.
├── main.tf                  # Terraform configuration
├── config/
│   └── config.hcl           # Vault server configuration
├── scripts/
│   ├── create_users.sql     # Oracle user creation SQL
│   └── verify_users.sql     # Oracle user verification SQL
├── client/                  # Oracle Instant Client (downloaded by Terraform)
├── plugin/                  # Vault Oracle plugin binary (downloaded by Terraform)
├── data/                    # Vault Raft storage + init.json (host-mounted volume)
├── .vault-token             # Root token (generated during init, gitignored)
├── .vault-unseal-key        # Unseal key (generated during init, gitignored)
└── .gitignore
```

## Setup

### 1. Start Colima

```bash
colima start --arch x86_64 --memory 4
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

### 2. Export Vault License

```bash
export TF_VAR_vault_license="$VAULT_LICENSE"
```

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Create Placeholder Token

The Vault provider requires a token file at plan time. Create a placeholder that will be overwritten during Stage 1:

```bash
echo "placeholder" > .vault-token
```

### 5. Stage 1 — Deploy Containers + Bootstrap

This spins up the Vault and Oracle XE containers, initializes and unseals Vault, and creates the Oracle database users:

```bash
terraform apply \
  -target=terraform_data.vault_init \
  -target=terraform_data.oracle_users
```

After this step:
- Vault is initialized, unsealed, and running
- `init.json` is saved to `data/init.json` (persisted on the host)
- Root token is written to `.vault-token`
- Unseal key is written to `.vault-unseal-key`
- Oracle `vault` and `staticvault` users are created in XEPDB1

### 6. Stage 2 — Configure Vault

This registers the Oracle database plugin, enables the database secrets engine, and creates both dynamic and static roles:

```bash
terraform apply
```

If the Vault container was recreated between stages, this step will automatically unseal Vault before proceeding.

## Verify

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(cat .vault-token)

# Test dynamic credentials
vault read database/creds/my-role

# Test static credentials
vault read database/static-creds/static-role
```

## Teardown

The Vault provider requires a running Vault to destroy its resources. Since we're tearing everything down, remove those resources from state first, then destroy the rest:

```bash
terraform state rm vault_mount.database
terraform state rm vault_generic_endpoint.oracle_connection
terraform state rm vault_database_secret_backend_role.dynamic_role
terraform state rm vault_database_secret_backend_static_role.static_role
terraform destroy -auto-approve
docker rm -f vault-test oracle-xe-test
colima stop
```

## Starting Fresh

```bash
terraform state rm vault_mount.database 2>/dev/null
terraform state rm vault_generic_endpoint.oracle_connection 2>/dev/null
terraform state rm vault_database_secret_backend_role.dynamic_role 2>/dev/null
terraform state rm vault_database_secret_backend_static_role.static_role 2>/dev/null
terraform destroy -auto-approve
docker rm -f vault-test oracle-xe-test
rm -rf data/raft data/vault.db
echo "placeholder" > .vault-token

# Stage 1
terraform apply \
  -target=terraform_data.vault_init \
  -target=terraform_data.oracle_users

# Stage 2
terraform apply
```

## Notes

- **Two-stage apply**: Required because Vault must be initialized and unsealed before the Terraform Vault provider can configure it.
- **Oracle startup**: Oracle XE can take a few minutes to fully initialize. The provisioner includes a retry loop.
- **Binary downloads**: The Oracle Instant Client and Vault Oracle plugin are downloaded automatically on the first run and cached in `client/` and `plugin/`.
- **Container recreation**: The Vault container uses `lifecycle { ignore_changes = [capabilities] }` to prevent unnecessary recreation due to Docker capability name normalization. Init credentials are saved to the host-mounted `data/` volume so they survive container recreation.
- **Colima Docker socket**: You must export `DOCKER_HOST` pointing to Colima's socket, or add it to your `~/.zshrc` for persistence.
