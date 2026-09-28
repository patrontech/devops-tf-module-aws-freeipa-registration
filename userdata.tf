## The following file is responsible for generating and outputing the user-data which can be used to register an instance
## with freeIPA. It should be concatenated with whatever other userdata scripts we have
##
## DEVOPS-7459: was data "template_file", which needs the deprecated
## hashicorp/template provider. That provider has no darwin_arm64 build, so
## terraform init/validate could not run on Apple Silicon at all. templatefile()
## is built into Terraform, renders identically, and drops the provider.
locals {
  userdata_snippet = templatefile("${path.module}/bash.tpl", {
    ec2_fqdn_tag        = var.ec2_fqdn_tag
    freeipa_secret_name = var.freeipa_secret_arn
    failure_webhook     = var.enrolment_failure_webhook
  })
}
