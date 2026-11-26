# Copyright IBM Corp. 2017, 2026

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

locals {
  create_users_sql = templatefile("${path.module}/scripts/create_users.sql.tpl", {
    vault_db_username = var.vault_db_username
    vault_db_password = var.vault_db_password
  })
  verify_users_sql = templatefile("${path.module}/scripts/verify_users.sql.tpl", {
    vault_db_username = var.vault_db_username
  })
}

# =============================================================================
# Providers
# =============================================================================

provider "aws" {
  region = var.aws_region
}

provider "vault" {
  address          = "http://${aws_eip.vault.public_ip}:8200"
  token            = file("${path.module}/.vault-token")
  skip_child_token = true
}

# =============================================================================
# Download Oracle Instant Client + Vault Oracle Plugin locally
# These are uploaded to the Vault host in Stage 1.
# =============================================================================

resource "terraform_data" "oracle_client" {
  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/client
      if [ ! -d "${path.module}/client/instantclient_19_28" ]; then
        echo "Downloading Oracle Instant Client..."
        curl -o /tmp/instantclient.zip \
          https://download.oracle.com/otn_software/linux/instantclient/1928000/instantclient-basic-linux.x64-19.28.0.0.0dbru.zip
        unzip -o /tmp/instantclient.zip -d ${path.module}/client/
        rm /tmp/instantclient.zip
      else
        echo "Oracle Instant Client already exists, skipping download."
      fi
    EOT
  }
}

resource "terraform_data" "vault_plugin" {
  provisioner "local-exec" {
    command = <<-EOT
      ARTIFACT_DIR="${path.module}/plugin/vault-plugin-database-oracle_0.13.0+ent_linux_amd64"
      mkdir -p "$ARTIFACT_DIR"
      if [ ! -f "$ARTIFACT_DIR/vault-plugin-database-oracle" ]; then
        echo "Downloading Vault Oracle Database Plugin..."
        curl -o /tmp/vault-oracle-plugin.zip \
          https://releases.hashicorp.com/vault-plugin-database-oracle/0.13.0+ent/vault-plugin-database-oracle_0.13.0+ent_linux_amd64.zip
        unzip -o /tmp/vault-oracle-plugin.zip -d "$ARTIFACT_DIR"
        rm /tmp/vault-oracle-plugin.zip
      else
        echo "Vault Oracle plugin already exists, skipping download."
      fi
    EOT
  }
}

# =============================================================================
# Networking — VPC, subnet, IGW, route table
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "vault-oracle-2i-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "vault-oracle-2i-public-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "vault-oracle-2i-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "vault-oracle-2i-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# Security groups
#   vault  : SSH + Vault API/cluster from allowed_cidr
#   oracle : SSH from allowed_cidr, listener 1521 ONLY from the Vault SG
# =============================================================================

resource "aws_security_group" "vault" {
  name        = "vault-2i-vault-sg"
  description = "Vault host: SSH and Vault API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "Vault API"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "Vault cluster"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vault-2i-vault-sg" }
}

resource "aws_security_group" "oracle" {
  name        = "vault-2i-oracle-sg"
  description = "Oracle host: SSH and listener from the Vault host only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description     = "Oracle listener from Vault host"
    from_port       = 1521
    to_port         = 1521
    protocol        = "tcp"
    security_groups = [aws_security_group.vault.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vault-2i-oracle-sg" }
}

# =============================================================================
# Elastic IP for the Vault host (stable api_addr + Vault provider address)
# =============================================================================

resource "aws_eip" "vault" {
  domain = "vpc"

  tags = { Name = "vault-oracle-2i-eip" }
}

resource "aws_eip_association" "vault" {
  instance_id   = aws_instance.vault.id
  allocation_id = aws_eip.vault.id

  depends_on = [aws_internet_gateway.igw]
}

# =============================================================================
# EC2 #1 — Vault Enterprise
# =============================================================================

resource "aws_instance" "vault" {
  # Both hosts need an internet route at first boot (user-data downloads
  # packages). A targeted apply would otherwise skip the route table.
  depends_on = [aws_route_table_association.public]

  ami                    = var.ami_id
  instance_type          = var.vault_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.vault.id]
  key_name               = var.key_pair_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Raft storage + init.json live on the root volume under /opt/vault/data.
  # Deleted with the instance so teardown leaves no orphan volumes.

  user_data = base64encode(templatefile("${path.module}/userdata_vault.sh.tpl", {
    vault_version = var.vault_version
    vault_license = var.vault_license
    vault_config = templatefile("${path.module}/config/config.hcl.tpl", {
      vault_api_addr = aws_eip.vault.public_ip
    })
  }))

  tags = { Name = "vault-2i-vault" }
}

# =============================================================================
# EC2 #2 — Oracle Database XE 21c
# =============================================================================

resource "aws_instance" "oracle" {
  depends_on = [aws_route_table_association.public]

  ami                    = var.ami_id
  instance_type          = var.oracle_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.oracle.id]
  key_name               = var.key_pair_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/userdata_oracle.sh.tpl", {
    oracle_password = var.oracle_password
  }))

  tags = { Name = "vault-2i-oracle" }
}

# =============================================================================
# Stage 1a: Vault host — wait for user-data, upload Instant Client + plugin
# =============================================================================

resource "terraform_data" "bootstrap_vault" {
  depends_on = [aws_eip_association.vault]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init / user-data on the Vault host...'",
      "for i in $(seq 1 480); do [ -f /var/lib/cloud/instance/boot-finished ] && break; [ $i -eq 480 ] && { echo 'ERROR: cloud-init did not finish within 40 minutes; see /var/log/cloud-init-output.log'; exit 1; }; sleep 5; done",
      "test -x /usr/local/bin/vault || { echo 'ERROR: vault binary missing — see /var/log/cloud-init-output.log'; exit 1; }",
      "/usr/local/bin/vault version",
      "sudo chown -R ec2-user:ec2-user /vault/plugin /vault/client",
    ]
  }
}

resource "terraform_data" "upload_oracle_client" {
  depends_on = [
    terraform_data.oracle_client,
    terraform_data.bootstrap_vault,
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  # Make re-runs idempotent: a previous run leaves the files owned by vault,
  # which ec2-user cannot overwrite.
  provisioner "remote-exec" {
    inline = ["sudo chown -R ec2-user:ec2-user /vault/client"]
  }

  # The file provisioner cannot copy the symlinks inside instantclient_*;
  # stream a tar archive over SSH instead.
  provisioner "local-exec" {
    command = <<-EOT
      COPYFILE_DISABLE=1 tar czf - -C ${path.module}/client . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ${var.ssh_private_key_path} \
            ec2-user@${aws_eip.vault.public_ip} \
            "tar xzf - -C /vault/client"
    EOT
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chown -R vault:vault /vault/client",
      # Fail now, not later at plugin runtime, if a shared library is missing.
      "echo 'Checking Instant Client shared libraries...'",
      # LD_LIBRARY_PATH mirrors what the plugin gets at registration; without it
      # ldd cannot see Instant Client's own sibling libraries.
      "if LD_LIBRARY_PATH=/vault/client/instantclient_19_28 ldd /vault/client/instantclient_19_28/libclntsh.so | grep 'not found'; then echo 'ERROR: unresolved Instant Client libraries'; exit 1; fi",
      "echo 'Instant Client libraries OK.'",
    ]
  }
}

resource "terraform_data" "upload_vault_plugin" {
  depends_on = [
    terraform_data.vault_plugin,
    terraform_data.bootstrap_vault,
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    source      = "${path.module}/plugin/"
    destination = "/vault/plugin"
  }

  # The file provisioner drops the execute bit; restore it.
  provisioner "remote-exec" {
    inline = [
      "sudo chown -R vault:vault /vault/plugin",
      "sudo find /vault/plugin -type f -name 'vault-plugin-*' -exec chmod 755 {} +",
    ]
  }
}

# =============================================================================
# Stage 1b: Oracle host — wait for XE, create users
# =============================================================================

resource "terraform_data" "bootstrap_oracle" {
  depends_on = [aws_instance.oracle]

  connection {
    type        = "ssh"
    host        = aws_instance.oracle.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for Oracle XE install + configure (user-data, ~15-20 min)...'",
      "for i in $(seq 1 240); do [ -f /var/lib/oracle-xe.ready ] && break; if [ -f /var/lib/oracle-xe.failed ]; then echo \"ERROR: Oracle user-data failed: $(cat /var/lib/oracle-xe.failed)\"; echo 'See /var/log/cloud-init-output.log'; exit 1; fi; [ $i -eq 240 ] && { echo 'ERROR: Oracle XE was not ready within 40 minutes; see /var/log/cloud-init-output.log'; exit 1; }; sleep 10; done",
      "echo 'Oracle XE is ready.'",
    ]
  }
}

resource "terraform_data" "upload_scripts" {
  triggers_replace = [sha256(local.create_users_sql), sha256(local.verify_users_sql)]

  depends_on = [terraform_data.bootstrap_oracle]

  connection {
    type        = "ssh"
    host        = aws_instance.oracle.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  # Rendered with the tfvars passwords; removed from /tmp after the users exist.
  provisioner "file" {
    content     = local.create_users_sql
    destination = "/tmp/create_users.sql"
  }

  provisioner "file" {
    content     = local.verify_users_sql
    destination = "/tmp/verify_users.sql"
  }
}

resource "terraform_data" "oracle_users" {
  # Re-create the users when the rendered SQL (e.g. vault_db_password) changes.
  triggers_replace = [terraform_data.upload_scripts.id]

  depends_on = [terraform_data.upload_scripts]

  connection {
    type        = "ssh"
    host        = aws_instance.oracle.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for XEPDB1 to become available...'",
      "ORACLE_HOME=$(sudo cat /etc/oratab | grep '^XE' | cut -d: -f2)",
      # ORACLE_SID must be set for bequeath (local) sqlplus connections.
      "export ORACLE_SID=XE",
      "for i in $(seq 1 20); do echo 'SELECT 1 FROM DUAL;' | sudo -u oracle ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID $ORACLE_HOME/bin/sqlplus -s / as sysdba 2>&1 | grep -qE '^[[:space:]]*1$' && break; [ $i -eq 20 ] && { echo 'ERROR: database did not answer within 5 minutes'; exit 1; }; echo \"  Attempt $i: DB not ready, retrying in 15s...\"; sleep 15; done",
      "echo 'Creating Oracle users...'",
      # OS authentication (/ as sysdba) as the oracle user: no SYS password on the
      # command line, so this provisioner's output is not suppressed as sensitive.
      "SQLPLUS=\"sudo -u oracle ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID $ORACLE_HOME/bin/sqlplus -s / as sysdba\"",
      "OK=0; for i in 1 2 3 4 5; do $SQLPLUS < /tmp/create_users.sql; if $SQLPLUS < /tmp/verify_users.sql | grep -q 'USER_OK:'; then echo 'Oracle users created successfully.'; OK=1; break; fi; echo \"Attempt $i failed, retrying in 15s...\"; sleep 15; done",
      "[ $OK -eq 1 ] || { echo 'ERROR: Oracle users were not created'; exit 1; }",
      "rm -f /tmp/create_users.sql",
      "echo 'Listener status:'",
      "sudo -u oracle bash -c \"export ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID; $ORACLE_HOME/bin/lsnrctl status\" | grep -iE 'XEPDB1|HOST=|PORT=' || true",
    ]
  }
}

# =============================================================================
# Stage 1c: Vault init + unseal (on the Vault host)
# =============================================================================

resource "terraform_data" "vault_init" {
  depends_on = [
    terraform_data.upload_oracle_client,
    terraform_data.upload_vault_plugin,
    aws_eip_association.vault,
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "if ! sudo systemctl is-active vault >/dev/null 2>&1; then echo 'Vault not running, attempting restart...'; sudo systemctl restart vault; sleep 3; fi",

      "echo 'Waiting for Vault to be ready...'",
      "for i in $(seq 1 100); do VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Seal Type' && break; [ $i -eq 100 ] && { echo 'ERROR: Vault did not respond within 5 minutes'; exit 1; }; echo '  Vault not ready yet, retrying in 3s...'; sleep 3; done",

      "if VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | jq -e '.initialized' >/dev/null; then echo 'Vault is already initialized, reusing /opt/vault/data/init.json.'; sudo test -s /opt/vault/data/init.json || { echo 'ERROR: Vault is initialized but /opt/vault/data/init.json is missing'; exit 1; }; else echo 'Initializing Vault...'; VAULT_ADDR=http://127.0.0.1:8200 vault operator init -key-shares=1 -key-threshold=1 -format=json | sudo tee /opt/vault/data/init.json > /dev/null; fi",

      "echo 'Extracting unseal key and root token...'",
      "UNSEAL=$(sudo cat /opt/vault/data/init.json | jq -r '.unseal_keys_b64[0]' | tr -d '[:space:]')",
      "TOKEN=$(sudo cat /opt/vault/data/init.json | jq -r '.root_token' | tr -d '[:space:]')",

      "if VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | jq -e '.sealed' >/dev/null; then echo 'Unsealing Vault...'; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal \"$UNSEAL\"; else echo 'Vault is already unsealed.'; fi",

      "echo 'Persisting credentials...'",
      "printf '%s' \"$TOKEN\" | sudo tee /opt/vault/data/.vault-token > /dev/null",
      "printf '%s' \"$UNSEAL\" | sudo tee /opt/vault/data/.vault-unseal-key > /dev/null",

      "echo 'Vault initialized and unsealed successfully.'",
    ]
  }

  # Pull root token and unseal key back to the local machine
  provisioner "local-exec" {
    command = <<-EOT
      echo "Fetching Vault root token from EC2..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${var.ssh_private_key_path} \
          ec2-user@${aws_eip.vault.public_ip} \
          "sudo cat /opt/vault/data/.vault-token" | tr -d '[:space:]' > ${path.module}/.vault-token
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i ${var.ssh_private_key_path} \
          ec2-user@${aws_eip.vault.public_ip} \
          "sudo cat /opt/vault/data/.vault-unseal-key" | tr -d '[:space:]' > ${path.module}/.vault-unseal-key
      echo "Credentials saved locally."
    EOT
  }
}

# =============================================================================
# Stage 2: Register plugin (on the Vault host), then configure the engine
# =============================================================================

resource "terraform_data" "vault_plugin_register" {
  depends_on = [terraform_data.vault_init]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Ensuring Vault is unsealed...'",
      "UNSEAL_KEY=$(sudo cat /opt/vault/data/.vault-unseal-key | tr -d '[:space:]')",
      "for i in $(seq 1 100); do VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Seal Type' && break; [ $i -eq 100 ] && { echo 'ERROR: Vault did not respond within 5 minutes'; exit 1; }; echo '  Vault not ready, retrying in 3s...'; sleep 3; done",
      "if VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Sealed.*true'; then echo 'Vault is sealed, unsealing...'; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal \"$UNSEAL_KEY\"; else echo 'Vault is already unsealed.'; fi",

      "echo 'Registering Oracle database plugin...'",
      "VAULT_TOKEN=$(sudo cat /opt/vault/data/.vault-token | tr -d '[:space:]') VAULT_ADDR=http://127.0.0.1:8200 vault plugin register -version=v0.13.0+ent -command=vault-plugin-database-oracle -args='-tls-skip-verify' -env='LD_LIBRARY_PATH=/vault/client/instantclient_19_28' database vault-plugin-database-oracle || { echo 'ERROR: plugin registration failed'; exit 1; }",

      "echo 'Plugin registered successfully.'",
    ]
  }
}

resource "vault_mount" "database" {
  depends_on = [terraform_data.vault_plugin_register]

  path = "database"
  type = "database"
}

resource "vault_generic_endpoint" "oracle_connection" {
  depends_on = [
    vault_mount.database,
    terraform_data.oracle_users,
  ]

  path                 = "database/config/my-oracle-database"
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    plugin_name = "vault-plugin-database-oracle"
    # Oracle runs on its own host now — connect to its private IP.
    connection_url          = "{{username}}/{{password}}@${aws_instance.oracle.private_ip}:1521/XEPDB1"
    username                = var.vault_db_username
    password                = var.vault_db_password
    allowed_roles           = ["my-role", "static-role"]
    max_connection_lifetime = "60s"
  })
}

resource "vault_database_secret_backend_role" "dynamic_role" {
  depends_on = [vault_generic_endpoint.oracle_connection]

  backend     = vault_mount.database.path
  name        = "my-role"
  db_name     = "my-oracle-database"
  default_ttl = 3600
  max_ttl     = 86400

  creation_statements = [
    "CREATE USER {{username}} IDENTIFIED BY \"{{password}}\"",
    "GRANT CONNECT TO {{username}}",
    "GRANT CREATE SESSION TO {{username}}",
  ]
}

resource "vault_database_secret_backend_static_role" "static_role" {
  depends_on = [vault_generic_endpoint.oracle_connection]

  backend         = vault_mount.database.path
  name            = "static-role"
  db_name         = "my-oracle-database"
  username        = "staticvault"
  rotation_period = 3600
}
