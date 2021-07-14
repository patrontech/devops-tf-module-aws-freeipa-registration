resource "aws_sns_topic" "autoscale_handling" {
  name = "${var.prefix}-${var.name}"
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
}

resource "aws_iam_role_policy" "autoscale_handling" {
  name   = local.iam_name
  role   = aws_iam_role.autoscale_handling.name
  policy = data.aws_iam_policy_document.autoscale_handling.json
}

resource "aws_iam_role" "autoscale_handling" {
  name = "${local.iam_name}AutoscaleDNSHandler"

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
  name               = "${local.iam_name}Lifecycle"
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
  name   = "${local.iam_name}Lifecycle"
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
  type        = "zip"
  source_file = "${path.module}/lambda/cleanup/"
  output_path = "${path.module}/lambda/cleanup/cleanup.zip"
}

resource "aws_lambda_function" "autoscale_handling" {
  depends_on = [aws_sns_topic.autoscale_handling]

  filename         = data.archive_file.autoscale.output_path
  function_name    = "${var.prefix}-${var.name}"
  role             = aws_iam_role.autoscale_handling.arn
  handler          = "cleanup.lambda_handler"
  runtime          = "python3.8"
  source_code_hash = filebase64sha256(data.archive_file.autoscale.output_path)
  description      = "Handles deregistering an instance from FreeIPA after its been terminated."
  environment {
    variables = {
      "FREEIPA_SECRET_ARN" = var.freeipa_secret_arn
    }
  }
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
  topic_arn = aws_sns_topic.autoscale_handling.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.autoscale_handling.arn
}