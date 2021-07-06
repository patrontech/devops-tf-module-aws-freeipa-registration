data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_secretsmanager_secret" "freeipa_credentials" {
  count = var.freeipa_secret_arn == "" ? 0 : 1
  arn   = var.freeipa_secret_arn
}

data "template_file" "freeipa_bash_script_snippet" {
  template = file("${path.module}/bash.tpl")
  vars = {
    freeipa_domain    = var.freeipa_domain
    freeipa_servers   = var.freeipa_servers
    freeipa_principal = var.freeipa_principal_user
    freeipa_secret_id = var.freeipa_secret_arn == "" ? aws_secretsmanager_secret.freeipa_credentials.name : data.aws_secretsmanager_secret.freeipa_credentials.name
  }
}
