# Copyright IBM Corp. 2017, 2026

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI used for both instances. Must be an Amazon Linux 2023 (x86_64) based image; default is the approved private hc-base AL2023 image."
  type        = string
  default     = "ami-04ee983f7bb25093b"
}

variable "vault_instance_type" {
  description = "EC2 instance type for the Vault host."
  type        = string
  default     = "t3.small"
}

variable "oracle_instance_type" {
  description = "EC2 instance type for the Oracle host. Oracle XE requires at least 2GB RAM; t3.medium (4GB) is recommended."
  type        = string
  default     = "t3.medium"
}

variable "vault_version" {
  description = "Vault Enterprise version installed on the Vault host (URL form, e.g. 2.0.4+ent)."
  type        = string
  default     = "2.0.4+ent"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access to both instances."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to the private key file matching key_pair_name (chmod 600). Used by Terraform provisioners."
  type        = string
}

variable "allowed_cidr" {
  description = "CIDR block allowed to reach SSH (22) and Vault (8200/8201). Restrict to your IP for security (e.g. '1.2.3.4/32')."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vault_license" {
  description = "Vault Enterprise license string"
  type        = string
  sensitive   = true
}

variable "oracle_password" {
  description = "Oracle SYS/SYSTEM password (set on first boot)"
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
