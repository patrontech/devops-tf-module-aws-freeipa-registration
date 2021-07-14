## The following file is responsible for generating and outputing the user-data which can be used to register an instance
## with freeIPA. It should be concatenated with whatever other userdata scripts we have
data "template_file" "userdata_snippet" {
  template = file("${path.module}/bash.tpl")
  vars = {
    ec2_fqdn_tag        = var.ec2_fqdn_tag
    freeipa_secret_name = var.freeipa_secret_arn
  }
}