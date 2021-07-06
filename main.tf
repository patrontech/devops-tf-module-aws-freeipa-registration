# This creates a secret if the user doesn't specify an ARN for the secret
# We expect the secret to be added in the form
# freeipa_principal_user = XXXXXXXX
# freeipa_principal_password = XXXXXXXXX
#
resource "aws_secretsmanager_secret" "freeipa_credentials" {
  count = var.freeipa_secret_arn == "" ? 1 : 0
  name  = "${var.name}-freeipa-registration-credentials"
  tags  = var.aws_tags
}
