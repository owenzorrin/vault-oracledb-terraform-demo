# Copyright IBM Corp. 2017, 2026

output "vault_address" {
  description = "Vault API address"
  value       = "http://${aws_eip.vault.public_ip}:8200"
}

output "vault_ssh_command" {
  description = "SSH command for the Vault host"
  value       = "ssh -i ${var.ssh_private_key_path} ec2-user@${aws_eip.vault.public_ip}"
}

output "oracle_ssh_command" {
  description = "SSH command for the Oracle host"
  value       = "ssh -i ${var.ssh_private_key_path} ec2-user@${aws_instance.oracle.public_ip}"
}

output "oracle_private_ip" {
  description = "Private IP Vault uses to reach the Oracle listener"
  value       = aws_instance.oracle.private_ip
}

output "elastic_ip" {
  description = "Elastic IP address of the Vault host"
  value       = aws_eip.vault.public_ip
}

output "test_dynamic_creds" {
  value = "vault read database/creds/my-role"
}

output "test_static_creds" {
  value = "vault read database/static-creds/static-role"
}
