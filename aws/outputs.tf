# Copyright IBM Corp. 2017, 2026

output "vault_address" {
  description = "Vault API address"
  value       = "http://${aws_eip.vault.public_ip}:8200"
}

output "ssh_command" {
  description = "SSH command to connect to the EC2 instance"
  value       = "ssh -i ${var.ssh_private_key_path} ec2-user@${aws_eip.vault.public_ip}"
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.vault_oracle.id
}

output "elastic_ip" {
  description = "Elastic IP address of the EC2 instance"
  value       = aws_eip.vault.public_ip
}

output "vault_init_file" {
  value = "Init credentials stored at /opt/vault/data/init.json on EC2 and fetched locally to .vault-token / .vault-unseal-key"
}

output "test_dynamic_creds" {
  value = "vault read database/creds/my-role"
}

output "test_static_creds" {
  value = "vault read database/static-creds/static-role"
}
