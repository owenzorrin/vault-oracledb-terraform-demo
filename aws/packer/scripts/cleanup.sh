#!/bin/bash
# Copyright IBM Corp. 2017, 2026
#
# Cleans up the Packer build instance before AMI snapshot.
# Removes caches, temp files, and cloud-init state so the AMI
# boots cleanly on new EC2 instances.
#
# NOTE: Do NOT rm -rf /tmp/* here — Packer uploads and executes scripts
# from a temp path under /tmp. Deleting /tmp/* mid-run kills the script.
# Instead we only remove known Oracle/install artifacts by name.

set -euo pipefail

echo "==> Cleaning DNF cache..."
dnf clean all
rm -rf /var/cache/dnf

echo "==> Removing known temp install artifacts..."
rm -f /tmp/oracle-xe-21c.rpm /tmp/vault.zip /tmp/instantclient.zip

echo "==> Clearing log files..."
find /var/log -type f -exec truncate -s 0 {} \;

echo "==> Resetting cloud-init so it reruns on new instances..."
cloud-init clean --logs

echo "==> Removing SSH host keys (regenerated on first boot)..."
rm -f /etc/ssh/ssh_host_*

echo "==> Cleanup complete."
