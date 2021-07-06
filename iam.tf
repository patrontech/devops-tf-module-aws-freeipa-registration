data "aws_iam_policy_document" "get_freeipa_secret" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.freeipa_secret_arn == "" ? aws_secretsmanager_secret.freeipa_credentials.name : data.aws_secretsmanager_secret.freeipa_credentials.name}",
    ]
  }
}

resource "aws_iam_policy" "get_freeipa_secret" {
  count       = var.freeipa_create_iam_policy == true ? 0 : 1
  name        = "${var.name}GetFreeIPASecrets"
  description = "Allows retrieval of FreeIPA Secrets For Node Registraion"
  policy      = data.aws_iam_policy_document.get_freeipa_secret.json
}