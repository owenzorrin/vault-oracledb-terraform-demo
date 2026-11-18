#!/bin/bash
# Copyright IBM Corp. 2017, 2026
#
# Installs Oracle Database XE 21c and Vault Enterprise on Amazon Linux 2023.
# Run by Packer as root during AMI build.
#
# Amazon Linux 2023 notes:
#   - No oracle-database-preinstall-21c package exists for AL2023.
#     We install the equivalent dependencies manually.
#   - Oracle XE 21c RPM was built for OL8/RHEL8 but installs cleanly on AL2023
#     since AL2023 is RHEL9-compatible with RHEL8 RPM compatibility.
#   - /etc/init.d/oracle-xe-21c configure is NOT run here — the password is a
#     Terraform variable unknown at AMI build time. configure runs in user-data
#     on first EC2 boot.

set -euo pipefail

VAULT_VERSION="2.0.4+ent"

# =============================================================================
# Oracle XE 21c preinstall dependencies
# (equivalent to oracle-database-preinstall-21c on OL8)
# =============================================================================

echo "==> Installing Oracle XE preinstall dependencies..."
# compat-openssl11 is NOT available in AL2023 repos — excluded.
# ksh, libibverbs, librdmacm, libXrender-devel confirmed present in AL2023.
dnf install -y \
  bc \
  binutils \
  elfutils-libelf \
  glibc \
  glibc-devel \
  ksh \
  libaio \
  libgcc \
  libibverbs \
  libnsl \
  libxcrypt-compat \
  librdmacm \
  libstdc++ \
  libxcb \
  libX11 \
  libXau \
  libXi \
  libXtst \
  libXrender \
  make \
  net-tools \
  nfs-utils \
  policycoreutils \
  policycoreutils-python-utils \
  smartmontools \
  sysstat \
  unzip \
  jq

# Oracle XE requires these kernel parameters
echo "==> Configuring kernel parameters for Oracle XE..."
cat >> /etc/sysctl.conf <<'EOF'
# Oracle XE requirements
fs.file-max = 6815744
kernel.sem = 250 32000 100 128
kernel.shmmni = 4096
kernel.shmall = 1073741824
kernel.shmmax = 4398046511104
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
fs.aio-max-nr = 1048576
net.ipv4.ip_local_port_range = 9000 65500
EOF
sysctl -p

# Oracle user limits
cat >> /etc/security/limits.conf <<'EOF'
oracle soft nofile 1024
oracle hard nofile 65536
oracle soft nproc 16384
oracle hard nproc 16384
oracle soft stack 10240
oracle hard stack 32768
oracle soft memlock 134217728
oracle hard memlock 134217728
EOF

# =============================================================================
# Oracle Database XE 21c RPM
# =============================================================================

echo "==> Downloading Oracle Database XE 21c RPM..."
curl -fsSL -o /tmp/oracle-xe-21c.rpm \
  https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-21c-1.0-1.ol8.x86_64.rpm

echo "==> Installing Oracle Database XE 21c RPM..."
# Use rpm -ivh --nodeps to bypass the oracle-database-preinstall-21c dependency
# declaration — dnf enforces it even with --nogpgcheck. We've already installed
# all required libraries manually above so the binary dependencies are satisfied.
rpm -ivh --nodeps /tmp/oracle-xe-21c.rpm
rm -f /tmp/oracle-xe-21c.rpm

echo "==> Pre-writing Oracle XE sysconfig (ports only — password set at first boot)..."
# Variable names must match what /etc/init.d/oracle-xe-21c reads
# (CHARSET / LISTENER_PORT / EM_EXPRESS_PORT) — the ORACLE_* names are ignored.
cat > /etc/sysconfig/oracle-xe-21c.conf <<'EOF'
CHARSET=AL32UTF8
LISTENER_PORT=1521
EM_EXPRESS_PORT=5500
EOF

# Enable the service so systemd starts it after user-data runs configure
systemctl enable oracle-xe-21c

echo "==> Oracle XE 21c installed (configure deferred to first boot)."

# =============================================================================
# Vault Enterprise
# =============================================================================

echo "==> Downloading Vault Enterprise ${VAULT_VERSION}..."
curl -fsSL -o /tmp/vault.zip \
  "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"

echo "==> Installing Vault binary..."
unzip -o /tmp/vault.zip -d /usr/local/bin/
chmod +x /usr/local/bin/vault
rm -f /tmp/vault.zip

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
# Do NOT enable or start vault — user-data writes the config first, then enables + starts it.

echo "==> Vault Enterprise ${VAULT_VERSION} installed."
