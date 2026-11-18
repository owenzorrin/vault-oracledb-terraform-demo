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
# These are uploaded to EC2 via file provisioners in Stage 1.
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
# Networking — VPC, subnet, IGW, route table, security group
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "vault-oracle-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "vault-oracle-public-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "vault-oracle-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "vault-oracle-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "vault_oracle" {
  name        = "vault-oracle-sg"
  description = "Allow SSH, Vault API and Oracle listener access"
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

  tags = { Name = "vault-oracle-sg" }
}

# =============================================================================
# Elastic IP — stable public address for Vault provider + Vault config api_addr
# =============================================================================

resource "aws_eip" "vault" {
  domain = "vpc"

  tags = { Name = "vault-oracle-eip" }
}

resource "aws_eip_association" "vault" {
  instance_id   = aws_instance.vault_oracle.id
  allocation_id = aws_eip.vault.id

  depends_on = [aws_internet_gateway.igw]
}

# =============================================================================
# EC2 Instance — Oracle XE 21c + Vault Enterprise (both native, no Docker)
# user-data:
#   - runs oracle-xe-21c configure (sets SYS/SYSTEM password, creates XEPDB1)
#   - starts oracle-xe-21c service
#   - writes Vault config + license to /etc/vault.d/
#   - enables and starts the vault systemd service
# =============================================================================

resource "aws_instance" "vault_oracle" {
  # The instance needs an internet route at first boot (user-data installs
  # packages). Nothing else references the route table, so a targeted apply
  # (-target=terraform_data.vault_init) would otherwise skip it.
  depends_on = [aws_route_table_association.public]

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.vault_oracle.id]
  key_name               = var.key_pair_name

  # Root volume — 30GB (matches Packer AMI root volume)
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # Separate EBS for Raft storage + init.json — persists across instance recreation
  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = 10
    volume_type           = "gp3"
    delete_on_termination = false
  }

  # user-data: configures Oracle XE password, starts XE + Vault on first boot.
  # Vault config is rendered here with the Elastic IP so api_addr is correct.
  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    oracle_password = var.oracle_password
    vault_license   = var.vault_license
    vault_config = templatefile("${path.module}/config/config.hcl.tpl", {
      vault_api_addr = aws_eip.vault.public_ip
    })
  }))

  tags = { Name = "vault-oracle-test" }
}

# =============================================================================
# Stage 1: Upload Oracle Instant Client + Vault plugin, bootstrap Oracle users
# =============================================================================

# Wait for cloud-init to finish and fix directory ownership for uploads
resource "terraform_data" "bootstrap" {
  depends_on = [aws_eip_association.vault]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for cloud-init / user-data to complete...'",
      "until [ -f /var/lib/cloud/instance/boot-finished ]; do sleep 5; done",
      "echo 'cloud-init finished.'",
      # Allow ec2-user to write into the Vault artifact directories
      "sudo chown -R ec2-user:ec2-user /vault/plugin /vault/client",
    ]
  }
}

# Upload Oracle Instant Client
resource "terraform_data" "upload_oracle_client" {
  depends_on = [
    terraform_data.oracle_client,
    terraform_data.bootstrap,
  ]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  # The file provisioner cannot copy the symlinks inside instantclient_*
  # (libclntsh.so -> libclntsh.so.19.1, etc.) and fails part-way. Stream a tar
  # archive over SSH instead, which preserves symlinks.
  provisioner "local-exec" {
    command = <<-EOT
      COPYFILE_DISABLE=1 tar czf - -C ${path.module}/client . | \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i ${var.ssh_private_key_path} \
            ec2-user@${aws_eip.vault.public_ip} \
            "tar xzf - -C /vault/client"
    EOT
  }

  # Restore vault ownership after upload
  provisioner "remote-exec" {
    inline = ["sudo chown -R vault:vault /vault/client"]
  }
}

# Upload Vault Oracle plugin
resource "terraform_data" "upload_vault_plugin" {
  depends_on = [
    terraform_data.vault_plugin,
    terraform_data.bootstrap,
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

  # Restore vault ownership after upload; the file provisioner drops the
  # execute bit, so restore it on the plugin binary.
  provisioner "remote-exec" {
    inline = [
      "sudo chown -R vault:vault /vault/plugin",
      "sudo find /vault/plugin -type f -name 'vault-plugin-*' -exec chmod 755 {} +",
    ]
  }
}

# Upload SQL scripts
resource "terraform_data" "upload_scripts" {
  depends_on = [terraform_data.bootstrap]

  connection {
    type        = "ssh"
    host        = aws_eip.vault.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    source      = "${path.module}/scripts/"
    destination = "/tmp/"
  }
}

# Oracle user setup — mirrors terraform_data.oracle_users from original
resource "terraform_data" "oracle_users" {
  depends_on = [
    terraform_data.upload_scripts,
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
      "echo 'Waiting for Oracle XE to be active...'",
      "until sudo systemctl is-active oracle-xe-21c >/dev/null 2>&1; do echo '  Oracle not active yet, retrying in 10s...'; sleep 10; done",
      "echo 'Waiting for XEPDB1 to become available...'",
      "ORACLE_HOME=$(sudo cat /etc/oratab | grep '^XE' | cut -d: -f2)",
      # ORACLE_SID must be set for bequeath (local) sqlplus connections;
      # without it every attempt fails with ORA-12162.
      "export ORACLE_SID=XE",
      "for i in $(seq 1 20); do echo 'SELECT 1 FROM DUAL;' | sudo -u oracle ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID $ORACLE_HOME/bin/sqlplus -s / as sysdba 2>&1 | grep -qE '^[[:space:]]*1$' && break || { echo \"  Attempt $i: DB not ready, retrying in 15s...\"; sleep 15; }; done",
      "echo 'Creating Oracle users...'",
      "OK=0; for i in 1 2 3 4 5; do sudo -u oracle bash -c \"export ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID; $ORACLE_HOME/bin/sqlplus sys/${var.oracle_password} as sysdba @/tmp/create_users.sql\" ; RESULT=$(sudo -u oracle bash -c \"export ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID; $ORACLE_HOME/bin/sqlplus -s sys/${var.oracle_password} as sysdba @/tmp/verify_users.sql\"); if echo \"$RESULT\" | grep -q 'VAULT'; then echo 'Oracle users created successfully.'; OK=1; break; fi; echo \"Attempt $i failed, retrying in 15s...\"; sleep 15; done; [ $OK -eq 1 ] || { echo 'ERROR: Oracle users were not created'; exit 1; }",
    ]
  }
}

# =============================================================================
# Stage 1: Vault init + unseal
# Vault is already running as a systemd service (started by user-data).
# We call vault CLI directly on the instance — no Docker exec.
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
      # If Vault failed to start in user-data (e.g. transient license issue),
      # restart it now that all artifacts are in place.
      "if ! sudo systemctl is-active vault >/dev/null 2>&1; then echo 'Vault not running, attempting restart...'; sudo systemctl restart vault; sleep 3; fi",

      "echo 'Waiting for Vault to be ready...'",
      "until VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Seal Type'; do echo '  Vault not ready yet, retrying in 3s...'; sleep 3; done",

      "echo 'Initializing Vault...'",
      "VAULT_ADDR=http://127.0.0.1:8200 vault operator init -key-shares=1 -key-threshold=1 -format=json | sudo tee /opt/vault/data/init.json > /dev/null",

      "echo 'Extracting unseal key and root token...'",
      "UNSEAL=$(sudo cat /opt/vault/data/init.json | jq -r '.unseal_keys_b64[0]' | tr -d '[:space:]')",
      "TOKEN=$(sudo cat /opt/vault/data/init.json | jq -r '.root_token' | tr -d '[:space:]')",

      "echo 'Unsealing Vault...'",
      "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal \"$UNSEAL\"",

      "echo 'Persisting credentials to EBS data volume...'",
      "printf '%s' \"$TOKEN\" | sudo tee /opt/vault/data/.vault-token > /dev/null",
      "printf '%s' \"$UNSEAL\" | sudo tee /opt/vault/data/.vault-unseal-key > /dev/null",

      "echo 'Vault initialized and unsealed successfully.'",
    ]
  }

  # Pull root token and unseal key back to the local machine
  provisioner "local-exec" {
    command = <<-EOT
      echo "Fetching Vault root token from EC2..."
      ssh -o StrictHostKeyChecking=no \
          -i ${var.ssh_private_key_path} \
          ec2-user@${aws_eip.vault.public_ip} \
          "sudo cat /opt/vault/data/.vault-token" | tr -d '[:space:]' > ${path.module}/.vault-token
      ssh -o StrictHostKeyChecking=no \
          -i ${var.ssh_private_key_path} \
          ec2-user@${aws_eip.vault.public_ip} \
          "sudo cat /opt/vault/data/.vault-unseal-key" | tr -d '[:space:]' > ${path.module}/.vault-unseal-key
      echo "Credentials saved locally."
    EOT
  }
}

# =============================================================================
# Stage 2: Ensure Vault is unsealed + Register Plugin
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
      "until VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Seal Type'; do echo '  Vault not ready, retrying in 3s...'; sleep 3; done",
      "if VAULT_ADDR=http://127.0.0.1:8200 vault status 2>&1 | grep -q 'Sealed.*true'; then echo 'Vault is sealed, unsealing...'; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal \"$UNSEAL_KEY\"; else echo 'Vault is already unsealed.'; fi",

      "echo 'Registering Oracle database plugin...'",
      "VAULT_TOKEN=$(sudo cat /opt/vault/data/.vault-token | tr -d '[:space:]') VAULT_ADDR=http://127.0.0.1:8200 vault plugin register -version=v0.13.0+ent -command=vault-plugin-database-oracle -args='-tls-skip-verify' -env='LD_LIBRARY_PATH=/vault/client/instantclient_19_28' database vault-plugin-database-oracle || { echo 'ERROR: plugin registration failed'; exit 1; }",

      "echo 'Plugin registered successfully.'",
    ]
  }
}

# =============================================================================
# Stage 2: Vault Database Secrets Engine Configuration
# (identical to original main.tf)
# =============================================================================

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
    plugin_name             = "vault-plugin-database-oracle"
    connection_url          = "{{username}}/{{password}}@localhost:1521/XEPDB1"
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
