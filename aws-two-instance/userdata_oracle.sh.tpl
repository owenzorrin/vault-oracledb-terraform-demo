#!/bin/bash
# Copyright IBM Corp. 2017, 2026
#
# EC2 user-data for the ORACLE host (stock Amazon Linux 2023, no custom AMI).
#
# Installs every dependency Oracle XE 21c needs, installs the RPM, runs the
# RPM's own `configure` (creates XE + XEPDB1), and writes a marker file that
# Terraform waits on. Unlike the single-instance layout this script is strict:
# any failed step aborts it and writes /var/lib/oracle-xe.failed, so Terraform
# fails fast instead of hanging for 20 minutes.

set -euo pipefail

fail() {
  echo "ERROR: $1" >&2
  echo "$1" > /var/lib/oracle-xe.failed
  exit 1
}
trap 'fail "user-data aborted at line $LINENO"' ERR

# =============================================================================
# 1. Oracle XE preinstall dependencies
#    (AL2023 has no oracle-database-preinstall-21c package, so install the
#    equivalent libraries by hand.)
# =============================================================================
echo "==> Installing Oracle XE dependencies..."
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

# =============================================================================
# 2. Kernel parameters + oracle user limits
# =============================================================================
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
# 3. Oracle XE 21c RPM
# =============================================================================
echo "==> Downloading Oracle Database XE 21c RPM (2.2 GB)..."
# /tmp is a RAM-backed tmpfs on AL2023 and is too small for the 2.2 GB RPM;
# use /var/tmp, which lives on the root volume.
curl -fsSL --retry 5 --retry-delay 10 -o /var/tmp/oracle-xe-21c.rpm \
  https://download.oracle.com/otn-pub/otn_software/db-express/oracle-database-xe-21c-1.0-1.ol8.x86_64.rpm

echo "==> Installing Oracle Database XE 21c RPM..."
# --nodeps: the RPM declares a dependency on oracle-database-preinstall-21c,
# which does not exist on AL2023. The libraries are installed above.
rpm -ivh --nodeps /var/tmp/oracle-xe-21c.rpm
rm -f /var/tmp/oracle-xe-21c.rpm

# Variable names must match what /etc/init.d/oracle-xe-21c reads.
cat > /etc/sysconfig/oracle-xe-21c.conf <<'XECONF'
CHARSET=AL32UTF8
LISTENER_PORT=1521
EM_EXPRESS_PORT=5500
XECONF

# =============================================================================
# 4. Dependency verification (before the 13-minute configure)
# =============================================================================
echo "==> Verifying Oracle installation and shared libraries..."
rpm -q oracle-database-xe-21c || fail "oracle-database-xe-21c RPM is not installed"

ORACLE_HOME=/opt/oracle/product/21c/dbhomeXE
[ -x "$ORACLE_HOME/bin/oracle" ]  || fail "$ORACLE_HOME/bin/oracle missing"
[ -x "$ORACLE_HOME/bin/sqlplus" ] || fail "$ORACLE_HOME/bin/sqlplus missing"

for bin in oracle sqlplus lsnrctl dbca; do
  if LD_LIBRARY_PATH="$ORACLE_HOME/lib" ldd "$ORACLE_HOME/bin/$bin" 2>&1 | grep -q 'not found'; then
    LD_LIBRARY_PATH="$ORACLE_HOME/lib" ldd "$ORACLE_HOME/bin/$bin" 2>&1 | grep 'not found' >&2
    fail "unresolved shared libraries for $bin"
  fi
done
ldconfig -p | grep -q 'libcrypt.so.1' || fail "libcrypt.so.1 missing (libxcrypt-compat)"
ldconfig -p | grep -q 'libaio.so.1'   || fail "libaio.so.1 missing"
echo "==> All Oracle binaries resolve their shared libraries."

# =============================================================================
# 5. configure (creates XE + XEPDB1) and start
# =============================================================================
echo "==> Running Oracle XE configure..."
ORACLE_PASSWORD='${oracle_password}' /etc/init.d/oracle-xe-21c configure 2>&1

grep -q '^XE:' /etc/oratab || fail "no XE entry in /etc/oratab after configure"

echo "==> Starting oracle-xe-21c service..."
systemctl enable oracle-xe-21c
systemctl start oracle-xe-21c
systemctl is-active --quiet oracle-xe-21c || fail "oracle-xe-21c service is not active"

trap - ERR
touch /var/lib/oracle-xe.ready
echo "==> User-data complete: Oracle XE is ready."
