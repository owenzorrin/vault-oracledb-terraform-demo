# Vault Oracle Database Secrets Engine Demo — AWS, two instances (Terraform only)

Variant of the [single-instance AWS demo](../aws/README.md) with **no Packer / custom AMI**. Vault Enterprise and Oracle Database XE 21c run on **separate EC2 instances** built from an Amazon Linux 2023 based AMI (`ami_id`, default: the approved private image `ami-04ee983f7bb25093b`); everything is installed by user-data at first boot.

## Architecture

```
AWS (us-east-1)
└── VPC (10.0.0.0/16)
    └── Public Subnet (10.0.1.0/24)
        ├── EC2 #1  t3.small   Vault Enterprise (systemd, :8200)  ←── Elastic IP
        │            + Oracle Instant Client + Vault Oracle plugin
        └── EC2 #2  t3.medium  Oracle XE 21c (systemd, :1521)
                     SG: 1521 reachable ONLY from the Vault host's security group
```

Vault connects to Oracle over the VPC private IP (`{{username}}/{{password}}@<oracle_private_ip>:1521/XEPDB1`).

## Prerequisites

- AWS credentials exported (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION=us-east-1`). Temporary credentials must last ~30 minutes.
- Terraform 1.5+, `jq`, `ssh`, `tar`
- An EC2 key pair, with the `.pem` file set to **`chmod 600`**
- Vault Enterprise license

## Setup

```bash
# Credentials + license, in the shell used for all steps below
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_SESSION_TOKEN=...
export AWS_DEFAULT_REGION=us-east-1
export TF_VAR_vault_license="<your-vault-enterprise-license>"   # single line, no spaces/newlines
aws sts get-caller-identity

cd aws-two-instance
cp terraform.tfvars.example terraform.tfvars   # set key_pair_name, ssh_private_key_path (and optionally ami_id, allowed_cidr)
chmod 600 <your-key.pem>
terraform init
echo "placeholder" > .vault-token              # the Vault provider needs a token file at plan time
```

### Stage 1 — deploy both hosts and bootstrap

```bash
terraform apply \
  -target=terraform_data.vault_init \
  -target=terraform_data.oracle_users
```

Both instances boot in parallel:

- **Vault host** (a few minutes): installs `libaio`, `libnsl`, `libxcrypt-compat`, downloads the Vault binary, writes config + license, starts Vault. Terraform then uploads the Oracle Instant Client and plugin, checks the Instant Client's shared libraries with `ldd`, and runs `vault operator init` / unseal.
- **Oracle host** (~13–15 minutes, dominates the run): installs Oracle's dependencies, kernel parameters and limits, downloads and installs the 2.2 GB RPM, verifies it (`rpm -q`, `ldd` on `oracle`/`sqlplus`/`lsnrctl`/`dbca`, `libcrypt.so.1`, `libaio.so.1`), runs `oracle-xe-21c configure`, checks `/etc/oratab`, and writes `/var/lib/oracle-xe.ready`. On any failure it writes `/var/lib/oracle-xe.failed` and Terraform fails immediately instead of waiting.

Terraform then creates the `vault` and `staticvault` Oracle users in `XEPDB1`.

### Stage 2 — configure Vault

```bash
terraform apply
```

Registers the Oracle plugin, enables the database secrets engine, creates the dynamic and static roles.

## Verify

```bash
export VAULT_ADDR=http://$(terraform output -raw elastic_ip):8200
export VAULT_TOKEN=$(cat .vault-token)
vault read database/creds/my-role
vault read database/static-creds/static-role
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Oracle user-data failed: ...` from `bootstrap_oracle` | Read `/var/log/cloud-init-output.log` on the Oracle host (`terraform output oracle_ssh_command`). The failing step is named in the message. To retry: `terraform apply -replace=aws_instance.oracle -replace=terraform_data.bootstrap_oracle -target=terraform_data.vault_init -target=terraform_data.oracle_users`. |
| `curl: (23) Failure writing output` during the Oracle RPM download | The RPM was being written to `/tmp`, a RAM-backed tmpfs on Amazon Linux 2023. The user-data uses `/var/tmp`. |
| `unresolved Instant Client libraries` | A shared library is missing on the Vault host. The check runs `ldd` with `LD_LIBRARY_PATH=/vault/client/instantclient_19_28`; install the missing package in `userdata_vault.sh.tpl`. |
| `UNPROTECTED PRIVATE KEY FILE!` / `Permission denied (publickey)` | `chmod 600` the `.pem` file, then re-run Stage 1. |
| `ORA-12541` / connection refused when Vault writes `database/config/...` | Check the Oracle security group allows 1521 from the Vault SG, and `lsnrctl status` on the Oracle host. |
| `tar: Cannot open: File exists` during the Instant Client upload | Files are owned by `vault` from a previous run. The upload step now resets ownership first; re-run Stage 1. |
| `InvalidClientTokenId` | AWS credentials expired. Refresh them. |
| `no valid licenses found` in the Vault journal | `TF_VAR_vault_license` is wrong. Fix it and `terraform apply -replace=aws_instance.vault`. |

## Teardown

Run in a shell with the AWS credentials and `TF_VAR_vault_license` exported:

```bash
terraform state rm vault_mount.database
terraform state rm vault_generic_endpoint.oracle_connection
terraform state rm vault_database_secret_backend_role.dynamic_role
terraform state rm vault_database_secret_backend_static_role.static_role
terraform destroy -auto-approve
```

No volumes are left behind; both instances use root volumes that are deleted with the instance.

## Notes

- **Two-stage apply**: Vault must be initialized and unsealed before the Terraform Vault provider can configure it.
- **Vault provider token**: `.vault-token` is a placeholder until Stage 1 replaces it with the real root token.
- **Local caches**: `client/` and `plugin/` hold the downloaded Instant Client and plugin; they are gitignored and reused on later runs.
- **Bumping versions**: set `vault_version` in `terraform.tfvars` for the Vault binary; bump the plugin version in the `terraform_data.vault_plugin` URL and the `-version` flag in `terraform_data.vault_plugin_register`.
