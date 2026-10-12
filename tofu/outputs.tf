output "vpc_id" {
  description = "VPC this workspace created for the cluster."
  value       = aws_vpc.main.id
}

output "controller_addresses" {
  description = "Private addresses of the control-plane nodes, as the machine configs resolve the API's name to them."
  value       = aws_instance.controller[*].private_ip
}

output "controller_endpoint" {
  description = "Where the operator reaches the Talos and Kubernetes APIs. `just bootstrap cluster` and every kubectl afterwards take this."
  value       = aws_eip.controller.public_ip
}

output "worker_addresses" {
  description = "Private addresses of the workers."
  value       = aws_instance.worker[*].private_ip
}

output "hosts_entry" {
  description = "Line to add to /etc/hosts on the operator's machine so talosctl and kubectl reach the API. The nodes resolve the same name themselves."
  value       = "${aws_eip.controller.public_ip} kubernetes.${var.domain}"
}

output "edge_lb_dns_name" {
  description = "Where the wildcard names have to resolve to. Until a zone carries them, this is what an /etc/hosts entry or curl --resolve points at."
  value       = aws_lb.edge.dns_name
}

output "wildcard_certificate_arn" {
  description = "ARN of the *.domain certificate the HTTPS listener holds."
  value       = aws_acm_certificate.wildcard.arn
}

output "wildcard_certificate_status" {
  description = "Certificate status. Issued off the tenant CA, so it reads ISSUED as soon as the apply returns."
  value       = aws_acm_certificate.wildcard.status
}

output "db_endpoint" {
  description = "Host the applications' connection strings name. Resolves inside the cluster and is reachable from the nodes alone."
  value       = aws_db_instance.postgres.address
}

output "db_master_username" {
  description = "Master user the init containers authenticate as."
  value       = aws_db_instance.postgres.username
}

output "db_master_password" {
  description = "Master password. Read with `tofu output -raw db_master_password` and put into the sops cluster secrets; this workspace is the only source of it."
  value       = random_password.db_master.result
  sensitive   = true
}

output "nfs_address" {
  description = "Address the applications mount the media library from."
  value       = aws_instance.nfs.private_ip
}

output "nfs_export" {
  description = "Export path on the NFS server."
  value       = "/srv/media"
}

output "media_smb_address" {
  description = "Where a desktop on the admin CIDR mounts the media library over SMB, as smb://<this>/media."
  value       = aws_instance.nfs.public_ip
}

output "media_smb_username" {
  description = "SMB user for the media share."
  value       = "media"
}

output "media_smb_password" {
  description = "SMB password for the media share. Read with `tofu output -raw media_smb_password`."
  value       = random_password.smb.result
  sensitive   = true
}

output "volsync_bucket" {
  description = "Bucket volsync writes backups to."
  value       = aws_s3_bucket.volsync.bucket
}

output "volsync_key_id" {
  description = "Access key for the volsync identity."
  value       = aws_iam_access_key.volsync.id
}

output "volsync_key_secret" {
  description = "Secret half of the volsync access key."
  value       = aws_iam_access_key.volsync.secret
  sensitive   = true
}

output "s3_endpoint" {
  description = "Predastore endpoint, as the movers need it (host:port, no scheme)."
  value       = replace(var.s3_endpoint, "https://", "")
}
