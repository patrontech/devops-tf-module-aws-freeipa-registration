resource "aws_sns_topic" "autoscale_handling" {
  name = "${var.prefix}-${var.name}"
  tags = var.aws_tags
}

locals {
  titled_iam_name = "${title(var.prefix)}${title(var.name)}"
  iam_name        = replace(local.titled_iam_name, "-", "")
}

data "aws_iam_policy_document" "autoscale_handling" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:*"
    ]

  }
  statement {
    actions = [
      "autoscaling:DescribeTags",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:CompleteLifecycleAction",
      "ec2:DescribeInstances",
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
    ]
    resources = [
      "*"
    ]
  }
  statement {
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      var.freeipa_secret_arn,
    ]
  }
  # DEVOPS-7459: failed deregistrations are alarmed on rather than silently
  # dropped, and the reconcile sweep publishes orphan counts.
  statement {
    actions = [
      "cloudwatch:PutMetricData"
    ]
    resources = [
      "*"
    ]
  }
}

resource "aws_iam_role_policy" "autoscale_handling" {
  name   = local.iam_name
  role   = aws_iam_role.autoscale_handling.name
  policy = data.aws_iam_policy_document.autoscale_handling.json
}

resource "aws_iam_role" "autoscale_handling" {
  name = "${local.iam_name}AutoscaleFreeIPAHandler"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_role" "lifecycle" {
  name               = "${local.iam_name}FreeIPAHandlerLifecycle"
  assume_role_policy = data.aws_iam_policy_document.lifecycle.json
}

data "aws_iam_policy_document" "lifecycle" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lifecycle_policy" {
  name   = "${local.iam_name}FreeIPAHandlerLifecycle"
  role   = aws_iam_role.lifecycle.id
  policy = data.aws_iam_policy_document.lifecycle_policy.json
}

data "aws_iam_policy_document" "lifecycle_policy" {
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish", "autoscaling:CompleteLifecycleAction"]
    resources = [aws_sns_topic.autoscale_handling.arn]
  }
}

data "archive_file" "autoscale" {
  type             = "zip"
  source_dir       = "${path.module}/lambda/cleanup"
  output_path      = "${path.module}/lambda/cleanup_zip/cleanup.zip"
  output_file_mode = "0666"
}

resource "aws_lambda_function" "autoscale_handling" {
  depends_on = [aws_sns_topic.autoscale_handling]

  filename         = data.archive_file.autoscale.output_path
  function_name    = "${var.prefix}-${var.name}"
  role             = aws_iam_role.autoscale_handling.arn
  handler          = "cleanup.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.cleanup_lambda_timeout
  source_code_hash = filebase64sha256(data.archive_file.autoscale.output_path)
  description      = "Handles deregistering an instance from FreeIPA after its been terminated."
  environment {
    variables = {
      "FREEIPA_SECRET_ARN"    = var.freeipa_secret_arn
      "HOST_DEL_MAX_ATTEMPTS" = var.host_del_max_attempts
      "METRIC_NAMESPACE"      = var.metric_namespace
      "FREEIPA_CA_BUNDLE"     = var.freeipa_ca_bundle
    }
  }
  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = var.vpc_security_group_ids
  }
  tags = var.aws_tags
}

resource "aws_lambda_permission" "autoscale_handling" {
  depends_on = [aws_lambda_function.autoscale_handling]

  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.autoscale_handling.arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.autoscale_handling.arn
}

resource "aws_sns_topic_subscription" "autoscale_handling" {
  depends_on = [aws_lambda_permission.autoscale_handling]
  topic_arn  = aws_sns_topic.autoscale_handling.arn
  protocol   = "lambda"
  endpoint   = aws_lambda_function.autoscale_handling.arn
}
###############################################################################
# DEVOPS-7459: reconciliation sweep.
#
# Retries in the cleanup lambda cut the miss rate but never to zero, and do
# nothing about entries already orphaned. This sweep removes FreeIPA hosts
# whose EC2 instance no longer exists. It shares the cleanup lambda's zip so
# the vendored requests/urllib3 dependencies are not duplicated.
#
# Opt-in (reconcile_enabled = true) and ships in DRY RUN: set reconcile_apply =
# true only once you have read a dry-run invocation's logs and agree with what it
# proposes to delete.
###############################################################################

resource "aws_lambda_function" "reconcile" {
  count = var.reconcile_enabled ? 1 : 0

  filename         = data.archive_file.autoscale.output_path
  function_name    = "${var.prefix}-${var.name}-reconcile"
  role             = aws_iam_role.autoscale_handling.arn
  handler          = "reconcile.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.reconcile_lambda_timeout
  source_code_hash = filebase64sha256(data.archive_file.autoscale.output_path)
  description      = "Deletes FreeIPA host entries whose EC2 instance no longer exists."

  environment {
    variables = {
      "FREEIPA_SECRET_ARN"    = var.freeipa_secret_arn
      "IPA_MANAGED_SUFFIXES"  = join(",", var.reconcile_managed_suffixes)
      "RECONCILE_APPLY"       = var.reconcile_apply ? "true" : "false"
      "RECONCILE_MAX_DELETES" = var.reconcile_max_deletes
      "METRIC_NAMESPACE"      = var.metric_namespace
      "FREEIPA_CA_BUNDLE"     = var.freeipa_ca_bundle
    }
  }

  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = var.vpc_security_group_ids
  }

  tags = var.aws_tags

  lifecycle {
    precondition {
      condition     = length(var.reconcile_managed_suffixes) > 0
      error_message = "reconcile_managed_suffixes must be non-empty when reconcile_enabled is true. It is the blast-radius guard: without it the sweep would consider every host in the realm."
    }
  }
}

resource "aws_cloudwatch_event_rule" "reconcile" {
  count = var.reconcile_enabled ? 1 : 0

  name                = "${var.prefix}-${var.name}-reconcile"
  description         = "Scheduled FreeIPA orphaned-host reconciliation."
  schedule_expression = var.reconcile_schedule
  tags                = var.aws_tags
}

resource "aws_cloudwatch_event_target" "reconcile" {
  count = var.reconcile_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.reconcile[0].name
  target_id = "lambda"
  arn       = aws_lambda_function.reconcile[0].arn
}

resource "aws_lambda_permission" "reconcile" {
  count = var.reconcile_enabled ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reconcile[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reconcile[0].arn
}
