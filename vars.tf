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
###############################################################################
# DEVOPS-7459
###############################################################################

variable "lambda_runtime" {
  description = "Python runtime for the lambdas. python3.8 is EOL and AWS no longer allows new functions on it."
  default     = "python3.12"
}

variable "cleanup_lambda_timeout" {
  description = "Seconds. Must stay comfortably below the ASG lifecycle hook heartbeat_timeout, or instances hang waiting for a hook that never completes."
  default     = 90
}

variable "host_del_max_attempts" {
  description = "How many times the cleanup lambda retries host_del on a transient 389-ds DatabaseError."
  default     = 5
}

variable "metric_namespace" {
  description = "CloudWatch namespace for HostDelFailed / OrphanedHosts / ReconcileDeleted."
  default     = "FreeIPA/Registration"
}

variable "freeipa_ca_bundle" {
  description = "Path inside the lambda bundle to the realm CA cert, e.g. /var/task/ipa-ca.crt. Leave empty to disable TLS verification (the previous behaviour)."
  default     = ""
}

variable "reconcile_enabled" {
  description = "Create the scheduled reconciliation lambda."
  default     = false
}

variable "reconcile_schedule" {
  description = "EventBridge schedule expression for the reconciliation sweep."
  default     = "rate(1 day)"
}

variable "reconcile_apply" {
  description = "false = dry run, log what would be deleted and delete nothing. Set true only after reviewing a dry-run invocation."
  default     = false
}

variable "reconcile_managed_suffixes" {
  description = "FQDN suffixes the sweep is allowed to touch, e.g. [\"prod.awsclix.io\"]. Required when reconcile_enabled - it is the blast-radius guard."
  type        = list(string)
  default     = []
}

variable "reconcile_max_deletes" {
  description = "Abort the sweep without deleting anything if it finds more orphans than this."
  default     = 25
}

variable "reconcile_lambda_timeout" {
  description = "Seconds. The sweep lists every IPA host, so give it room."
  default     = 300
}

variable "enrolment_failure_webhook" {
  description = "Optional Slack webhook the instance userdata posts to when FreeIPA enrolment fails. Empty disables the alert."
  type        = string
  default     = ""
}
