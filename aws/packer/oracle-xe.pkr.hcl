# Copyright IBM Corp. 2017, 2026
#
# Packer build definition for Oracle XE 21c + Vault Enterprise AMI.
# Builds on Amazon Linux 2023 (x86_64).
#
# Oracle no longer publishes free Oracle Linux AMIs to AWS. Amazon Linux 2023
# is RHEL-compatible and fully supports Oracle XE 21c RPM installation via
# manual preinstall dependencies (no oracle-database-preinstall package needed).
#
# Usage:
#   packer init .
#   packer build -var 'aws_region=us-east-1' oracle-xe.pkr.hcl
#
# The resulting AMI ID is written to manifest.json and should be set
# as the ami_id variable in the Terraform configuration.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.0"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region to build the AMI in"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the Packer build instance. Needs 4GB+ RAM for XE configure."
  type        = string
  default     = "t3.xlarge"
}

variable "ami_name_prefix" {
  description = "Prefix for the AMI name. A timestamp is appended automatically."
  type        = string
  default     = "oracle-xe-21c-vault"
}

# =============================================================================
# Data source — latest Amazon Linux 2023 AMI
# Resolved via AWS SSM parameter — always returns the current latest AL2023 AMI
# for the given region without any owner ID or name glob that can break.
# =============================================================================

data "amazon-parameterstore" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  region = var.aws_region
}

# =============================================================================
# Build
# =============================================================================

source "amazon-ebs" "oracle_xe" {
  region        = var.aws_region
  instance_type = var.instance_type
  source_ami    = data.amazon-parameterstore.al2023.value

  ssh_username = "ec2-user"

  # AMI name includes a timestamp to allow multiple builds
  ami_name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "Oracle Database XE 21c + Vault Enterprise on Amazon Linux 2023 - Vault Oracle plugin testing"

  # Root volume — Oracle XE needs ~15GB minimum
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name      = "${var.ami_name_prefix}"
    OracleXE  = "21c"
    BaseOS    = "AmazonLinux2023"
    ManagedBy = "Packer"
    Purpose   = "vault-oracle-plugin-testing"
  }
}

build {
  name    = "oracle-xe-21c"
  sources = ["source.amazon-ebs.oracle_xe"]

  # Step 1: Install Oracle XE 21c + Vault Enterprise binary + systemd unit
  provisioner "shell" {
    script          = "${path.root}/scripts/install_oracle.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    # Oracle XE RPM install + Vault binary download — allow up to 30 minutes
    timeout         = "30m"
  }

  # Step 2: Clean up before snapshot
  provisioner "shell" {
    script          = "${path.root}/scripts/cleanup.sh"
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # Write AMI ID to manifest.json so Terraform can consume it
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
