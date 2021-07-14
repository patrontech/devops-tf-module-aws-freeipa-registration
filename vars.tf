variable "prefix" {
  description = "Unique prefix for all the assets e.g hendrix, clapton, prod"
}

variable "name" {
  description = "Unique prefix for all the assets e.g aws-app-node-autoscaler"
}

variable "freeipa_secret_arn" {
  description = "The ARN for the secret containing FreeIPA credentials"
}

variable "aws_tags" {
  description = "AWS tags to assign to any resources created."
}