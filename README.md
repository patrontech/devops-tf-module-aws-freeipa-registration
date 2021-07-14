## Intro
The following module is designed to work with Autoscaling Groups to manage the freeIPA regisration/deregistration lifecycle.

The module looks for a specific AWS tag(s) on the instance.  
asg:hostname_pattern : ops-ecs-node-#instanceid.myinternaldomain.io@#################

This is then parsed into a proper TLD and the lambda consequently makes a request to the freeIPA server issuing a delete.

We also expect a AWS secret to be made for the module which contains the following format:
- Host : ########
- Username : ######
- Password: ########

## Examples
When using this module you'll need to initialize it for every Autoscaling Group that needs FreeIPa registration you can use this module by implementing the following:

```terraform
module "autoscale_freeipa_handler" {
  source  = "github.com/patrontech/devops-tf-module-aws-freeipa-registration?ref=v1.10.1"
  prefix = var.aws_base_tags.env_name
  name = "aws-app-node-freeipa"
  aws_tags = var.aws_base_tags
  freeipa_secret_arn = "arn:aws:secretsmanager:#####"
  vpc_subnet_ids = []
  vpc_security_group_ids = []
}

resource "aws_autoscaling_lifecycle_hook" "ecs_node_group_launching_freeipa_handler" {
  name                    = "${var.aws_base_tags.env_name}-app-ecs-node-launching-freeipa-hook"
  autoscaling_group_name  = aws_autoscaling_group.ecs_node_group.name
  default_result          = "ABANDON" # this maybe should be continue instead.
  heartbeat_timeout       = 120
  lifecycle_transition    = "autoscaling:EC2_INSTANCE_TERMINATING"
  notification_target_arn = module.autoscale_freeipa_handler.autoscale_handling_sns_topic_arn
  role_arn                = module.autoscale_freeipa_handler.agent_lifecycle_iam_role_arn
}

```

## Here be dragons
This module in particular looks for specific instance aws tags to determine what the IPA record is for deletion. This probably isn't the best approach.
It would be better if we could pass through a route53 zone and then scan the entire zone to match the IP address and then delete the relevant IPA records.

This would decouple us from a particular tagging strategy and make this more flexible. However due to time constraints here we are.

