output "bash_script_snippet" {
  value = data.template_file.freeipa_bash_script_snippet.rendered
}

output "freeipa_secret_arn" {
  value = var.freeipa_secret_arn == "" ? aws_secretsmanager_secret.freeipa_credentials[0].arn : data.aws_secretsmanager_secret.freeipa_credentials.arn
}

output "freeipa_policy_arn" {
  value = var.freeipa_create_iam_policy == true ? aws_iam_policy.get_freeipa_secret[0].arn : ""
}