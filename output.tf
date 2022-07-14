output "autoscale_handling_sns_topic_arn" {
  description = "SNS topic ARN for autoscaling group"
  value       = aws_sns_topic.autoscale_handling.arn
}

output "autoscale_iam_role_arn" {
  description = "IAM role ARN for autoscaling group"
  value       = aws_iam_role.autoscale_handling.arn
}

output "autoscale_iam_role_name" {
  description = "IAM role Name for autoscaling group"
  value       = aws_iam_role.autoscale_handling.name
}

output "agent_lifecycle_iam_role_arn" {
  description = "IAM Role ARN for lifecycle_hooks"
  value       = aws_iam_role.lifecycle.arn
}

output "freeipa_userdata_snippet" {
  description = "Userdata snippet to be added to EC2 instance during bootstrap"
  value       = data.template_file.userdata_snippet.rendered
}