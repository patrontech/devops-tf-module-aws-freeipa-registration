variable "prefix" {
  description = "Unique prefix for all the assets e.g hendrix, clapton, prod"
}

variable "name" {
  description = "Unique prefix for all the assets e.g aws-app-node-autoscaler"
}

variable "freeipa_secret_arn" {
  description = "The ARN for the secret containing FreeIPA credentials"
}

variable "ec2_fqdn_tag" {
  description = "The name of the EC2 tag that carries the instance's FQDN for freeIPA reg."
  default     = "FQDN"
}

variable "vpc_subnet_ids" {
  description = "A list of subnet IDs to attach the lambda function to."
  default     = []
}

variable "vpc_security_group_ids" {
  description = "A list of security group IDs to attach the lambda function to."
  default     = []
}

variable "aws_tags" {
  description = "AWS tags to assign to any resources created."
}