terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "vault_license" {
  description = "Vault Enterprise license string"
  type        = string
  sensitive   = true
}

variable "oracle_password" {
  description = "Oracle SYS password"
  type        = string
  default     = "rootpassword"
  sensitive   = true
}

variable "vault_db_username" {
  description = "Username Vault uses to connect to Oracle"
  type        = string
  default     = "vault"
}

variable "vault_db_password" {
  description = "Password for Vault's Oracle DB user"
  type        = string
  default     = "vaultpasswd"
  sensitive   = true
}

# =============================================================================
# Providers
# =============================================================================

provider "docker" {
  # Uses DOCKER_HOST env var or default socket
  # For Colima: export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
}

provider "vault" {
  address          = "http://localhost:8200"
  token            = file("${path.module}/.vault-token")
  skip_child_token = true
}

# =============================================================================
# Download Oracle Instant Client + Vault Oracle Plugin
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
      mkdir -p ${path.module}/plugin
      if [ ! -f "${path.module}/plugin/vault-plugin-database-oracle" ]; then
        echo "Downloading Vault Oracle Database Plugin..."
        curl -o /tmp/vault-oracle-plugin.zip \
          https://releases.hashicorp.com/vault-plugin-database-oracle/0.10.2/vault-plugin-database-oracle_0.10.2_linux_amd64.zip
        unzip -o /tmp/vault-oracle-plugin.zip -d ${path.module}/plugin/
        rm /tmp/vault-oracle-plugin.zip
      else
        echo "Vault Oracle plugin already exists, skipping download."
      fi
    EOT
  }
}

# =============================================================================
# Docker Network
# =============================================================================

resource "docker_network" "vault_oracle" {
  name = "vault-oracle-net"
}

# =============================================================================
# Oracle XE Container (gvenzl/oracle-xe - matches docker-compose.yaml)
# =============================================================================

resource "docker_image" "oracle" {
  name = "gvenzl/oracle-xe"
}

resource "docker_container" "oracle" {
  name  = "oracle-xe-test"
  image = docker_image.oracle.image_id

  networks_advanced {
    name = docker_network.vault_oracle.name
  }

  env = [
    "ORACLE_PASSWORD=${var.oracle_password}",
  ]
}

# =============================================================================
# Vault Enterprise Container (matches docker-compose.yaml)
# =============================================================================

resource "docker_image" "vault" {
  name = "owenzhang134/vault-linux-amd64-1.21.0-ent:latest"
}

resource "docker_container" "vault" {
  name  = "vault-test"
  image = docker_image.vault.image_id

  depends_on = [
    terraform_data.oracle_client,
    terraform_data.vault_plugin,
  ]

  networks_advanced {
    name = docker_network.vault_oracle.name
  }

  ports {
    internal = 8200
    external = 8200
  }

  env = [
    "VAULT_LICENSE=${var.vault_license}",
    "VAULT_ADDR=http://127.0.0.1:8200",
    "LD_LIBRARY_PATH=/vault/client/instantclient_19_28",
  ]

  capabilities {
    add = ["IPC_LOCK"]
  }

  # Prevent Docker provider from recreating the container due to
  # capability name normalization (IPC_LOCK vs CAP_IPC_LOCK)
  lifecycle {
    ignore_changes = [capabilities]
  }

  # Mount Vault config directory
  volumes {
    host_path      = abspath("${path.module}/config")
    container_path = "/vault/config"
  }

  # Mount plugin binary
  volumes {
    host_path      = abspath("${path.module}/plugin")
    container_path = "/vault/plugin"
  }

  # Mount Oracle Instant Client
  volumes {
    host_path      = abspath("${path.module}/client")
    container_path = "/vault/client"
  }

  # Mount data directory to /opt/vault/data (matches config.hcl raft storage path)
  volumes {
    host_path      = abspath("${path.module}/data")
    container_path = "/opt/vault/data"
  }

  command = ["vault", "server", "-config=/vault/config/config.hcl"]
}

# =============================================================================
# Stage 1: Vault Init + Unseal
#
# Saves init.json to the host-mounted data volume (/opt/vault/data/init.json)
# so it survives container recreation. Also saves unseal key locally.
# =============================================================================

resource "terraform_data" "vault_init" {
  depends_on = [docker_container.vault]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Vault to be ready..."
      until docker exec vault-test vault status 2>&1 | grep -q "Seal Type"; do
        echo "  Vault not ready yet, retrying in 3s..."
        sleep 3
      done

      echo "Initializing Vault..."
      docker exec vault-test sh -c \
        'vault operator init -key-shares=1 -key-threshold=1 -format=json > /opt/vault/data/init.json'

      echo "Extracting unseal key and root token..."
      UNSEAL=$(docker exec vault-test cat /opt/vault/data/init.json | jq -r '.unseal_keys_b64[0]' | tr -d '[:space:]')
      TOKEN=$(docker exec vault-test cat /opt/vault/data/init.json | jq -r '.root_token' | tr -d '[:space:]')

      echo "Unsealing Vault..."
      docker exec vault-test vault operator unseal "$UNSEAL"

      echo "Writing root token and unseal key for Terraform..."
      printf '%s' "$TOKEN" > ${path.module}/.vault-token
      printf '%s' "$UNSEAL" > ${path.module}/.vault-unseal-key

      echo "Vault initialized and unsealed successfully."
    EOT
  }
}

# =============================================================================
# Stage 1: Oracle User Setup
# =============================================================================

resource "terraform_data" "oracle_users" {
  depends_on = [docker_container.oracle]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Oracle XEPDB1 to be ready..."
      until docker exec oracle-xe-test bash -c \
        "echo 'alter session set container=XEPDB1; SELECT 1 FROM DUAL; exit;' | sqlplus -s sys/rootpassword as sysdba" 2>/dev/null | grep -q "1"; do
        echo "  Oracle XEPDB1 not ready yet, retrying in 15s..."
        sleep 15
      done
      echo "Oracle XEPDB1 is ready."

      echo "Creating Oracle users..."
      docker exec oracle-xe-test bash -c "printf '%s\n' \
        'alter session set container=XEPDB1;' \
        'CREATE USER vault IDENTIFIED BY vaultpasswd;' \
        'ALTER USER vault DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;' \
        'GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO vault;' \
        'CREATE USER staticvault IDENTIFIED BY test;' \
        'ALTER USER staticvault DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;' \
        'GRANT CREATE SESSION, RESOURCE, UNLIMITED TABLESPACE, DBA TO staticvault;' \
        'exit;' \
        | sqlplus sys/rootpassword as sysdba"

      echo "Verifying users were created..."
      RESULT=$(docker exec oracle-xe-test bash -c \
        "echo 'alter session set container=XEPDB1; SELECT username FROM all_users WHERE username = '\''VAULT'\''; exit;' | sqlplus -s sys/rootpassword as sysdba")
      if echo "$RESULT" | grep -q "VAULT"; then
        echo "Oracle users created successfully."
      else
        echo "ERROR: Oracle users were NOT created. Output:"
        echo "$RESULT"
        exit 1
      fi
    EOT
  }
}

# =============================================================================
# Stage 2: Ensure Vault is unsealed + Register Plugin
#
# If the container was recreated between stages, Vault will be sealed.
# This step unseals it first, then registers the plugin.
# =============================================================================

resource "terraform_data" "vault_plugin_register" {
  depends_on = [terraform_data.vault_init]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Ensuring Vault is unsealed..."
      UNSEAL_KEY=$(cat ${path.module}/.vault-unseal-key | tr -d '[:space:]')

      # Wait for Vault container to be responsive
      until docker exec vault-test vault status 2>&1 | grep -q "Seal Type"; do
        echo "  Vault not ready yet, retrying in 3s..."
        sleep 3
      done

      # Check if sealed and unseal if needed
      if docker exec vault-test vault status 2>&1 | grep -q "Sealed.*true"; then
        echo "Vault is sealed, unsealing..."
        docker exec vault-test vault operator unseal "$UNSEAL_KEY"
      else
        echo "Vault is already unsealed."
      fi

      export VAULT_TOKEN=$(cat ${path.module}/.vault-token | tr -d '[:space:]')

      echo "Registering Oracle database plugin..."
      SHASUM=$(docker exec vault-test sha256sum /vault/plugin/vault-plugin-database-oracle | awk '{print $1}')

      docker exec \
        -e VAULT_ADDR=http://127.0.0.1:8200 \
        -e "VAULT_TOKEN=$VAULT_TOKEN" \
        vault-test \
        vault plugin register \
          -sha256="$SHASUM" \
          -version=v0.10.2 \
          -command=vault-plugin-database-oracle \
          -args="-tls-skip-verify" \
          -env="LD_LIBRARY_PATH=/vault/client/instantclient_19_28" \
          database vault-plugin-database-oracle

      echo "Plugin registered successfully."
    EOT
  }
}

# =============================================================================
# Stage 2: Vault Database Secrets Engine Configuration
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
    plugin_name              = "vault-plugin-database-oracle"
    connection_url           = "{{username}}/{{password}}@oracle-xe-test:1521/XEPDB1"
    username                 = var.vault_db_username
    password                 = var.vault_db_password
    allowed_roles            = ["my-role", "static-role"]
    max_connection_lifetime  = "60s"
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

# =============================================================================
# Outputs
# =============================================================================

output "vault_address" {
  value = "http://localhost:8200"
}

output "vault_init_file" {
  value = "Init credentials stored at data/init.json and inside container at /opt/vault/data/init.json"
}

output "test_dynamic_creds" {
  value = "vault read database/creds/my-role"
}

output "test_static_creds" {
  value = "vault read database/static-creds/static-role"
}
