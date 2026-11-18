# Copyright IBM Corp. 2017, 2026

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. Oracle XE requires at least 2GB RAM; t3.medium (4GB) is recommended."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID of the custom Oracle XE 21c image built by Packer. See packer/manifest.json after running 'packer build'."
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access to the instance."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to the private key file matching key_pair_name. Used by Terraform remote-exec provisioners."
  type        = string
}

variable "allowed_cidr" {
  description = "CIDR block allowed to reach port 22 (SSH) and 8200 (Vault). Restrict to your IP for security (e.g. '1.2.3.4/32'). Defaults to open for convenience during testing."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vault_license" {
  description = "Vault Enterprise license string"
  type        = string
  sensitive   = true
}

variable "oracle_password" {
  description = "Oracle SYS/SYSTEM password (set on EC2 boot)"
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
