# Vault Oracle Database Secrets Engine Demo — AWS (Terraform + Packer)

AWS version of the [local Docker demo](../README.md). Deploys **Vault Enterprise** and **Oracle Database XE 21c** on a single EC2 instance — both running natively as systemd services, no Docker required.

## Architecture

```
AWS (us-east-1)
└── VPC (10.0.0.0/16)
    └── Public Subnet (10.0.1.0/24)
        └── EC2 (t3.medium, custom Oracle XE + Vault AMI)  ←── Elastic IP
              ├── oracle-xe-21c  (systemd, port 1521)
              └── vault          (systemd, port 8200)
```

The Packer AMI bakes Oracle XE 21c and the Vault Enterprise binary onto Amazon Linux 2023. On first EC2 boot, user-data installs `libxcrypt-compat`, runs the RPM's own `/etc/init.d/oracle-xe-21c configure` (sets the SYS/SYSTEM password, creates `XEPDB1`), writes the Vault config + license, and starts both services. Terraform then uploads the Oracle Instant Client and Vault Oracle plugin, creates the Oracle users, initializes and unseals Vault, and configures the database secrets engine.

## Prerequisites

- AWS CLI configured (`aws configure`, or SSO / exported `AWS_*` variables). If you use temporary credentials, make sure they last long enough: the Packer build takes ~14 minutes and the Terraform deploy another ~15–20 minutes.
- Packer installed (`brew install packer`)
- Terraform installed (`brew install terraform`)
- `jq` installed (`brew install jq`)
- An EC2 key pair created in your AWS account
- Vault Enterprise license
- `ssh` and `tar` on your workstation (used to upload the Oracle Instant Client)

## Project Structure

```
aws/
├── packer/
│   ├── oracle-xe.pkr.hcl          # Packer — Amazon Linux 2023 + Oracle XE 21c + Vault binary → AMI
│   └── scripts/
│       ├── install_oracle.sh      # Installs Oracle XE 21c RPM + Vault binary + systemd unit
│       └── cleanup.sh             # AMI pre-snapshot cleanup
├── main.tf                        # Terraform — VPC, EC2, remote-exec provisioners, Vault config
├── variables.tf                   # All input variables
├── outputs.tf                     # EC2 IP, Vault address, SSH command
├── userdata.sh.tpl                # First-boot: runs XE configure, writes Vault config + license, starts services
├── config/
│   └── config.hcl.tpl             # Vault config template (api_addr injected at deploy time)
├── terraform.tfvars.example       # Copy to terraform.tfvars
└── scripts/
    ├── create_users.sql            # Oracle user creation (identical to local demo)
    └── verify_users.sql            # Oracle user verification
```

## Setup

### Step 0 — Prerequisites check

```bash
aws sts get-caller-identity   # verify AWS credentials
packer version                # 1.9+
terraform version             # 1.5+
```

### Step 1 — Export credentials and build the custom AMI with Packer

Export your AWS credentials and the Vault Enterprise license in the same shell you will use for Packer **and** Terraform (Steps 1–6). Packer and Terraform both read the AWS variables; Terraform picks up the license from `TF_VAR_vault_license` and writes it to the instance at first boot, so the license is never baked into the AMI.

```bash
# 1. AWS credentials (omit AWS_SESSION_TOKEN if you use long-lived IAM user keys)
export AWS_ACCESS_KEY_ID=<your-access-key-id>
export AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
export AWS_SESSION_TOKEN=<your-session-token>
export AWS_DEFAULT_REGION=us-east-1

# 2. Vault Enterprise license — Terraform reads TF_VAR_<variable name>.
export VAULT_LICENSE=<your-vault-enterprise-license>
export TF_VAR_vault_license="$VAULT_LICENSE"

aws sts get-caller-identity   # confirm the credentials work
```

Then build the AMI. This runs once (or when bumping versions) and takes ~14 minutes, mostly downloading and installing Oracle's 2.2 GB RPM and snapshotting the instance.

```bash
cd aws/packer
packer init .
packer build -var 'aws_region=us-east-1' oracle-xe.pkr.hcl
```

The AMI bakes in:
- Amazon Linux 2023 base (x86_64)
- Oracle XE 21c (installed, **not yet configured** — password is set at first boot)
- Vault Enterprise binary at `/usr/local/bin/vault`
- `vault` system user, directories (`/etc/vault.d`, `/opt/vault/data`, `/vault/plugin`, `/vault/client`), and systemd unit (not yet enabled)

On success, the AMI ID is written to `manifest.json` (run this from `aws/packer`, where Step 1 left you):

```bash
cat manifest.json | jq -r '.builds[-1].artifact_id' | cut -d: -f2
# → ami-0abc1234...
```

### Step 2 — Configure Terraform

```bash
cd ..    # back to the aws/ directory (Step 1 ended in aws/packer)
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

| Variable | Value |
|---|---|
| `ami_id` | AMI ID from Step 1 |
| `key_pair_name` | Name of your EC2 key pair |
| `ssh_private_key_path` | Path to the `.pem` file (e.g. `~/.ssh/my-key.pem`). It must not be readable by others: run `chmod 600` on it first, or `ssh` ignores the key and the Instant Client upload fails (see Troubleshooting). |
| `vault_license` | Leave the line commented out if you exported `TF_VAR_vault_license` in Step 1 (a value in the file overrides the environment variable). Otherwise uncomment it and paste the license **exactly** (single line, no spaces or newlines). A single wrong character makes Vault fail with `no valid licenses found`. |
| `oracle_password` | SYS/SYSTEM password for Oracle XE |
| `allowed_cidr` | Your IP CIDR (e.g. `1.2.3.4/32`) — defaults to `0.0.0.0/0` for testing |

### Step 3 — Initialize Terraform

```bash
terraform init
```

### Step 4 — Create placeholder token

The Vault provider requires a token file at plan time:

```bash
echo "placeholder" > .vault-token
```

### Step 5 — Stage 1: Deploy EC2 + Bootstrap

Provisions VPC, EC2, uploads Oracle Instant Client + Vault plugin, creates Oracle DB users, initializes and unseals Vault. `-target` on the two leaf resources pulls in everything they depend on:

```bash
terraform apply \
  -target=terraform_data.vault_init \
  -target=terraform_data.oracle_users
```

What happens on EC2 first boot (user-data, automatic, ~13 minutes; `terraform apply` waits for it):
1. `libxcrypt-compat` is installed (provides `libcrypt.so.1`, needed by the perl bundled with Oracle's DBCA)
2. `/etc/init.d/oracle-xe-21c configure` runs — sets SYS/SYSTEM password, creates `XEPDB1`
3. `oracle-xe-21c` systemd service starts
4. Vault config written to `/etc/vault.d/vault.hcl` (with Elastic IP as `api_addr`)
5. Vault Enterprise license written to `/etc/vault.d/vault.license`
6. `vault` systemd service starts (may fail here — the plugin isn't uploaded yet; Terraform restarts it)

What Terraform then does:
- Uploads Oracle Instant Client to `/vault/client/` (streamed as a `tar` over SSH to preserve symlinks)
- Uploads Vault Oracle plugin to `/vault/plugin/` and sets its execute bit
- Uploads SQL scripts, creates `vault` and `staticvault` Oracle users in `XEPDB1` (fails the apply if the users can't be created)
- Runs `vault operator init`, unseals, writes `.vault-token` and `.vault-unseal-key` locally

### Step 6 — Stage 2: Configure Vault

```bash
terraform apply
```

Registers the Oracle database plugin, enables the database secrets engine, creates dynamic and static roles.

## Verify

```bash
export VAULT_ADDR=http://$(terraform output -raw elastic_ip):8200
export VAULT_TOKEN=$(cat .vault-token)

# Test dynamic credentials
vault read database/creds/my-role

# Test static credentials
vault read database/static-creds/static-role
```

## Manage Vault service on EC2

```bash
# SSH in
ssh -i ~/.ssh/my-key.pem ec2-user@<ELASTIC_IP>

# Vault service management
sudo systemctl status vault
sudo systemctl restart vault
sudo journalctl -u vault -f

# Vault CLI (as ec2-user)
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(sudo cat /opt/vault/data/.vault-token)

# Oracle XE service management
sudo systemctl status oracle-xe-21c
sudo systemctl restart oracle-xe-21c
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `InvalidClientTokenId` from the AWS provider | AWS credentials expired or invalid. Refresh them and check `aws sts get-caller-identity`. |
| `vault.service` keeps restarting; journal says `licensing could not be initialized: no valid licenses found` | `vault_license` in `terraform.tfvars` doesn't exactly match the license file. Fix it and replace the instance: `terraform apply -replace=aws_instance.vault_oracle`. |
| First boot: DBCA errors, `oracle-xe-21c` active but no `XE` entry in `/etc/oratab`, no database | Check `/var/log/cloud-init-output.log`. Known causes: missing `libcrypt.so.1` (install `libxcrypt-compat`), or `/etc/sysconfig/oracle-xe-21c.conf` using the wrong variable names — the init script reads `CHARSET`, `LISTENER_PORT`, `EM_EXPRESS_PORT`, not `ORACLE_*`. Re-run with `sudo ORACLE_PASSWORD=<pw> /etc/init.d/oracle-xe-21c configure`. |
| Instant Client upload fails part-way (`Upload failed: Process exited with status 1`) | The `file` provisioner can't copy the symlinks in `instantclient_*`. The config uploads via `tar` over SSH instead; `ssh` and `tar` must be available locally. |
| `terraform_data.upload_oracle_client` fails with `exit status 255`, `UNPROTECTED PRIVATE KEY FILE!` / `bad permissions` / `Permission denied (publickey...)` | The `.pem` in `ssh_private_key_path` has permissions that are too open (e.g. 0644), so `ssh` ignores it. `chmod 600 <key.pem>` and re-run the Step 5 `terraform apply` — the existing instance is reused, so you don't wait for first boot again. |
| `fork/exec .../vault-plugin-database-oracle: permission denied` | The plugin binary lost its execute bit. `sudo chmod 755 /vault/plugin/*/vault-plugin-database-oracle` on the instance. |
| `ORA-01017: invalid username/password` when Vault writes `database/config/...` | The `vault` Oracle user wasn't created. Check `/tmp/create_users.sql` ran in `XEPDB1`. Note `/tmp` is a tmpfs and is cleared on reboot — re-run `terraform apply -replace=terraform_data.upload_scripts -replace=terraform_data.oracle_users`. |
| `ssh: connect ... Connection refused` after the instance was stopped/started | Wait for the instance to finish booting, then re-run `terraform apply`. |
| `terraform_data.bootstrap` fails with `dial tcp ...:22: i/o timeout`, and `cloud-init-output.log` shows `dnf` timeouts | The instance had no internet route at first boot. The route table must be associated before the instance is created (`aws_instance.vault_oracle` depends on it). Check your `allowed_cidr` includes your current IP, then `terraform destroy` and re-run Step 5. |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Expected after replacing the instance (same Elastic IP, new host key). Run `ssh-keygen -R <ELASTIC_IP>`. |

## Teardown

Run this in a shell where the AWS credentials and `TF_VAR_vault_license` from Step 1 are still exported. `terraform destroy` requires `vault_license` even though nothing is created, and any non-empty value works.

```bash
# Remove Vault provider resources from state first (Vault must be running to destroy them)
terraform state rm vault_mount.database
terraform state rm vault_generic_endpoint.oracle_connection
terraform state rm vault_database_secret_backend_role.dynamic_role
terraform state rm vault_database_secret_backend_static_role.static_role

# Destroy all AWS infrastructure
terraform destroy -auto-approve
```

> **Note:** The EBS data volume has `delete_on_termination = false`. Every instance replacement (`-replace=aws_instance.vault_oracle`) and teardown leaves the previous 10 GB volume behind, and Terraform creates a fresh one each time — it does not reattach the old one. Delete unattached volumes in the AWS console to avoid charges.

To also delete the Packer AMI and its snapshot:
```bash
SNAP=$(aws ec2 describe-images --image-ids <ami-id> --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
aws ec2 deregister-image --image-id <ami-id>
aws ec2 delete-snapshot --snapshot-id "$SNAP"
```

## Notes

- **Two-stage apply**: Same pattern as the local demo — Vault must be initialized and unsealed before the Terraform Vault provider can configure it.
- **No Docker**: Both Oracle XE and Vault run as native systemd services. The Vault binary is installed directly on the AMI; no container runtime needed.
- **Oracle XE configure timing**: `oracle-xe-21c configure` runs in user-data on first boot and takes roughly 13 minutes on a `t3.medium` (database creation dominates). The `terraform_data.oracle_users` provisioner waits for the service to be active and `XEPDB1` to be open before creating users.
- **Existing AMIs still work**: user-data installs `libxcrypt-compat` and rewrites `/etc/sysconfig/oracle-xe-21c.conf` at boot, so an AMI built before those fixes needs no rebuild. New Packer builds include both.
- **Vault config + license**: Both are written by user-data from Terraform template variables — no separate upload step needed. `api_addr` is set to the Elastic IP so it's correct before Vault ever starts.
- **Vault plugin layout**: Same subfolder requirement as the local demo — the binary must live in `plugin/vault-plugin-database-oracle_0.13.0+ent_linux_amd64/vault-plugin-database-oracle`.
- **EIP stability**: Elastic IP keeps `api_addr` stable across EC2 stop/start cycles.
- **EBS data volume**: holds Raft storage, `init.json` and credentials. It is created with `delete_on_termination = false`, so it outlives the instance (see the teardown note).
- **Bumping Vault version**: Update `VAULT_VERSION` in [`packer/scripts/install_oracle.sh`](packer/scripts/install_oracle.sh), bump the plugin version in the `terraform_data.vault_plugin` download URL and `-version` flag in `terraform_data.vault_plugin_register`, then rebuild the AMI with Packer.
