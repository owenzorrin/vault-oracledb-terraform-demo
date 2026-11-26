#!/bin/bash
# Copyright IBM Corp. 2017, 2026
#
# EC2 user-data — runs once on first boot of the Oracle XE + Vault AMI.
#
# Responsibilities:
#   1. Run Oracle XE configure (sets SYS/SYSTEM password, creates XEPDB1)
#   2. Start the oracle-xe-21c service
#   3. Write the Vault config to /etc/vault.d/vault.hcl
#   4. Write the Vault Enterprise license to /etc/vault.d/vault.license
#   5. Enable and start the vault systemd service
#   (first) Format + mount the EBS data volume at /opt/vault/data
#
# Vault config is rendered by Terraform's templatefile() with the Elastic IP.
# The Oracle Instant Client and Vault Oracle plugin are uploaded by Terraform
# remote-exec provisioners *after* this script completes (cloud-init sentinel).

set -uo pipefail
# Note: -e (exit on error) intentionally omitted — Oracle DBCA and Vault start
# failures are handled by Terraform remote-exec provisioners, not by aborting
# user-data entirely. A hard exit here would leave the instance unbootable.

# =============================================================================
# Vault data volume - format on first use, mount at /opt/vault/data
# =============================================================================
# The EBS volume attached as /dev/sdf holds Raft storage + init.json. On Nitro
# instances it appears as an NVMe device; AL2023's udev rules add the /dev/sdf
# symlink. Fall back to the only other disk if the symlink is missing.
echo "==> Mounting Vault data volume..."
DATA_DEV=""
for _ in $(seq 1 60); do
  for d in /dev/sdf /dev/xvdf; do
    if [ -b "$d" ]; then DATA_DEV=$(readlink -f "$d"); break 2; fi
  done
  sleep 2
done
if [ -z "$DATA_DEV" ]; then
  ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
  DATA_DEV=$(lsblk -dpno NAME,TYPE | awk -v root="/dev/$ROOT_DISK" '$2 == "disk" && $1 != root { print $1; exit }')
fi

if [ -n "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    echo "==> Formatting $DATA_DEV (first use)..."
    mkfs.xfs -L vault-data "$DATA_DEV"
  fi
  DATA_UUID=$(blkid -s UUID -o value "$DATA_DEV")
  mkdir -p /opt/vault/data
  grep -q "UUID=$DATA_UUID" /etc/fstab || \
    echo "UUID=$DATA_UUID /opt/vault/data xfs defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q /opt/vault/data || mount /opt/vault/data
  chown vault:vault /opt/vault/data
  chmod 700 /opt/vault/data
  echo "==> $DATA_DEV mounted at /opt/vault/data."
else
  echo "WARNING: Vault data volume not found; Raft data stays on the root volume."
fi

# =============================================================================
# Oracle XE - configure + start
# =============================================================================
# Use the RPM's own configure (runs netca then dbca with the right flags).
# libxcrypt-compat provides libcrypt.so.1, required by the bundled perl that
# DBCA uses for post-creation scripts (ordlib.sql). Installed here so AMIs
# built before this fix also work.
echo "==> Installing libxcrypt-compat..."
dnf install -y libxcrypt-compat

# Variable names must match what /etc/init.d/oracle-xe-21c reads.
cat > /etc/sysconfig/oracle-xe-21c.conf <<'XECONF'
CHARSET=AL32UTF8
LISTENER_PORT=1521
EM_EXPRESS_PORT=5500
XECONF

echo "==> Running Oracle XE configure..."
ORACLE_PASSWORD='${oracle_password}' /etc/init.d/oracle-xe-21c configure 2>&1

echo "==> Starting oracle-xe-21c service..."
systemctl start oracle-xe-21c

# =============================================================================
# Vault config + license
# =============================================================================
echo "==> Writing Vault config..."
cat > /etc/vault.d/vault.hcl <<'VAULTCFG'
${vault_config}
VAULTCFG

echo "==> Writing Vault Enterprise license..."
printf '%s' '${vault_license}' > /etc/vault.d/vault.license
chmod 640 /etc/vault.d/vault.license
chown vault:vault /etc/vault.d/vault.license

# Point Vault at the license file via environment
mkdir -p /etc/vault.d
cat >> /etc/vault.d/vault.hcl <<'EOF'
license_path = "/etc/vault.d/vault.license"
EOF

chown vault:vault /etc/vault.d/vault.hcl

echo "==> Enabling and starting Vault service..."
systemctl enable vault
# Start Vault — failure here is non-fatal; Terraform remote-exec will verify
# and restart if needed after uploading artifacts.
systemctl start vault || echo "WARNING: vault.service failed initial start — Terraform will retry after upload."

echo "==> User-data complete."
