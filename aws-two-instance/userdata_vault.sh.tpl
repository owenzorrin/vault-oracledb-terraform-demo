#!/bin/bash
# Copyright IBM Corp. 2017, 2026
#
# EC2 user-data for the VAULT host (stock Amazon Linux 2023, no custom AMI).
#
# Installs the Vault Enterprise binary, creates the vault user + directories,
# writes the systemd unit, Vault config and license, and starts Vault. Also
# installs the OS libraries the Oracle Instant Client / Vault Oracle plugin
# need at runtime (libaio, libnsl, libxcrypt-compat) — on the single-instance
# layout these arrived indirectly with the Oracle XE packages.
#
# The Instant Client and the plugin binary are uploaded by Terraform afterwards.

set -euo pipefail

# =============================================================================
# Runtime libraries for Oracle Instant Client
# =============================================================================
echo "==> Installing packages..."
dnf install -y libaio libnsl libxcrypt-compat unzip jq

# =============================================================================
# Vault Enterprise binary
# =============================================================================
echo "==> Downloading Vault Enterprise ${vault_version}..."
curl -fsSL --retry 5 --retry-delay 5 -o /tmp/vault.zip \
  "https://releases.hashicorp.com/vault/${vault_version}/vault_${vault_version}_linux_amd64.zip"
unzip -o /tmp/vault.zip -d /usr/local/bin/
chmod +x /usr/local/bin/vault
rm -f /tmp/vault.zip
/usr/local/bin/vault version

echo "==> Creating vault system user and directories..."
useradd --system --home /etc/vault.d --shell /bin/false vault || true
mkdir -p /etc/vault.d /opt/vault/data /vault/plugin /vault/client
chown -R vault:vault /etc/vault.d /opt/vault /vault/plugin /vault/client
chmod 700 /opt/vault/data

echo "==> Installing Vault systemd unit..."
cat > /etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=HashiCorp Vault Enterprise
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
Type=notify
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

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

cat >> /etc/vault.d/vault.hcl <<'EOF'
license_path = "/etc/vault.d/vault.license"
EOF
chown vault:vault /etc/vault.d/vault.hcl

echo "==> Enabling and starting Vault service..."
systemctl enable vault
# Non-fatal: the plugin is not uploaded yet; Terraform restarts Vault if needed.
systemctl start vault || echo "WARNING: vault.service failed initial start — Terraform will retry after upload."

echo "==> User-data complete."
