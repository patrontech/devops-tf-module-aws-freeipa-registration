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


## Enrolment retry and orphan reconciliation (DEVOPS-7459)

Concurrent ASG churn causes 389-ds transaction collisions on the FreeIPA servers,
returned to callers as `DatabaseError`. Previously both halves of this module
treated that as success: `ipa-client-install` ran once with no retry, and the
cleanup lambda never looked at the JSON-RPC response at all. The result was
instances booting with no Kerberos identity, and stale host entries accumulating
on every failed deregistration.

**Enrolment** (`bash.tpl`) now retries `ipa-client-install` with exponential
backoff and jitter, clearing a partial install between attempts. The jitter is
load-bearing: a scale-out launches several instances at once, and without it they
retry in lockstep and recreate the collision.

**Deregistration** (`cleanup.py`) parses the response, retries transient errors,
and publishes a `HostDelFailed` CloudWatch metric when it finally gives up. It
still completes the lifecycle hook either way - for `EC2_INSTANCE_TERMINATING`
both CONTINUE and ABANDON terminate the instance, so refusing to complete would
only strand ASG capacity. **Alarm on `HostDelFailed`.**

**Reconciliation** (`reconcile.py`) runs on a schedule and deletes host entries
whose EC2 instance no longer exists. It is opt-in (`reconcile_enabled = true`)
and ships in dry run. Guards, in order:

1. Only FQDNs equal to, or subdomains of, `reconcile_managed_suffixes` are
   considered (DNS label boundary - `prod.awsclix.io` does not match
   `notprod.awsclix.io`).
2. Only FQDNs containing an EC2 instance id are considered.
3. An instance counts as an orphan only if EC2 does not return it *at all*.
   Terminated instances stay visible for about an hour, which gives a free grace
   period and avoids racing the cleanup lambda. A stopped instance is left alone.
4. Nothing is deleted unless `reconcile_apply = true`.
5. More than `reconcile_max_deletes` orphans aborts the run without deleting.

### Rollout

Enable with `reconcile_apply = false`, read a dry-run invocation's logs, and only
then set `reconcile_apply = true`.

```terraform
module "autoscale_freeipa_handler" {
  source = "github.com/patrontech/devops-tf-module-aws-freeipa-registration?ref=vX.Y.Z"
  # ... existing arguments ...

  reconcile_enabled          = true
  reconcile_managed_suffixes = ["prod.awsclix.io", "prod.conv.leapevent.net"]
  reconcile_apply            = false  # flip to true after reviewing a dry run
}
```

### Notes

- `lambda_runtime` now defaults to `python3.12`. The previous hardcoded
  `python3.8` is end-of-life and AWS no longer accepts new functions on it.
- `cleanup_lambda_timeout` must stay comfortably below the lifecycle hook's
  `heartbeat_timeout`, or instances hang waiting on a hook that never completes.
  The retry loop also watches its own remaining execution budget so a slow batch
  cannot strand later records.
- `freeipa_ca_bundle` is empty by default, which preserves the existing
  behaviour of **disabled TLS verification**. Point it at a bundled realm CA
  cert to turn verification on.
- `userdata.tf` now uses the built-in `templatefile()` instead of the deprecated
  `hashicorp/template` provider, which has no `darwin_arm64` build and blocked
  `terraform init` on Apple Silicon entirely.
