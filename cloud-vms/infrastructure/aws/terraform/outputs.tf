output "dashboard_url" {
  description = "Changes after a stop/start; `vms-aws.ps1 status` always shows the current one"
  value       = "http://${aws_instance.app.public_ip}"
}

output "region" {
  value = var.region
}

output "instance_id" {
  value = aws_instance.app.id
}

output "db_identifier" {
  value = aws_db_instance.db.identifier
}

output "bucket" {
  value = aws_s3_bucket.media.bucket
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "admin_password_parameter" {
  description = "Read with `vms-aws.ps1 password` (user name: admin)"
  value       = aws_ssm_parameter.admin_password.name
}
