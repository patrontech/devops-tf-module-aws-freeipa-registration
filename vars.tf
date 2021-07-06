variable "name" {
  description = "The name prefix for any of the resources created by this module"
}

variable "freeipa_servers" {
  description = "An array of freeIPA servers for the resource to associate itself with."
  default     = []
}

variable "freeipa_principal_user" {
  description = "The username of the admin principal for which to use for enrollment of the resource"
}

variable "freeipa_principal_password" {
  description = "The password of the freeipa principal user for which to use for enrollment of the resource"
  sensitive   = true
}

variable "freeipa_domain" {
  description = "The freeIPA domain for which to register the resource"
}

variable "freeipa_secret_arn" {
  description = "The ARN for the secret containing FreeIPA credentials"
}

variable "freeipa_create_iam_policy" {
  type = bool
  description = "Set to true to have the module create the FreeIPA IAM policy."
}

variable "aws_tags" {
  description = "AWS tags to assign to any resources created."
}