data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Reports go to a SEPARATE topic, otherwise the agent would trigger itself
resource "aws_sns_topic" "reports" {
  name = "${var.name}-incident-reports"
}

resource "aws_sns_topic_subscription" "reports_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.reports.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_dynamodb_table" "audit" {
  name         = "${var.name}-agent-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"
  range_key    = "ts"

  attribute {
    name = "incident_id"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "S"
  }
}

data "archive_file" "agent" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/agent.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.name}-agent"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "agent" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.llm_secret_arn]
  }
  statement {
    actions = ["logs:FilterLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}:*",
    ]
  }
  statement {
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecs:DescribeServices"]
    resources = ["*"]
  }
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.reports.arn]
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "agent-read-only-tools"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/lambda/${var.name}-agent"
  retention_in_days = 7
}

resource "aws_lambda_function" "agent" {
  function_name    = "${var.name}-agent"
  role             = aws_iam_role.agent.arn
  runtime          = "python3.12"
  handler          = "agent.handler"
  filename         = data.archive_file.agent.output_path
  source_code_hash = data.archive_file.agent.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      LOG_GROUP        = var.log_group_name
      CLUSTER          = var.cluster_name
      SERVICE          = var.service_name
      ALB_ARN_SUFFIX   = var.alb_arn_suffix
      TG_ARN_SUFFIX    = var.target_group_arn_suffix
      REPORT_TOPIC_ARN = aws_sns_topic.reports.arn
      AUDIT_TABLE      = aws_dynamodb_table.audit.name
      LLM_SECRET_ARN   = var.llm_secret_arn
      LLM_PROVIDER     = var.llm_provider
      LLM_MODEL        = var.llm_model
    }
  }

  depends_on = [aws_cloudwatch_log_group.agent]
}

resource "aws_lambda_permission" "from_sns" {
  statement_id  = "AllowAlarmTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.alarm_topic_arn
}

resource "aws_sns_topic_subscription" "agent" {
  topic_arn = var.alarm_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.agent.arn
}
